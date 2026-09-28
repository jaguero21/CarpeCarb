# USDA FoodData Central Lookup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Food lookups take their nutrition numbers from USDA FoodData Central, calculated by the server, and fall back to today's Perplexity web lookup only for foods USDA can't match.

**Architecture:** Perplexity `sonar` with search disabled splits the text into foods (`foodParse.js`). The server searches FDC for each one (`usda.js`). A second search-off `sonar` call picks an FDC entry, portion and count for all foods at once, using IDs only. The server validates the pick and multiplies USDA's per-100 g values by the portion grams. `lookup.js` orchestrates this with time budgets and hands unmatched foods to the existing `lookupFoods` in `perplexity.js`. The response shape is unchanged, so the app and Siri need no update.

**Tech Stack:** Node 22, Firebase Functions v2 (`firebase-functions` ^6), `node:test`, global `fetch`, `AbortSignal.timeout`.

**Spec:** `docs/superpowers/specs/2026-09-28-usda-lookup-design.md`

## Global Constraints

- The model never supplies a nutrition number on the USDA path. Every value is `per100g × grams × count / 100`, rounded to 1 decimal.
- A nutrient USDA does not list is `null`, never `0`.
- The pick must name an `fdcId` from the candidates sent, a `portionId` belonging to that candidate, and a `count` with `0.25 ≤ count ≤ 20`. Anything else means no match.
- Any USDA-path failure sends the affected foods to the web fallback. It never fails the request by itself.
- Parse failure → the whole request goes to `lookupFoods(sanitized)` (today's behavior).
- Time budgets: USDA path 12 000 ms, overall 25 000 ms, each USDA HTTP call ≤ 4 000 ms, each search-off sonar call ≤ 6 000 ms.
- Billing: a free lookup is refunded only if **no** Perplexity call in the request returned 2xx. The existing `notBilled` / `isNotBilled` marker in `functions/src/perplexity.js` is the mechanism.
- Never log food text, search queries, model output, or the USDA key. Log stage, counts, error codes and milliseconds only.
- Fallback items get `details` prefixed with `"Web source, not USDA. "`.
- USDA item `details`: `"USDA FoodData Central (<dataType>): <description>[, <brand>], <amount> (<grams> g)."`. `citations` gains `https://fdc.nal.usda.gov/food-details/<fdcId>/nutrients`.
- Search-off calls: `model: "sonar"`, `disable_search: true`, `temperature: 0`, `max_tokens: 1024`.
- Response shape stays `{ items: [{name, carbs, protein, fat, fiber, calories, details}], citations: string[] }`.
- Commits: no `Co-Authored-By` trailer and no "Generated with Claude Code" line, ever.
- Run tests from `functions/`: `npm test`.

## File Structure

| File | Responsibility |
|---|---|
| `functions/src/usda.js` (create) | FDC HTTP calls, turning search results into candidates, portions, nutrition math |
| `functions/src/foodParse.js` (create) | search-off sonar calls: parse prompt, pick prompt, output validation |
| `functions/src/lookup.js` (create) | orchestration, budgets, fallback, billing, details text, logging |
| `functions/index.js` (modify) | new secret, `LOOKUP_SOURCE` kill switch, wiring |
| `functions/.env` (create) | `LOOKUP_SOURCE=usda` |
| `docs/privacy-policy.html` (modify) | one sentence about USDA |
| `functions/test/usda.test.js`, `foodParse.test.js`, `lookup.test.js` (create) | tests |

---

### Task 1: USDA client and nutrition math

**Files:**
- Create: `functions/src/usda.js`
- Test: `functions/test/usda.test.js`

**Interfaces:**
- Produces:
  - `class UsdaError extends Error`: thrown for any FDC HTTP, timeout or JSON failure. `message` is a short code, never a URL.
  - `searchCandidates(query: string, apiKey: string, { fetchImpl?, timeoutMs? }) → Promise<Candidate[]>`
  - `Candidate = { fdcId: number, description: string, dataType: string, brand: string|null, per100g: {carbs: number, protein: number|null, fat: number|null, fiber: number|null, calories: number|null}, portions: [{id: string, label: string, grams: number}] }`. Every candidate's last portion is `{id: "100g", label: "100 g", grams: 100}`.
  - `nutritionFor(candidate, portion, count) → {carbs, protein, fat, fiber, calories, grams}`: values are rounded to 1 decimal (null stays null), and `grams` is rounded to an integer.

- [ ] **Step 1: Write the failing tests**

Create `functions/test/usda.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const { searchCandidates, nutritionFor, UsdaError } = require("../src/usda");

// Trimmed from real FoodData Central responses (2026-09-28).
const NUGGETS_SR = {
  fdcId: 173297, dataType: "SR Legacy", description: "McDONALD'S, Chicken McNUGGETS", foodMeasures: [],
  foodNutrients: [
    { nutrientId: 1003, value: 15.8 }, { nutrientId: 1004, value: 19.8 },
    { nutrientId: 1005, value: 15.1 }, { nutrientId: 1008, value: 302 },
  ],
};
const PHO_FNDDS = {
  fdcId: 2707124, dataType: "Survey (FNDDS)", description: "Soup, pho, with meat",
  foodMeasures: [
    { disseminationText: "1 cup", gramWeight: 245 },
    { disseminationText: "Quantity not specified", gramWeight: 245 },
  ],
  foodNutrients: [
    { nutrientId: 1003, value: 5.81 }, { nutrientId: 1004, value: 3.33 }, { nutrientId: 1005, value: 5.6 },
    { nutrientId: 1008, value: 77 }, { nutrientId: 1079, value: 0.4 },
  ],
};
const TORTILLA_BRANDED = {
  fdcId: 2104027, dataType: "Branded", description: "FAJITA TORTILLAS", brandOwner: "Price Chopper Supermarkets",
  servingSize: 45.0, servingSizeUnit: "g", householdServingFullText: "1 TORTILLA", foodMeasures: [],
  foodNutrients: [
    { nutrientId: 1003, value: 8.89 }, { nutrientId: 1004, value: 8.89 }, { nutrientId: 1005, value: 46.7 },
    { nutrientId: 1008, value: 289 }, { nutrientId: 1079, value: 2.2 },
  ],
};
const BROTH_BRANDED_ML = {
  fdcId: 2305002, dataType: "Branded", description: "PHO BROTH, PHO", brandOwner: "New Seasons Market, LLC",
  servingSize: 177.0, servingSizeUnit: "ml", householdServingFullText: "6 OZA", foodMeasures: [],
  foodNutrients: [{ nutrientId: 1005, value: 3.39 }, { nutrientId: 1008, value: 17.0 }],
};
// The details endpoint's portions for 173297, as FDC returns them.
const NUGGETS_DETAILS = [{
  fdcId: 173297, dataType: "SR Legacy",
  foodPortions: [
    { gramWeight: 95.0, amount: 6.0, modifier: "pieces", measureUnit: { name: "undetermined" } },
    { gramWeight: 64.0, amount: 4.0, modifier: "pieces", measureUnit: { name: "undetermined" } },
    { gramWeight: 159.0, amount: 10.0, modifier: "pieces", measureUnit: { name: "undetermined" } },
  ],
}];

function json(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

/** Routes FDC calls by path and records each request. */
function fdc({ search, details = [] }) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body), signal: init.signal });
    if (url.includes("/foods/search")) return typeof search === "function" ? search() : json(search);
    return typeof details === "function" ? details() : json(details);
  };
  return { fetchImpl, calls };
}

test("searchCandidates sends the query to FDC search with the four data types", async () => {
  const { fetchImpl, calls } = fdc({ search: { foods: [PHO_FNDDS] } });

  await searchCandidates("pho", "KEY", { fetchImpl });

  assert.match(calls[0].url, /^https:\/\/api\.nal\.usda\.gov\/fdc\/v1\/foods\/search\?api_key=KEY$/);
  assert.deepEqual(calls[0].body, {
    query: "pho", pageSize: 8, dataType: ["Survey (FNDDS)", "SR Legacy", "Foundation", "Branded"],
  });
  assert.ok(calls[0].signal, "every FDC call has a timeout");
});

test("a survey food keeps its per-100 g values and listed portions, plus 100 g", async () => {
  const { fetchImpl, calls } = fdc({ search: { foods: [PHO_FNDDS] } });

  const [pho] = await searchCandidates("pho", "KEY", { fetchImpl });

  assert.deepEqual(pho, {
    fdcId: 2707124, description: "Soup, pho, with meat", dataType: "Survey (FNDDS)", brand: null,
    per100g: { carbs: 5.6, protein: 5.81, fat: 3.33, fiber: 0.4, calories: 77 },
    portions: [
      { id: "p1", label: "1 cup", grams: 245 },
      { id: "p2", label: "typical serving", grams: 245 },
      { id: "100g", label: "100 g", grams: 100 },
    ],
  });
  assert.equal(calls.length, 1, "no details call when search already has portions");
});

test("an SR Legacy food gets its portions from one details call", async () => {
  const { fetchImpl, calls } = fdc({ search: { foods: [NUGGETS_SR] }, details: NUGGETS_DETAILS });

  const [nuggets] = await searchCandidates("McDonald's Chicken McNuggets", "KEY", { fetchImpl });

  assert.match(calls[1].url, /\/fdc\/v1\/foods\?api_key=KEY$/);
  assert.deepEqual(calls[1].body, { fdcIds: [173297], format: "full" });
  assert.deepEqual(nuggets.portions, [
    { id: "p1", label: "6 pieces", grams: 95 },
    { id: "p2", label: "4 pieces", grams: 64 },
    { id: "p3", label: "10 pieces", grams: 159 },
    { id: "100g", label: "100 g", grams: 100 },
  ]);
  // A nutrient the record doesn't list is unknown, not 0.
  assert.equal(nuggets.per100g.fiber, null);
});

test("a failed details call leaves the candidate usable by weight", async () => {
  const { fetchImpl } = fdc({ search: { foods: [NUGGETS_SR] }, details: () => json({}, 503) });

  const [nuggets] = await searchCandidates("nuggets", "KEY", { fetchImpl });

  assert.deepEqual(nuggets.portions, [{ id: "100g", label: "100 g", grams: 100 }]);
});

test("a branded food's serving comes from the label", async () => {
  const { fetchImpl } = fdc({ search: { foods: [TORTILLA_BRANDED] } });

  const [tortilla] = await searchCandidates("fajita tortilla", "KEY", { fetchImpl });

  assert.equal(tortilla.brand, "Price Chopper Supermarkets");
  assert.deepEqual(tortilla.portions, [
    { id: "p1", label: "1 TORTILLA", grams: 45 },
    { id: "100g", label: "100 g", grams: 100 },
  ]);
});

test("foods measured in ml or without a carb value are not candidates", async () => {
  // Per-100 values for an ml product are per 100 ml; weighing them as grams is wrong.
  const noCarbs = { ...PHO_FNDDS, fdcId: 1, foodNutrients: [{ nutrientId: 1008, value: 50 }] };
  const { fetchImpl } = fdc({ search: { foods: [BROTH_BRANDED_ML, noCarbs, PHO_FNDDS] } });

  const found = await searchCandidates("pho", "KEY", { fetchImpl });

  assert.deepEqual(found.map((c) => c.fdcId), [2707124]);
});

test("a real zero carb value is kept", async () => {
  const water = { ...PHO_FNDDS, fdcId: 2, foodNutrients: [{ nutrientId: 1005, value: 0 }] };
  const { fetchImpl } = fdc({ search: { foods: [water] } });

  const [c] = await searchCandidates("water", "KEY", { fetchImpl });

  assert.equal(c.per100g.carbs, 0);
});

test("search failures surface as UsdaError without the key", async () => {
  const cases = [
    () => json({ error: { code: "OVER_RATE_LIMIT" } }, 429),
    () => json({}, 500),
    () => { throw Object.assign(new Error("aborted"), { name: "TimeoutError" }); },
    () => { throw new TypeError("fetch failed"); },
    () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError("bad"); } }),
  ];
  for (const search of cases) {
    const { fetchImpl } = fdc({ search });
    await assert.rejects(searchCandidates("pho", "SECRETKEY", { fetchImpl }), (err) => {
      assert.ok(err instanceof UsdaError);
      assert.doesNotMatch(err.message, /SECRETKEY/);
      return true;
    });
  }
});

test("a search with no foods is an empty list", async () => {
  const { fetchImpl } = fdc({ search: { totalHits: 0, foods: [] } });

  assert.deepEqual(await searchCandidates("zzzz", "KEY", { fetchImpl }), []);
});

test("nutritionFor scales per-100 g values by portion and count", () => {
  const pho = {
    per100g: { carbs: 5.6, protein: 5.81, fat: 3.33, fiber: 0.4, calories: 77 },
  };
  assert.deepEqual(nutritionFor(pho, { grams: 245 }, 1), {
    carbs: 13.7, protein: 14.2, fat: 8.2, fiber: 1, calories: 188.7, grams: 245,
  });

  const nuggets = { per100g: { carbs: 15.1, protein: 15.8, fat: 19.8, fiber: null, calories: 302 } };
  const four = nutritionFor(nuggets, { grams: 64 }, 1);
  assert.equal(four.carbs, 9.7);
  assert.equal(four.fiber, null);
  assert.equal(nutritionFor(nuggets, { grams: 64 }, 2.5).carbs, 24.2);
  assert.equal(nutritionFor(nuggets, { grams: 64 }, 2.5).grams, 160);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd functions && node --test test/usda.test.js`
Expected: FAIL with `Cannot find module '../src/usda'`.

- [ ] **Step 3: Implement `functions/src/usda.js`**

```js
/**
 * USDA FoodData Central: search, portions, and the nutrition math.
 *
 * Every number the USDA lookup reports comes from here, calculated from FDC's
 * per-100 g values. The model only ever names an entry and a portion.
 */

const USDA_BASE = "https://api.nal.usda.gov/fdc/v1";
const DATA_TYPES = ["Survey (FNDDS)", "SR Legacy", "Foundation", "Branded"];
const SEARCH_PAGE_SIZE = 8;
const NUTRIENT = { carbs: 1005, protein: 1003, fat: 1004, fiber: 1079 };
// Energy in kcal. Foundation foods sometimes list only the Atwater values.
const KCAL = [1008, 2047, 2048];
const HUNDRED_GRAMS = { id: "100g", label: "100 g", grams: 100 };

/** Any FDC failure. The message is a short code and never carries the URL, which holds the key. */
class UsdaError extends Error {}

async function usdaPost(path, apiKey, body, { fetchImpl, timeoutMs }) {
  let res;
  try {
    res = await fetchImpl(`${USDA_BASE}${path}?api_key=${encodeURIComponent(apiKey)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    throw new UsdaError(err && err.name === "TimeoutError" ? "timeout" : "network");
  }
  if (!res.ok) throw new UsdaError(`status ${res.status}`);
  try {
    return await res.json();
  } catch {
    throw new UsdaError("bad json");
  }
}

