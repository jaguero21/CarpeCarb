/**
 * Food lookup through USDA FoodData Central, with the web lookup as fallback.
 *
 * Brand and chain foods are matched in USDA FoodData Central first. Every other
 * food, and any brand food USDA can't match, goes through a chain: the web lookup,
 * then USDA survey data, then the web lookup once more. A 0 g answer needs two
 * sources to agree. Numbers from USDA are calculated here from FDC data; the
 * model only splits the text and names an entry and portion.
 */

const { HttpsError } = require("firebase-functions/v2/https");
const { lookupFoods, sanitizeFoodInput, isNotBilled, notBilled } = require("./perplexity");
const { searchCandidates, nutritionFor, UsdaError } = require("./usda");
const { parseFoods, pickMatches, validatePick, ParseError } = require("./foodParse");

const USDA_BUDGET_MS = 12_000;
const TOTAL_BUDGET_MS = 25_000;
const USDA_CALL_MS = 4_000;
const SONAR_CALL_MS = 6_000;
// The chain only starts a step it has time to finish: a USDA survey check needs room for its
// search and pick plus a web retry after it; a web call needs a few seconds on its own.
const MIN_SURVEY_MS = 8_000;
const MIN_WEB_MS = 3_000;
const SURVEY = ["Survey (FNDDS)"];
const WEB_PREFIX = "Web source, not USDA. ";
const NOT_FOUND = "Couldn't look this up. Enter the carbs yourself.";
const NOT_IN_TIME = "Couldn't look this up in time. Enter the carbs yourself.";

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
    // For the serving picker: the app can show these servings and recalculate from per100g,
    // so changing the serving needs no new lookup. Older app versions ignore these fields.
    source: "usda",
    fdcId: candidate.fdcId,
    serving: { portionId: portion.id, label: portion.label, grams: portion.grams, count },
    portions: candidate.portions,
    per100g: candidate.per100g,
  };
}

const labelled = (item) => ({ ...item, details: `${WEB_PREFIX}${item.details || ""}`.trim(), source: "web" });
const fdcCitation = (candidate) => `https://fdc.nal.usda.gov/food-details/${candidate.fdcId}/nutrients`;

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
  const stats = { foods: 0, usda: 0, survey: 0, web: 0, unknown: 0, webCalls: 0 };
  const logDone = (outcome = "ok") =>
    console.log(
      `[lookup] source=usda foods=${stats.foods} usda=${stats.usda} survey=${stats.survey} web=${stats.web} ` +
      `unknown=${stats.unknown} webCalls=${stats.webCalls} ms=${now() - start} outcome=${outcome}`
    );

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
    // goes straight to the chain below without a brand search.
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

  // Brand foods USDA matched are done. Every other food goes through the chain on its own, so
  // each answer maps back to the food, and the amount, the user typed.
  const results = foods.map((food, i) =>
    matches[i] ? { item: usdaItem(food, matches[i]), citations: [fdcCitation(matches[i].candidate)] } : null
  );
  stats.usda = results.filter(Boolean).length;
  let firstWebError = null;

  /** One food's own words for the web, or null if neither its text nor its name passes the rules. */
  function lookupText(food) {
    for (const t of [food.text, food.name]) {
      try {
        return sanitizeFoodInput(t);
      } catch {
        // try the next one
      }
    }
    return null;
  }

  /** One web lookup for one food: {item, citations} | {timeout} | {error} | {none}. */
  async function webOnce(food) {
    const text = lookupText(food);
    if (text === null) return { none: true };
    if (left(TOTAL_BUDGET_MS) < MIN_WEB_MS) return { timeout: true };
    stats.webCalls += 1;
    try {
      const result = await web(text);
      const item = result.items[0];
      return item ? { item: labelled(item), citations: result.citations || [] } : { none: true };
    } catch (err) {
      if (err instanceof WebTimeout) return { timeout: true };
      if (!firstWebError) firstWebError = err;
      console.log(`[lookup] web failed: ${errorCode(err)}`);
      return { error: err };
    }
  }

  /** The USDA survey (FNDDS) entry for a food, as {item, citations}, or null. */
  async function surveyOnce(food) {
    if (left(TOTAL_BUDGET_MS) < MIN_SURVEY_MS) return null;
    // Leave room for the web retry that follows a miss.
    const deadline = start + TOTAL_BUDGET_MS - MIN_WEB_MS;
    try {
      const list = await searchCandidates(food.query, usdaKey, {
        fetchImpl, timeoutMs: USDA_CALL_MS, deadline, now, dataTypes: SURVEY,
      });
      if (list.length === 0) return null;
      const [pick] = await pickMatches([food], [list], perplexityKey, {
        fetchImpl, billing, timeoutMs: SONAR_CALL_MS, deadline, now, sleep: options.sleep,
      });
      const match = validatePick(pick, list, food);
      if (!match) return null;
      return { item: usdaItem(food, match), citations: [fdcCitation(match.candidate)] };
    } catch (err) {
      console.log(`[lookup] survey failed: ${errorCode(err)}`);
      return null;
    }
  }

  const carbsOf = (r) => (r && r.item ? r.item.carbs : undefined);

  /**
   * web → USDA survey → web again. A 0 is never returned on one source's word: USDA must
   * confirm it (or replace it with its own number), or a second web lookup must say 0 too.
   */
  async function resolveFood(food) {
    const first = await webOnce(food);
    if (carbsOf(first) > 0) {
      stats.web += 1;
      return first;
    }
    const survey = await surveyOnce(food);
    if (survey) {
      stats.survey += 1;
      return survey;
    }
    const second = await webOnce(food);
    if (carbsOf(second) > 0) {
      stats.web += 1;
      return second;
    }
    if (carbsOf(first) === 0 && carbsOf(second) === 0) {
      stats.web += 1;
      return { item: { ...first.item, details: `${first.item.details} Checked twice: 0 g.` }, citations: first.citations };
    }
    stats.unknown += 1;
    return { item: unknown(food.name, first.timeout || second.timeout ? NOT_IN_TIME : NOT_FOUND), citations: [] };
  }

  for (let i = 0; i < foods.length; i++) {
    if (!results[i]) results[i] = await resolveFood(foods[i]);
  }

  // Nothing found anywhere because the web lookup itself failed (rate limit, auth, outage):
  // surface that error, with its billing marker, instead of a list of unknowns.
  if (firstWebError && results.every((r) => r.item.carbs === null)) {
    logDone("error");
    throw firstWebError;
  }

  const items = results.map((r) => r.item);
  const citations = results.flatMap((r) => r.citations);
  logDone();
  return { items, citations: [...new Set(citations)] };
}

module.exports = { lookupFoodsUsda };
