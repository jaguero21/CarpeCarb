/**
 * The two search-off model calls in a USDA lookup: split the text into foods,
 * then pick an FDC entry and portion for each. The model names things here; it
 * never supplies a nutrition number.
 */

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
  '"query" (string: a short FoodData Central search phrase for it; keep a brand or chain name, ' +
  "e.g. \"McDonald's Chicken McNuggets\"; leave out quantities), " +
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
  "If the user named no brand or chain, choose a generic entry; choose a brand or restaurant entry " +
  '(for example "Hamburger (Burger King)") only if no generic entry is the same food. ' +
  "If the user gave no amount, set portionId and count to null; the server uses the standard portion. " +
  "If the user gave an amount, choose the portion and count that give it: \"10\" nuggets with a \"4 pieces\" portion is count 2.5. " +
  "If nothing matches, fdcId is null. Never give nutrition values.";

async function callSonar(system, user, apiKey, { fetchImpl = fetch, timeoutMs, billing }) {
  let res;
  try {
    res = await fetchImpl(SONAR_URL, {
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
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    throw new ParseError(err && err.name === "TimeoutError" ? "timeout" : "network");
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
    const brand = item.brand === undefined ? null : item.brand;
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

/** The standard portion: the "typical serving" if the candidate has one, else its first portion. */
function standardPortion(candidate) {
  return candidate.portions.find((p) => p.label === "typical serving") || candidate.portions[0] || null;
}

/**
 * A pick the server can use, or null. The ID must be a candidate that was
 * sent. When the user gave an amount, the portion must be one of the
 * candidate's portions and the count must be sane. When they gave no amount,
 * the model's portion and count are ignored: the server uses the standard
 * portion with count 1.
 *
 * @param {string|null} amount - the user's own words for the amount, or null
 * @returns {{candidate: object, portion: object, count: number}|null}
 */
function validatePick(pick, candidates, amount) {
  const candidate = findCandidate(pick, candidates);
  if (!candidate) return null;

  if (amount === null) {
    const portion = standardPortion(candidate);
    if (!portion) return null;
    return { candidate, portion, count: 1 };
  }

  const portion = candidate.portions.find((p) => p.id === pick.portionId);
  if (!portion) return null;
  const count = pick.count;
  if (typeof count !== "number" || !Number.isFinite(count) || count < 0.25 || count > 20) return null;
  return { candidate, portion, count };
}

module.exports = { parseFoods, pickMatches, validatePick, ParseError };