function per100g(food, ids) {
  for (const id of ids) {
    const n = (food.foodNutrients || []).find((x) => x && x.nutrientId === id);
    if (n && Number.isFinite(n.value) && n.value >= 0) return n.value;
  }
  return null;
}

function isGrams(unit) {
  return typeof unit === "string" && /^(g|grm|gram|grams)$/i.test(unit.trim());
}

function addPortion(portions, label, grams) {
  if (typeof label !== "string" || !label.trim()) return;
  if (!Number.isFinite(grams) || grams <= 0) return;
  // FNDDS's own name for its typical-intake portion.
  const text = label.trim() === "Quantity not specified" ? "typical serving" : label.trim();
  portions.push({ label: text, grams });
}

/** A details-endpoint portion's label: FNDDS describes it; SR Legacy and Foundation compose it. */
function portionLabel(p) {
  if (typeof p.portionDescription === "string" && p.portionDescription.trim()) {
    return p.portionDescription;
  }
  const unit = p.measureUnit && p.measureUnit.name && p.measureUnit.name !== "undetermined" ? p.measureUnit.name : "";
  return [Number.isFinite(p.amount) ? String(p.amount) : "", unit, typeof p.modifier === "string" ? p.modifier : ""]
    .filter(Boolean)
    .join(" ");
}

