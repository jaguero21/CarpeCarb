/**
 * The two search-off model calls in a USDA lookup: split the text into foods,
 * then pick an FDC entry and portion for each. The model names things here; it
 * never supplies a nutrition number.
 */

const { retryWaitMs } = require("./perplexity");

const SONAR_URL = "https://api.perplexity.ai/chat/completions";
const MAX_FOODS = 10;
const MAX_FIELD = 100;

/** Any sonar call or output failure. The message is a short code, never model output. */
class ParseError extends Error {}

const PARSE_PROMPT =
  "You split a food log entry into the separate foods it names, for a USDA FoodData Central search. " +
  "Reply with ONLY a JSON array, no markdown. One element per distinct food the user names " +
  "('burger and fries' is 2; 'tortilla' is 1). Each element has: " +
  '"name" (string: the food as the user would recognise it, with the brand if they gave one), ' +
  '"query" (string: a FoodData Central search phrase; if the user named a brand or chain, use it with the ' +
  "product name, e.g. \"McDonald's Chicken McNuggets\"; no quantities), " +
  '"amount" (string: the user\'s own words for how much, e.g. "a bowl of", "10", "2 slices"; null if they gave none), ' +
  '"text" (string: the user\'s words for this food, amount included, copied exactly), ' +
  '"brand" (string: the brand, chain, restaurant or store the user named, e.g. "McDonald\'s", "H-E-B"; ' +
  "null if they named none). " +
  "Do not give nutrition values.";

const PICK_PROMPT =
  "You match foods to USDA FoodData Central entries. The user message is JSON: foods, each with the amount " +
  "the user gave and candidate entries with their portions. For each food choose the candidate that is the " +
  "same food, then the portion and count that match the amount. Reply with ONLY a JSON array, one element per " +
  'food: {"index": number, "fdcId": number or null, "portionId": string or null, "count": number or null}. ' +
  "Rules: Choose a candidate only if it is the same food. A different dish, a different form (broth for a soup, " +
  "raw for cooked) or an ingredient of it is not a match. " +
  "If the user named a brand or chain, only a candidate from that brand or chain matches; if there is none, fdcId is null. " +
  "If the user gave no amount, set portionId and count to null; the server uses the standard portion. " +
  "If the user gave an amount, choose the portion and count that give it: \"10\" nuggets with a \"4 pieces\" portion is count 2.5. " +
  "If nothing matches, fdcId is null. Never give nutrition values.";

const realSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * @param {{fetchImpl?: typeof fetch, timeoutMs?: number, deadline?: number, now?: () => number,
 *   billing: object, sleep?: (ms: number) => Promise<void>}} options - `deadline` is an absolute
 *   ms timestamp (comparable to `now()`); when given, it caps every attempt's timeout (including
 *   a retry's, freshly, after any sleep) on top of `timeoutMs`, and a 429 is not retried when the
 *   server's wait would itself run past it. Without a `deadline`, `timeoutMs` alone is the cap,
 *   as before.
 */
async function callSonar(system, user, apiKey, { fetchImpl = fetch, timeoutMs, deadline, now = Date.now, billing, sleep = realSleep }) {
  const requestInit = {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "sonar",
      disable_search: true,
      temperature: 0,
      max_tokens: 1024,
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
    }),
  };
  /** This attempt's timeout: `timeoutMs`, further capped by the time left before `deadline`. */
  function attemptTimeoutMs() {
    if (deadline === undefined) return timeoutMs;
    const left = Math.max(0, deadline - now());
    return timeoutMs === undefined ? left : Math.min(timeoutMs, left);
  }
  async function attempt() {
    try {
      return await fetchImpl(SONAR_URL, { ...requestInit, signal: AbortSignal.timeout(attemptTimeoutMs()) });
    } catch (err) {
      throw new ParseError(err && err.name === "TimeoutError" ? "timeout" : "network");
    }
  }

  let res = await attempt();
  if (res.status === 429) {
    const wait = retryWaitMs(res);
    const timeLeft = deadline === undefined ? Infinity : deadline - now();
    if (wait !== null && wait < timeLeft) {
      await sleep(wait);
      res = await attempt();
    }
  }
  if (!res.ok) throw new ParseError(`status ${res.status}`);
  billing.billed = true;
  let body;
  try {
    body = await res.json();
  } catch {
    throw new ParseError("bad json");
  }
  const content = body && body.choices && body.choices[0] && body.choices[0].message
    ? body.choices[0].message.content
    : undefined;
  if (typeof content !== "string") throw new ParseError("no content");
  return content;
}

function jsonArray(content) {
  const text = content.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "");
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start < 0 || end < start) throw new ParseError("no array");
  try {
    const value = JSON.parse(text.slice(start, end + 1));
    if (!Array.isArray(value)) throw new ParseError("not an array");
    return value;
  } catch (err) {
    if (err instanceof ParseError) throw err;
    throw new ParseError("bad array");
  }
}

const isField = (v) => typeof v === "string" && v.trim().length > 0 && v.length <= MAX_FIELD;

/**
 * Splits the user's text into foods.
 *
 * @returns {Promise<{name: string, query: string, amount: string|null, text: string, brand: string|null}[]>}
 * @throws {ParseError}
 */
