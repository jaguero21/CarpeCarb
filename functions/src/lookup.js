/**
 * Food lookup through USDA FoodData Central, with the web lookup as fallback.
 *
 * Numbers for matched foods are calculated here from FDC data; the model only
 * splits the text and names an entry and portion. Foods FDC can't match go to
 * the existing Perplexity web lookup, labelled as such.
 */

const { HttpsError } = require("firebase-functions/v2/https");
const { lookupFoods, sanitizeFoodInput, isNotBilled, notBilled } = require("./perplexity");
const { searchCandidates, nutritionFor, UsdaError } = require("./usda");
const { parseFoods, pickMatches, validatePick, ParseError } = require("./foodParse");

const USDA_BUDGET_MS = 12_000;
const TOTAL_BUDGET_MS = 25_000;
const USDA_CALL_MS = 4_000;
const SONAR_CALL_MS = 6_000;
const WEB_PREFIX = "Web source, not USDA. ";

class WebTimeout extends Error {}

function unknown(name, details) {
  return { name, carbs: null, protein: null, fat: null, fiber: null, calories: null, details };
}

function amountText(count, label) {
  if (count === 1) return label;
  return `${Number(count.toFixed(2))} × ${label}`;
}

function usdaItem(food, { candidate, portion, count }) {
  const n = nutritionFor(candidate, portion, count);
  const brand = candidate.brand ? `, ${candidate.brand}` : "";
  return {
    name: food.name,
    carbs: n.carbs,
    protein: n.protein,
    fat: n.fat,
    fiber: n.fiber,
    calories: n.calories,
    details:
      `USDA FoodData Central (${candidate.dataType}): ${candidate.description}${brand}, ` +
      `${amountText(count, portion.label)} (${n.grams} g).`,
  };
}

const labelled = (item) => ({ ...item, details: `${WEB_PREFIX}${item.details || ""}`.trim() });

const errorCode = (err) =>
  err instanceof UsdaError || err instanceof ParseError ? err.message : (err && err.name) || "error";

/**
 * Looks up a sanitized food description. Same result shape and billing
 * markers as lookupFoods in perplexity.js.
 *
 * @param {string} sanitized - output of sanitizeFoodInput
 * @param {{perplexityKey: string, usdaKey: string}} keys
 * @param {{fetchImpl?: typeof fetch, now?: () => number, webLookup?: (text: string) => Promise<{items: object[], citations: string[]}>, sleep?: (ms: number) => Promise<void>}} [options]
 */