function toCandidate(food) {
  if (!food || !Number.isInteger(food.fdcId) || typeof food.description !== "string") return null;
  const carbs = per100g(food, [NUTRIENT.carbs]);
  if (carbs === null) return null;
  const branded = food.dataType === "Branded";
  // Branded per-100 values follow the label's unit; per 100 ml can't be weighed.
  if (branded && !isGrams(food.servingSizeUnit)) return null;

  const portions = [];
  if (branded) {
    addPortion(portions, food.householdServingFullText || "1 serving", food.servingSize);
  } else {
    for (const m of food.foodMeasures || []) addPortion(portions, m && m.disseminationText, m && m.gramWeight);
  }
  return {
    fdcId: food.fdcId,
    description: food.description,
    dataType: food.dataType,
    brand: food.brandOwner || food.brandName || null,
    per100g: {
      carbs,
      protein: per100g(food, [NUTRIENT.protein]),
      fat: per100g(food, [NUTRIENT.fat]),
      fiber: per100g(food, [NUTRIENT.fiber]),
      calories: per100g(food, KCAL),
    },
    portions,
  };
}

function withPortionIds(candidate) {
  return {
    ...candidate,
    portions: [...candidate.portions.map((p, i) => ({ id: `p${i + 1}`, ...p })), HUNDRED_GRAMS],
  };
}

/**
 * Searches FDC and returns usable candidates, best match first.
 *
 * @param {string} query
 * @param {string} apiKey
 * @param {{fetchImpl?: typeof fetch, timeoutMs?: number}} [options]
 * @returns {Promise<object[]>}
 * @throws {UsdaError} when the search itself fails
 */
async function searchCandidates(query, apiKey, { fetchImpl = fetch, timeoutMs = 4000 } = {}) {
  const found = await usdaPost(
    "/foods/search",
    apiKey,
    { query, pageSize: SEARCH_PAGE_SIZE, dataType: DATA_TYPES },
    { fetchImpl, timeoutMs }
  );
  const candidates = (Array.isArray(found && found.foods) ? found.foods : []).map(toCandidate).filter(Boolean);

  // SR Legacy and Foundation results carry no portions; one details call fetches them all.
  const needPortions = candidates.filter((c) => c.portions.length === 0 && c.dataType !== "Branded");
  if (needPortions.length > 0) {
    try {
      const details = await usdaPost(
        "/foods",
        apiKey,
        { fdcIds: needPortions.map((c) => c.fdcId), format: "full" },
        { fetchImpl, timeoutMs }
      );
      for (const food of Array.isArray(details) ? details : []) {
        const c = needPortions.find((x) => food && x.fdcId === food.fdcId);
        if (!c) continue;
        for (const p of food.foodPortions || []) addPortion(c.portions, portionLabel(p), p.gramWeight);
      }
    } catch (err) {
      if (!(err instanceof UsdaError)) throw err;
      // Portions are a convenience: every candidate can still be weighed in 100 g.
    }
  }
  return candidates.map(withPortionIds);
}

const round1 = (v) => Math.round(v * 10) / 10;

/**
 * The nutrition for `count` of `portion` of `candidate`.
 *
 * @returns {{carbs: number, protein: number|null, fat: number|null, fiber: number|null, calories: number|null, grams: number}}
 */