async function parseFoods(text, apiKey, options) {
  const raw = jsonArray(await callSonar(PARSE_PROMPT, text, apiKey, options));
  if (raw.length === 0 || raw.length > MAX_FOODS) throw new ParseError("food count");
  return raw.map((item) => {
    if (!item || typeof item !== "object") throw new ParseError("item");
    const amount = item.amount === undefined ? null : item.amount;
    // A brand the model sent as "" or whitespace named no brand; treat it the
    // same as omitting the field instead of rejecting the whole food.
    const rawBrand = item.brand === undefined ? null : item.brand;
    const brand = typeof rawBrand === "string" && rawBrand.trim() === "" ? null : rawBrand;
    if (!isField(item.name) || !isField(item.query) || !isField(item.text)) throw new ParseError("fields");
    if (amount !== null && !isField(amount)) throw new ParseError("amount");
    if (brand !== null && !isField(brand)) throw new ParseError("brand");
    return {
      name: item.name.trim(), query: item.query.trim(), amount: amount && amount.trim(), text: item.text.trim(),
      brand: brand === null ? null : brand.trim(),
    };
  });
}

/**
 * Asks for one pick per food that has candidates, in a single call.
 *
 * @returns {Promise<(object|null)[]>} raw picks aligned with `foods`; validate with validatePick
 * @throws {ParseError}
 */
async function pickMatches(foods, candidateLists, apiKey, options) {
  const sent = [];
  foods.forEach((food, index) => {
    const candidates = candidateLists[index] || [];
    if (candidates.length === 0) return;
    sent.push({
      index,
      name: food.name,
      amount: food.amount,
      brand: food.brand,
      candidates: candidates.map((c) => ({
        fdcId: c.fdcId, description: c.description, dataType: c.dataType, brand: c.brand, portions: c.portions,
      })),
    });
  });
  const picks = foods.map(() => null);
  if (sent.length === 0) return picks;

  const raw = jsonArray(await callSonar(PICK_PROMPT, JSON.stringify({ foods: sent }), apiKey, options));
  const sentIndexes = new Set(sent.map((s) => s.index));
  for (const pick of raw) {
    if (pick && typeof pick === "object" && sentIndexes.has(pick.index)) picks[pick.index] = pick;
  }
  return picks;
}

function findCandidate(pick, candidates) {
  if (!pick || typeof pick !== "object") return null;
  const id = typeof pick.fdcId === "string" && /^\d+$/.test(pick.fdcId) ? Number(pick.fdcId) : pick.fdcId;
  return candidates.find((c) => c.fdcId === id) || null;
}

/**
 * The standard portion for a no-amount pick: the "typical serving" if the
 * candidate has one, else its first non-synthetic portion. The synthetic
 * 100 g portion (added to every candidate so it can always be weighed) is
 * never picked here: with no amount from the user, serving 100 g would be a
 * silent guess, not something anyone asked for.
 */
function standardPortion(candidate) {
  return (
    candidate.portions.find((p) => p.label === "typical serving") ||
    candidate.portions.find((p) => p.id !== "100g") ||
    null
  );
}

/**
 * Lowercased words for brand matching on token boundaries. `'`, `’`, `&`, `-`
 * and `.` are dropped outright (so "H-E-B", "HEB" and "A&W" tokenize the way
 * people actually write them); anything else non-alphanumeric becomes a
 * space, and runs of whitespace collapse. A raw substring match would let
 * "A&W" match "str-AW-berry" or "Sonic" match "super-SONIC-burger"; this
 * keeps the match to whole words only.
 */
function tokens(s) {
  return String(s)
    .toLowerCase()
    .replace(/['’&\-.]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** Whether the candidate's description or brand names the given brand, as a whole word. */
function carriesBrand(candidate, brand) {
  const needle = tokens(brand);
  if (!needle) return false;
  const wrap = (s) => ` ${tokens(s)} `;
  const target = ` ${needle} `;
  return wrap(candidate.description).includes(target) || wrap(candidate.brand || "").includes(target);
}

/** Whether the user's own words for an amount state an actual weight, e.g. "200 g" or "8 oz". */
const STATES_A_WEIGHT = /\d\s*(g|grams?|oz|ounces?|lbs?|pounds?)\b/i;

/**
 * A pick the server can use, or null. The ID must be a candidate that was
 * sent. When the food names a brand, the candidate must carry it (in its
 * description or brand field). When the user gave an amount, the portion
 * must be one of the candidate's portions and the count must be sane. When
 * they gave no amount, the model's portion and count are ignored: the server
 * uses the standard portion with count 1.
 *
 * @param {{amount: string|null, brand: string|null}} food - the user's amount and named brand
 * @returns {{candidate: object, portion: object, count: number}|null}
 */
function validatePick(pick, candidates, food) {
  const candidate = findCandidate(pick, candidates);
  if (!candidate) return null;
  if (food.brand !== null && !carriesBrand(candidate, food.brand)) return null;

  if (food.amount === null) {
    const portion = standardPortion(candidate);
    if (!portion) return null;
    return { candidate, portion, count: 1 };
  }

  // The 100 g portion is a weighing fallback, not a serving anyone described. With a stated
  // amount, it's only a sane match when that amount is itself a weight ("200 g", "8 oz") - not a
  // count or a vague amount ("a", "a bowl of"), which would silently misreport the serving size.
  if (pick.portionId === "100g" && !STATES_A_WEIGHT.test(food.amount)) return null;

  const portion = candidate.portions.find((p) => p.id === pick.portionId);
  if (!portion) return null;
  const count = pick.count;
  if (typeof count !== "number" || !Number.isFinite(count) || count < 0.25 || count > 20) return null;
  return { candidate, portion, count };
}

module.exports = { parseFoods, pickMatches, validatePick, ParseError };