async function lookupFoodsUsda(sanitized, { perplexityKey, usdaKey }, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  const now = options.now || Date.now;
  const webLookup = options.webLookup || ((text) => lookupFoods(text, perplexityKey, { fetchImpl }));

  const start = now();
  const left = (budget) => Math.max(0, start + budget - now());
  // The USDA path's own deadline: passed to parse, search and pick so each one's retries and
  // sequential calls are capped by the time actually left, not a value frozen at call start.
  const usdaDeadline = start + USDA_BUDGET_MS;
  const billing = { billed: false };
  const stats = { foods: 0, usda: 0, web: 0 };
  const logDone = (outcome = "ok") =>
    console.log(`[lookup] source=usda foods=${stats.foods} usda=${stats.usda} web=${stats.web} ms=${now() - start} outcome=${outcome}`);

  /** The web lookup, capped by the overall budget, with billing carried across the request. */
  async function web(text) {
    let timer;
    try {
      return await Promise.race([
        webLookup(text),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new WebTimeout()), left(TOTAL_BUDGET_MS));
        }),
      ]);
    } catch (err) {
      // An earlier call in this request was billed, so the lookup counts whatever the web call did.
      if (billing.billed && isNotBilled(err)) err.notBilled = false;
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  let foods;
  try {
    foods = await parseFoods(sanitized, perplexityKey, {
      fetchImpl, billing, timeoutMs: SONAR_CALL_MS, deadline: usdaDeadline, now, sleep: options.sleep,
    });
  } catch (err) {
    console.log(`[lookup] parse failed: ${errorCode(err)}`);
    stats.web = 1;
    try {
      const result = await web(sanitized);
      logDone();
      return { items: result.items.map(labelled), citations: result.citations || [] };
    } catch (webErr) {
      console.log(`[lookup] parse fallback failed: ${errorCode(webErr)}`);
      logDone("error");
      if (webErr instanceof WebTimeout) {
        const timeoutErr = new HttpsError("deadline-exceeded", "Looking this up took too long. Enter the carbs yourself.");
        // Billed only if the parse call itself got a 2xx; nothing else on this path can bill us.
        throw billing.billed ? timeoutErr : notBilled(timeoutErr);
      }
      throw webErr;
    }
  }
  stats.foods = foods.length;

  const matches = foods.map(() => null);
  try {
    // Only a food with a named brand or chain is reliable enough for USDA. A plain food
    // ("pizza", "an apple") gets an empty candidate list, which pickMatches skips, so it
    // falls straight through to the web leftover below without ever being searched.
    const lists = await Promise.all(foods.map((food) => {
      if (food.brand === null) return [];
      return searchCandidates(food.query, usdaKey, {
        fetchImpl, timeoutMs: USDA_CALL_MS, deadline: usdaDeadline, now,
      }).catch((err) => {
        console.log(`[lookup] usda search failed: ${errorCode(err)}`);
        return [];
      });
    }));
    if (lists.some((list) => list.length > 0) && left(USDA_BUDGET_MS) > 0) {
      const picks = await pickMatches(foods, lists, perplexityKey, {
        fetchImpl, billing, timeoutMs: SONAR_CALL_MS, deadline: usdaDeadline, now, sleep: options.sleep,
      });
      picks.forEach((pick, i) => { matches[i] = validatePick(pick, lists[i], foods[i]); });
    }
  } catch (err) {
    console.log(`[lookup] pick failed: ${errorCode(err)}`);
  }

  const items = [];
  const citations = [];
  const leftover = [];
  foods.forEach((food, i) => {
    if (!matches[i]) {
      leftover.push(food);
      return;
    }
    items.push(usdaItem(food, matches[i]));
    citations.push(`https://fdc.nal.usda.gov/food-details/${matches[i].candidate.fdcId}/nutrients`);
  });
  stats.usda = items.length;
  stats.web = leftover.length;

  if (leftover.length > 0) {
    // When nothing matched, the web gets the original text as-is - there's nothing USDA already
    // covered, so nothing can be double-counted. Otherwise the web must never see wording for a
    // food USDA already matched: the parse and web models can name the same food differently
    // (e.g. "Big Mac" vs "McDonald's Big Mac"), so a same-name dedupe after the fact can't be
    // trusted to catch it. Only the leftover foods' own words are ever sent, tried a few ways to
    // fit sanitizeFoodInput's length cap; if none fit, those foods are reported unknown rather
    // than risk asking the web about a food USDA already resolved.
    let text = sanitized;
    if (items.length > 0) {
      const attempts = [
        () => leftover.map((f) => f.text).join(" and "),
        () => leftover.map((f) => f.text).join(", "),
        () => leftover.map((f) => f.name).join(", "),
      ];
      text = null;
      for (const attempt of attempts) {
        try {
          text = sanitizeFoodInput(attempt());
          break;
        } catch {
          // try the next fallback
        }
      }
    }
    if (text === null) {
      const details = "Couldn't look this up. Enter the carbs yourself.";
      for (const food of leftover) items.push(unknown(food.name, details));
    } else {
      try {
        const result = await web(text);
        items.push(...result.items.map(labelled));
        citations.push(...(result.citations || []));
      } catch (err) {
        if (!(err instanceof WebTimeout) && items.length === 0) {
          logDone("error");
          throw err;
        }
        const details = err instanceof WebTimeout
          ? "Couldn't look this up in time. Enter the carbs yourself."
          : "Couldn't look this up. Enter the carbs yourself.";
        for (const food of leftover) items.push(unknown(food.name, details));
      }
    }
  }

  logDone();
  return { items, citations: [...new Set(citations)] };
}

module.exports = { lookupFoodsUsda };
