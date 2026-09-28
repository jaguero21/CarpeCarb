/**
 * USDA FoodData Central: search, portions, and the nutrition math.
 *
 * Every number the USDA lookup reports comes from here, calculated from FDC's
 * per-100 g values. The model only ever names an entry and a portion.
 */

const USDA_BASE = "https://api.nal.usda.gov/fdc/v1";
const DATA_TYPES = ["Survey (FNDDS)", "SR Legacy", "Foundation", "Branded"];
const SEARCH_PAGE_SIZE = 15;
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

/** Trims a brand name; blank-after-trim is no brand at all. */
function cleanBrand(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
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
    brand: cleanBrand(food.brandOwner) || cleanBrand(food.brandName),
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
 * Sorts details-endpoint portions by FDC's own ascending sequenceNumber. Portions
 * without a numeric sequenceNumber go after those with one, in the order received.
 */
function bySequenceNumber(foodPortions) {
  return foodPortions
    .map((p, index) => ({ p, index, seq: Number.isFinite(p && p.sequenceNumber) ? p.sequenceNumber : null }))
    .sort((a, b) => {
      if (a.seq !== null && b.seq !== null) return a.seq - b.seq;
      if (a.seq !== null) return -1;
      if (b.seq !== null) return 1;
      return a.index - b.index;
    })
    .map((x) => x.p);
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
        for (const p of bySequenceNumber(food.foodPortions || [])) addPortion(c.portions, portionLabel(p), p.gramWeight);
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