function nutritionFor(candidate, portion, count) {
  const grams = portion.grams * count;
  const scale = (value) => (value === null ? null : round1((value * grams) / 100));
  const p = candidate.per100g;
  return {
    carbs: scale(p.carbs),
    protein: scale(p.protein),
    fat: scale(p.fat),
    fiber: scale(p.fiber),
    calories: scale(p.calories),
    grams: Math.round(grams),
  };
}

module.exports = { searchCandidates, nutritionFor, UsdaError };
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd functions && node --test test/usda.test.js`
Expected: all pass. Then `npm test`: all pass.

- [ ] **Step 5: Commit**

```bash
git add functions/src/usda.js functions/test/usda.test.js
git commit -m "feat(lookup): USDA FoodData Central client and nutrition math"
```

---

### Task 2: Parse and pick with search-off sonar

**Files:**
- Create: `functions/src/foodParse.js`
- Test: `functions/test/foodParse.test.js`

**Interfaces:**
- Consumes: the `Candidate` shape from Task 1 (`fdcId`, `description`, `dataType`, `brand`, `portions[{id,label,grams}]`).
- Produces:
  - `class ParseError extends Error`: any sonar call or output failure. `message` is a short code.
  - `parseFoods(text, apiKey, { fetchImpl?, timeoutMs, billing }) → Promise<Food[]>`, where `Food = {name: string, query: string, amount: string|null, text: string}` and there are 1–10 of them.
  - `pickMatches(foods, candidateLists, apiKey, { fetchImpl?, timeoutMs, billing }) → Promise<(object|null)[]>`: raw picks aligned with `foods`. Foods whose list is empty get `null` and are not sent.
  - `validatePick(pick, candidates) → {candidate, portion, count} | null`
  - `billing` is a caller-owned `{billed: boolean}`. It is set `true` as soon as any sonar call returns 2xx.

- [ ] **Step 1: Write the failing tests**

Create `functions/test/foodParse.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const { parseFoods, pickMatches, validatePick, ParseError } = require("../src/foodParse");

function completion(content) {
  return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content } }] }) };
}
function status(code) {
  return { ok: false, status: code, json: async () => ({}) };
}
/** A sonar stand-in returning `responses` in order and recording request bodies. */
function sonar(...responses) {
  const bodies = [];
  const fetchImpl = async (_url, init) => {
    bodies.push(JSON.parse(init.body));
    const next = responses[Math.min(bodies.length, responses.length) - 1];
    if (next instanceof Error) throw next;
    return next;
  };
  return { fetchImpl, bodies };
}
const opts = (fetchImpl, billing = { billed: false }) => ({ fetchImpl, timeoutMs: 6000, billing });

const PHO = {
  fdcId: 2707124, description: "Soup, pho, with meat", dataType: "Survey (FNDDS)", brand: null,
  per100g: { carbs: 5.6, protein: 5.81, fat: 3.33, fiber: 0.4, calories: 77 },
  portions: [
    { id: "p1", label: "1 cup", grams: 245 },
    { id: "p2", label: "typical serving", grams: 245 },
    { id: "100g", label: "100 g", grams: 100 },
  ],
};

// ── parseFoods ──

test("parseFoods calls sonar with search off and returns the foods", async () => {
  const { fetchImpl, bodies } = sonar(completion(
    '[{"name":"pho","query":"pho","amount":"a bowl of","text":"a bowl of pho"},' +
    '{"name":"McDonald\'s nuggets","query":"McDonald\'s Chicken McNuggets","amount":"10","text":"10 mcdonalds nuggets"}]'
  ));
  const billing = { billed: false };

  const foods = await parseFoods("a bowl of pho and 10 mcdonalds nuggets", "KEY", opts(fetchImpl, billing));

  assert.deepEqual(foods, [
    { name: "pho", query: "pho", amount: "a bowl of", text: "a bowl of pho" },
    { name: "McDonald's nuggets", query: "McDonald's Chicken McNuggets", amount: "10", text: "10 mcdonalds nuggets" },
  ]);
  assert.equal(bodies[0].model, "sonar");
  assert.equal(bodies[0].disable_search, true);
  assert.equal(bodies[0].temperature, 0);
  assert.equal(bodies[0].messages[1].content, "a bowl of pho and 10 mcdonalds nuggets");
  assert.match(bodies[0].messages[0].content, /keep a brand or chain name/i);
  assert.equal(billing.billed, true);
});

test("parseFoods accepts fenced output and a missing amount", async () => {
  const { fetchImpl } = sonar(completion('```json\n[{"name":"pizza","query":"pizza","text":"pizza"}]\n```'));

  const [food] = await parseFoods("pizza", "KEY", opts(fetchImpl));

  assert.equal(food.amount, null);
});

test("parseFoods rejects output that is not a usable food list", async () => {
  for (const content of [
    "no json here",
    "[]",
    '[{"name":"pizza"}]',
    '[{"name":"","query":"pizza","text":"pizza"}]',
    '[{"name":"pizza","query":"pizza","text":"pizza","amount":3}]',
    JSON.stringify(Array.from({ length: 11 }, () => ({ name: "a", query: "a", text: "a" }))),
  ]) {
    const { fetchImpl } = sonar(completion(content));
    await assert.rejects(parseFoods("pizza", "KEY", opts(fetchImpl)), ParseError, content);
  }
});

test("a sonar failure is a ParseError, billed only on 2xx", async () => {
  for (const [response, billed] of [
    [status(500), false],
    [status(429), false],
    [Object.assign(new Error("t"), { name: "TimeoutError" }), false],
    [{ ok: true, status: 200, json: async () => ({ choices: [] }) }, true],
  ]) {
    const billing = { billed: false };
    const { fetchImpl } = sonar(response);
    await assert.rejects(parseFoods("pizza", "KEY", opts(fetchImpl, billing)), ParseError);
    assert.equal(billing.billed, billed);
  }
});

// ── pickMatches ──

test("pickMatches sends one call for all foods with candidates, IDs and portions only", async () => {
  const { fetchImpl, bodies } = sonar(completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":3}]'));
  const foods = [
    { name: "pho", query: "pho", amount: "a bowl of", text: "a bowl of pho" },
    { name: "zzz", query: "zzz", amount: null, text: "zzz" },
  ];

  const picks = await pickMatches(foods, [[PHO], []], "KEY", opts(fetchImpl));

  assert.equal(bodies.length, 1);
  assert.equal(bodies[0].disable_search, true);
  const sent = JSON.parse(bodies[0].messages[1].content);
  assert.deepEqual(sent, {
    foods: [{
      index: 0, name: "pho", amount: "a bowl of",
      candidates: [{
        fdcId: 2707124, description: "Soup, pho, with meat", dataType: "Survey (FNDDS)", brand: null,
        portions: PHO.portions,
      }],
    }],
  });
  // The model is never shown nutrition values, so it can't echo or invent them.
  assert.doesNotMatch(bodies[0].messages[1].content, /per100g|carbs/);
  assert.deepEqual(picks, [{ index: 0, fdcId: 2707124, portionId: "p1", count: 3 }, null]);
});

test("pickMatches makes no call when no food has candidates", async () => {
  const { fetchImpl, bodies } = sonar(completion("[]"));

  const picks = await pickMatches([{ name: "a", query: "a", amount: null, text: "a" }], [[]], "KEY", opts(fetchImpl));

  assert.equal(bodies.length, 0);
  assert.deepEqual(picks, [null]);
});

test("pickMatches ignores picks for indexes it did not send", async () => {
  const { fetchImpl } = sonar(completion('[{"index":5,"fdcId":1,"portionId":"p1","count":1}]'));

  const picks = await pickMatches([{ name: "pho", query: "pho", amount: null, text: "pho" }], [[PHO]], "KEY", opts(fetchImpl));

  assert.deepEqual(picks, [null]);
});

test("the pick prompt forbids other brands and nutrition values", async () => {
  const { fetchImpl, bodies } = sonar(completion("[]"));
  await pickMatches([{ name: "pho", query: "pho", amount: null, text: "pho" }], [[PHO]], "KEY", opts(fetchImpl));

  const system = bodies[0].messages[0].content;
  assert.match(system, /only a candidate from that brand or chain/i);
  assert.match(system, /Never give nutrition values/);
});

// ── validatePick ──

test("validatePick accepts a pick naming a sent candidate, its portion and a sane count", () => {
  assert.deepEqual(validatePick({ fdcId: 2707124, portionId: "p1", count: 3 }, [PHO]), {
    candidate: PHO, portion: PHO.portions[0], count: 3,
  });
  // Some models quote numbers.
  assert.equal(validatePick({ fdcId: "2707124", portionId: "100g", count: 0.25 }, [PHO]).count, 0.25);
});

test("validatePick rejects anything else", () => {
  for (const pick of [
    null,
    "2707124",
    { fdcId: null, portionId: null, count: null },
    { fdcId: 999, portionId: "p1", count: 1 },
    { fdcId: 2707124, portionId: "p9", count: 1 },
    { fdcId: 2707124, portionId: "p1", count: 0 },
    { fdcId: 2707124, portionId: "p1", count: 0.2 },
    { fdcId: 2707124, portionId: "p1", count: 21 },
    { fdcId: 2707124, portionId: "p1", count: "2" },
    { fdcId: 2707124, portionId: "p1", count: NaN },
    { fdcId: "27x", portionId: "p1", count: 1 },
  ]) {
    assert.equal(validatePick(pick, [PHO]), null, JSON.stringify(pick));
  }
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd functions && node --test test/foodParse.test.js`
Expected: FAIL with `Cannot find module '../src/foodParse'`.

- [ ] **Step 3: Implement `functions/src/foodParse.js`**

```js
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
  '"text" (string: the user\'s words for this food, amount included, copied exactly). ' +
  "Do not give nutrition values.";

const PICK_PROMPT =
  "You match foods to USDA FoodData Central entries. The user message is JSON: foods, each with the amount " +
  "the user gave and candidate entries with their portions. For each food choose the candidate that is the " +
  "same food, then the portion and count that match the amount. Reply with ONLY a JSON array, one element per " +
  'food: {"index": number, "fdcId": number or null, "portionId": string or null, "count": number or null}. ' +
  "Rules: Choose a candidate only if it is the same food. A different dish, a different form (broth for a soup, " +
  "raw for cooked) or an ingredient of it is not a match. " +
  "If the user named a brand or chain, only a candidate from that brand or chain matches; if there is none, fdcId is null. " +
  'If the user gave no amount, use the portion labelled "typical serving" if there is one, else the first portion, with count 1. ' +
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
 * @returns {Promise<{name: string, query: string, amount: string|null, text: string}[]>}
 * @throws {ParseError}
 */
async function parseFoods(text, apiKey, options) {
  const raw = jsonArray(await callSonar(PARSE_PROMPT, text, apiKey, options));
  if (raw.length === 0 || raw.length > MAX_FOODS) throw new ParseError("food count");
  return raw.map((item) => {
    if (!item || typeof item !== "object") throw new ParseError("item");
    const amount = item.amount === undefined ? null : item.amount;
    if (!isField(item.name) || !isField(item.query) || !isField(item.text)) throw new ParseError("fields");
    if (amount !== null && !isField(amount)) throw new ParseError("amount");
    return { name: item.name.trim(), query: item.query.trim(), amount: amount && amount.trim(), text: item.text.trim() };
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

/**
 * A pick the server can use, or null. The ID must be a candidate that was
 * sent, the portion must be one of its portions, and the count must be sane.
 *
 * @returns {{candidate: object, portion: object, count: number}|null}
 */
function validatePick(pick, candidates) {
  if (!pick || typeof pick !== "object") return null;
  const id = typeof pick.fdcId === "string" && /^\d+$/.test(pick.fdcId) ? Number(pick.fdcId) : pick.fdcId;
  const candidate = candidates.find((c) => c.fdcId === id);
  if (!candidate) return null;
  const portion = candidate.portions.find((p) => p.id === pick.portionId);
  if (!portion) return null;
  const count = pick.count;
  if (typeof count !== "number" || !Number.isFinite(count) || count < 0.25 || count > 20) return null;
  return { candidate, portion, count };
}

module.exports = { parseFoods, pickMatches, validatePick, ParseError };
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd functions && node --test test/foodParse.test.js`
Expected: all pass. Then `npm test`: all pass.

- [ ] **Step 5: Commit**

```bash
git add functions/src/foodParse.js functions/test/foodParse.test.js
git commit -m "feat(lookup): parse and pick foods with search-off sonar"
```

---

### Task 3: Orchestrator with budgets, fallback and billing

**Files:**
- Create: `functions/src/lookup.js`
- Test: `functions/test/lookup.test.js`

**Interfaces:**
- Consumes:
  - Task 1: `searchCandidates(query, apiKey, {fetchImpl, timeoutMs})`, `nutritionFor(candidate, portion, count)`, `UsdaError`.
  - Task 2: `parseFoods(text, apiKey, {fetchImpl, timeoutMs, billing})`, `pickMatches(foods, lists, apiKey, {fetchImpl, timeoutMs, billing})`, `validatePick(pick, candidates)`, `ParseError`.
  - Existing `functions/src/perplexity.js`: `lookupFoods(sanitized, apiKey, {fetchImpl, sleep})`, `sanitizeFoodInput(text)`, `isNotBilled(err)`.
- Produces: `lookupFoodsUsda(sanitized, {perplexityKey, usdaKey}, {fetchImpl?, now?, webLookup?}) → Promise<{items, citations}>`. Its error behavior matches `lookupFoods`: errors carry `notBilled: true` only when no Perplexity call in the request returned 2xx.

Test strategy: one `fetchImpl` routes by URL. Perplexity calls are told apart by `model`: `"sonar"` with `disable_search` is parse or pick (parse first, then pick), and the web fallback is injected as `webLookup` so its behavior is scripted directly. `now` is injected to exercise the budgets without real waiting.

- [ ] **Step 1: Write the failing tests**

Create `functions/test/lookup.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const { lookupFoodsUsda } = require("../src/lookup");
const { isNotBilled, notBilled } = require("../src/perplexity");

const PHO = {
  fdcId: 2707124, dataType: "Survey (FNDDS)", description: "Soup, pho, with meat",
  foodMeasures: [{ disseminationText: "1 cup", gramWeight: 245 }],
  foodNutrients: [
    { nutrientId: 1003, value: 5.81 }, { nutrientId: 1004, value: 3.33 }, { nutrientId: 1005, value: 5.6 },
    { nutrientId: 1008, value: 77 }, { nutrientId: 1079, value: 0.4 },
  ],
};
const KEYS = { perplexityKey: "PKEY", usdaKey: "UKEY" };

function json(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}
function completion(content) {
  return json({ choices: [{ message: { content } }] });
}

/**
 * parse / pick: sonar responses in call order (a Response, an Error to throw, or a function).
 * search: map of query → FDC search response (or function).
 */
function world({ parse, pick, search = {} }) {
  const seen = { sonar: 0, usda: 0 };
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    if (url.startsWith("https://api.perplexity.ai")) {
      seen.sonar += 1;
      const r = seen.sonar === 1 ? parse : pick;
      if (r instanceof Error) throw r;
      return typeof r === "function" ? r() : r;
    }
    seen.usda += 1;
    const r = search[body.query];
    if (r === undefined) return json({ foods: [] });
    return typeof r === "function" ? r() : r;
  };
  return { fetchImpl, seen };
}

const parsed = (...foods) => completion(JSON.stringify(foods));
const food = (name, amount = null) => ({ name, query: name, amount, text: amount ? `${amount} ${name}` : name });

function web(result) {
  const calls = [];
  const webLookup = async (text) => {
    calls.push(text);
    if (result instanceof Error) throw result;
    return typeof result === "function" ? result(text) : result;
  };
  return { webLookup, calls };
}

test("a USDA match is calculated by the server and cites FDC", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho", "a bowl of")),
    search: { pho: json({ foods: [PHO] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":3}]'),
  });
  const { webLookup, calls } = web(new Error("must not be called"));

  const res = await lookupFoodsUsda("a bowl of pho", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(res, {
    items: [{
      name: "pho", carbs: 41.2, protein: 42.7, fat: 24.5, fiber: 2.9, calories: 566,
      details: "USDA FoodData Central (Survey (FNDDS)): Soup, pho, with meat, 3 × 1 cup (735 g).",
    }],
    citations: ["https://fdc.nal.usda.gov/food-details/2707124/nutrients"],
  });
  assert.equal(calls.length, 0);
});

test("a count of 1 reads as the portion alone, and a brand is named", async () => {
  const branded = {
    fdcId: 2104027, dataType: "Branded", description: "FAJITA TORTILLAS", brandOwner: "Price Chopper Supermarkets",
    servingSize: 45, servingSizeUnit: "g", householdServingFullText: "1 TORTILLA",
    foodNutrients: [{ nutrientId: 1005, value: 46.7 }],
  };
  const { fetchImpl } = world({
    parse: parsed(food("fajita tortilla")),
    search: { "fajita tortilla": json({ foods: [branded] }) },
    pick: completion('[{"index":0,"fdcId":2104027,"portionId":"p1","count":1}]'),
  });

  const res = await lookupFoodsUsda("fajita tortilla", KEYS, { fetchImpl, webLookup: web({}).webLookup });

  assert.equal(res.items[0].details,
    "USDA FoodData Central (Branded): FAJITA TORTILLAS, Price Chopper Supermarkets, 1 TORTILLA (45 g).");
  assert.equal(res.items[0].carbs, 21);
  assert.equal(res.items[0].protein, null);
});

test("foods USDA can't match go to one web lookup, labelled, after the USDA foods", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho"), food("grandma's casserole"), food("chipotle bowl")),
    search: { pho: json({ foods: [PHO] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });
  const { webLookup, calls } = web({
    items: [
      { name: "Casserole", carbs: null, protein: null, fat: null, fiber: null, calories: null, details: "Not found." },
      { name: "Chipotle Bowl", carbs: 60, protein: 30, fat: 20, fiber: 10, calories: 600, details: "Chipotle US." },
    ],
    citations: ["https://chipotle.com"],
  });

  const res = await lookupFoodsUsda("pho, grandma's casserole and chipotle bowl", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(calls, ["grandma's casserole and chipotle bowl"]);
  assert.deepEqual(res.items.map((i) => i.name), ["pho", "Casserole", "Chipotle Bowl"]);
  assert.equal(res.items[1].details, "Web source, not USDA. Not found.");
  assert.equal(res.items[2].carbs, 60);
  assert.deepEqual(res.citations, ["https://fdc.nal.usda.gov/food-details/2707124/nutrients", "https://chipotle.com"]);
});

test("a pick that fails validation falls back instead of trusting it", async () => {
  for (const pick of [
    '[{"index":0,"fdcId":999,"portionId":"p1","count":1}]',
    '[{"index":0,"fdcId":2707124,"portionId":"p1","count":50}]',
    '[{"index":0,"fdcId":null,"portionId":null,"count":null}]',
    "not json",
  ]) {
    const { fetchImpl } = world({
      parse: parsed(food("pho")),
      search: { pho: json({ foods: [PHO] }) },
      pick: completion(pick),
    });
    const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

    const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, webLookup });

    assert.deepEqual(calls, ["pho"], pick);
    assert.equal(res.items[0].carbs, 40);
  }
});

test("USDA errors send the food to the web and the request still succeeds", async () => {
  for (const failure of [
    () => json({}, 429),
    () => json({}, 500),
    () => { throw Object.assign(new Error("t"), { name: "TimeoutError" }); },
  ]) {
    const { fetchImpl } = world({ parse: parsed(food("pho")), search: { pho: failure } });
    const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

    const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, webLookup });

    assert.deepEqual(calls, ["pho"]);
    assert.equal(res.items[0].carbs, 40);
  }
});

test("a failed parse sends the whole original text to the web lookup", async () => {
  for (const parse of [completion("no json"), json({}, 500)]) {
    const { fetchImpl } = world({ parse });
    const { webLookup, calls } = web({ items: [{ name: "Pizza", carbs: 35, details: "USDA slice" }], citations: [] });

    const res = await lookupFoodsUsda("pizza", KEYS, { fetchImpl, webLookup });

    assert.deepEqual(calls, ["pizza"]);
    assert.equal(res.items[0].details, "Web source, not USDA. USDA slice");
  }
});

test("an unbilled failure stays refundable only if nothing was billed", async () => {
  // Parse 5xx (not billed) then web 5xx (not billed): refund.
  let w = world({ parse: json({}, 500) });
  await assert.rejects(
    lookupFoodsUsda("pizza", KEYS, { fetchImpl: w.fetchImpl, webLookup: web(notBilled(new Error("5xx"))).webLookup }),
    (err) => isNotBilled(err)
  );

  // Parse billed but unusable, then web 5xx: the parse call cost money, so no refund.
  w = world({ parse: completion("no json") });
  await assert.rejects(
    lookupFoodsUsda("pizza", KEYS, { fetchImpl: w.fetchImpl, webLookup: web(notBilled(new Error("5xx"))).webLookup }),
    (err) => !isNotBilled(err)
  );
});

test("when the web fallback fails, USDA foods still return and the rest are unknown", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho"), food("mystery")),
    search: { pho: json({ foods: [PHO] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });

  const res = await lookupFoodsUsda("pho and mystery", KEYS, {
    fetchImpl, webLookup: web(new Error("boom")).webLookup,
  });

  assert.equal(res.items[0].carbs, 13.7);
  assert.deepEqual(res.items[1], {
    name: "mystery", carbs: null, protein: null, fat: null, fiber: null, calories: null,
    details: "Couldn't look this up. Enter the carbs yourself.",
  });
});

test("past the USDA budget, the pick is skipped and foods go to the web", async () => {
  let t = 0;
  const now = () => t;
  const { fetchImpl, seen } = world({
    parse: () => { t = 13_000; return parsed(food("pho")); },
    search: { pho: json({ foods: [PHO] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });
  const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

  await lookupFoodsUsda("pho", KEYS, { fetchImpl, now, webLookup });

  assert.equal(seen.sonar, 1, "no pick call after the budget");
  assert.deepEqual(calls, ["pho"]);
});

test("past the overall budget, unresolved foods come back unknown", async () => {
  let t = 0;
  const now = () => t;
  const { fetchImpl } = world({ parse: () => { t = 25_000; return parsed(food("pho")); } });
  const never = { webLookup: () => new Promise(() => {}) };

  const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, now, webLookup: never.webLookup });

  assert.equal(res.items[0].carbs, null);
  assert.equal(res.items[0].details, "Couldn't look this up in time. Enter the carbs yourself.");
});

test("a web error with no USDA foods is rethrown", async () => {
  const { fetchImpl } = world({ parse: completion("no json") });
  const err = new Error("too many foods");

  await assert.rejects(lookupFoodsUsda("pizza", KEYS, { fetchImpl, webLookup: web(err).webLookup }), (e) => e === err);
});

test("logs carry counts and timing, never food text or keys", async () => {
  const lines = [];
  const orig = { log: console.log, error: console.error };
  console.log = (...a) => lines.push(a.join(" "));
  console.error = (...a) => lines.push(a.join(" "));
  try {
    const { fetchImpl } = world({
      parse: parsed(food("pho"), food("secret stew")),
      search: { pho: json({ foods: [PHO] }) },
      pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
    });
    await lookupFoodsUsda("pho and secret stew", KEYS, {
      fetchImpl, webLookup: web({ items: [], citations: [] }).webLookup,
    });
  } finally {
    Object.assign(console, orig);
  }
  const all = lines.join("\n");
  assert.match(all, /\[lookup\] source=usda foods=2 usda=1 web=1 ms=\d+/);
  assert.doesNotMatch(all, /pho|stew|PKEY|UKEY|Soup/i);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd functions && node --test test/lookup.test.js`
Expected: FAIL with `Cannot find module '../src/lookup'`.

- [ ] **Step 3: Implement `functions/src/lookup.js`**

```js
/**
 * Food lookup through USDA FoodData Central, with the web lookup as fallback.
 *
 * Numbers for matched foods are calculated here from FDC data; the model only
 * splits the text and names an entry and portion. Foods FDC can't match go to
 * the existing Perplexity web lookup, labelled as such.
 */

const { lookupFoods, sanitizeFoodInput, isNotBilled } = require("./perplexity");
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

/**
 * Looks up a sanitized food description. Same result shape and billing
 * markers as lookupFoods in perplexity.js.
 *
 * @param {string} sanitized - output of sanitizeFoodInput
 * @param {{perplexityKey: string, usdaKey: string}} keys
 * @param {{fetchImpl?: typeof fetch, now?: () => number, webLookup?: (text: string) => Promise<{items: object[], citations: string[]}>}} [options]
 */
async function lookupFoodsUsda(sanitized, { perplexityKey, usdaKey }, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  const now = options.now || Date.now;
  const webLookup = options.webLookup || ((text) => lookupFoods(text, perplexityKey, { fetchImpl }));

  const start = now();
  const left = (budget) => Math.max(0, start + budget - now());
  const billing = { billed: false };
  const stats = { foods: 0, usda: 0, web: 0 };
  const logDone = () =>
    console.log(`[lookup] source=usda foods=${stats.foods} usda=${stats.usda} web=${stats.web} ms=${now() - start}`);

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
      fetchImpl, billing, timeoutMs: Math.min(SONAR_CALL_MS, left(USDA_BUDGET_MS)),
    });
  } catch (err) {
    if (!(err instanceof ParseError)) throw err;
    console.log(`[lookup] parse failed: ${err.message}`);
    stats.web = 1;
    const result = await web(sanitized);
    logDone();
    return { items: result.items.map(labelled), citations: result.citations || [] };
  }
  stats.foods = foods.length;

  const matches = foods.map(() => null);
  try {
    const lists = await Promise.all(foods.map((food) =>
      searchCandidates(food.query, usdaKey, { fetchImpl, timeoutMs: Math.min(USDA_CALL_MS, left(USDA_BUDGET_MS)) })
        .catch((err) => {
          if (!(err instanceof UsdaError)) throw err;
          console.log(`[lookup] usda search failed: ${err.message}`);
          return [];
        })
    ));
    if (lists.some((list) => list.length > 0) && left(USDA_BUDGET_MS) > 0) {
      const picks = await pickMatches(foods, lists, perplexityKey, {
        fetchImpl, billing, timeoutMs: Math.min(SONAR_CALL_MS, left(USDA_BUDGET_MS)),
      });
      picks.forEach((pick, i) => { matches[i] = validatePick(pick, lists[i]); });
    }
  } catch (err) {
    if (!(err instanceof ParseError)) throw err;
    console.log(`[lookup] pick failed: ${err.message}`);
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
    try {
      const text = items.length === 0 ? sanitized : sanitizeFoodInput(leftover.map((f) => f.text).join(" and "));
      const result = await web(text);
      items.push(...result.items.map(labelled));
      citations.push(...(result.citations || []));
    } catch (err) {
      if (!(err instanceof WebTimeout) && items.length === 0) throw err;
      const details = err instanceof WebTimeout
        ? "Couldn't look this up in time. Enter the carbs yourself."
        : "Couldn't look this up. Enter the carbs yourself.";
      for (const food of leftover) items.push(unknown(food.name, details));
    }
  }

  logDone();
  return { items, citations };
}

module.exports = { lookupFoodsUsda };
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd functions && node --test test/lookup.test.js`
Expected: all pass. Then `npm test`: all pass. The existing `perplexity.test.js` and `handlers.test.js` must be untouched and green.

- [ ] **Step 5: Commit**

```bash
git add functions/src/lookup.js functions/test/lookup.test.js
git commit -m "feat(lookup): USDA-first lookup with labelled web fallback"
```

---

### Task 4: Wiring, kill switch, privacy policy

**Files:**
- Modify: `functions/index.js` (imports at lines 4 and 8; secrets near line 17; `lookupFoods:` in `getHandlers()`; `secrets:` of `exports.getMultipleCarbCounts`)
- Create: `functions/.env`
- Modify: `docs/privacy-policy.html` (the paragraph that describes sending the food description to Perplexity)

**Interfaces:**
- Consumes: Task 3 `lookupFoodsUsda(sanitized, {perplexityKey, usdaKey})`.

- [ ] **Step 1: Edit `functions/index.js`**

Change the params import:

```js
const { defineSecret, defineString } = require("firebase-functions/params");
```

Add the import after `const { lookupFoods } = require("./src/perplexity");`:

```js
const { lookupFoodsUsda } = require("./src/lookup");
```

After `const perplexityApiKey = defineSecret("PERPLEXITY_API_KEY");` add:

```js
const usdaApiKey = defineSecret("USDA_API_KEY");
// "web" restores the Perplexity-only lookup without a code change (edit functions/.env and redeploy).
const lookupSource = defineString("LOOKUP_SOURCE", { default: "usda" });
```

In `getHandlers()`, replace the `lookupFoods:` line with:

```js
    lookupFoods: (sanitized) =>
      lookupSource.value() === "web"
        ? lookupFoods(sanitized, perplexityApiKey.value())
        : lookupFoodsUsda(sanitized, {
          perplexityKey: perplexityApiKey.value(),
          // Trimmed like the App Store secrets: a pasted value often ends in a newline.
          usdaKey: usdaApiKey.value().trim(),
        }),
```

In `exports.getMultipleCarbCounts`, change the secrets to:

```js
    secrets: [perplexityApiKey, usdaApiKey, ...APP_STORE_SECRETS],
```

- [ ] **Step 2: Create `functions/.env`**

```
# Food lookup source: "usda" (FoodData Central first, web fallback) or "web" (Perplexity only).
LOOKUP_SOURCE=usda
```

- [ ] **Step 3: Check that the module loads and the suite passes**

Run: `cd functions && node -e "require('./index.js'); console.log('ok')"`
Expected: `ok`. A warning about missing credentials from `firebase-admin` is fine; a `SyntaxError` or `Cannot find module` is not.

Run: `npm test`
Expected: all pass.

- [ ] **Step 4: Update `docs/privacy-policy.html`**

Find the paragraph that says the food description is sent to Perplexity. Add this sentence right after it, matching the surrounding markup (same element type and class):

```
To find nutrition values, a short search phrase based on the food you type is also sent to USDA FoodData Central, a public nutrition database run by the U.S. Department of Agriculture. It is sent from our server, with nothing that identifies you.
```

- [ ] **Step 5: Commit**

```bash
git add functions/index.js functions/.env docs/privacy-policy.html
git commit -m "feat(lookup): route lookups through USDA, with a LOOKUP_SOURCE kill switch"
```

---

### Task 5: Live validation (controller only, not a subagent)

This needs the real Perplexity and USDA keys, held in memory only, and the controller runs it. The probe lives in the session scratchpad and is never committed.

- [ ] **Step 1: Write the probe** at `<scratchpad>/probe/usda-probe.js`. It calls `lookupFoodsUsda` from the repo with `{perplexityKey: process.env.PPLX_KEY, usdaKey: process.env.USDA_KEY}`, runs each food `RUNS` times, and prints the carbs, details and elapsed ms per run, then the median ms per food.

- [ ] **Step 2: Run it**

```bash
PPLX_KEY="$(cd /Volumes/APFS2/Developer/CarpeCarb && firebase functions:secrets:access PERPLEXITY_API_KEY 2>/dev/null)" \
USDA_KEY="$(cd /Volumes/APFS2/Developer/CarpeCarb && firebase functions:secrets:access USDA_API_KEY 2>/dev/null | tr -d '[:space:]')" \
RUNS=5 node usda-probe.js
```

Foods: `pizza`, `mcdonalds chicken nuggets`, `pho`, `a bowl of pho`, `10 mcdonalds nuggets`, `big mac`, `banana`, `water`, `heb fajita tortilla`, `grandma's secret casserole`, `burger and fries`.

- [ ] **Step 3: Check the pass criteria from the spec**

The probe passes when:
- each food gives the same carbs on all 5 runs, or is null on all 5
- pho and nuggets come from USDA
- water is 0
- grandma's secret casserole is null
- the median latency is no worse than the 5–10 s of today's lookup

If a criterion fails, change only the parse or pick prompt in `foodParse.js`. Re-run the probe and the unit tests (the prompt assertions in `foodParse.test.js` must still hold), and commit as `fix(lookup): …`.

- [ ] **Step 4: Open the PR** against `main`, stacked on #54, with the probe results table. Deploying is the owner's call.
