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
// The details endpoint's portions for 173297, as FDC returns them: out of grams order,
// each carrying FDC's own sequenceNumber (6 pc = 2, 4 pc = 1, 10 pc = 3).
const NUGGETS_DETAILS = [{
  fdcId: 173297, dataType: "SR Legacy",
  foodPortions: [
    { gramWeight: 95.0, amount: 6.0, modifier: "pieces", measureUnit: { name: "undetermined" }, sequenceNumber: 2 },
    { gramWeight: 64.0, amount: 4.0, modifier: "pieces", measureUnit: { name: "undetermined" }, sequenceNumber: 1 },
    { gramWeight: 159.0, amount: 10.0, modifier: "pieces", measureUnit: { name: "undetermined" }, sequenceNumber: 3 },
  ],
}];
const FRIES_BRANDED = {
  fdcId: 3001, dataType: "Branded", description: "FRIES", brandOwner: "Lamb Weston Sales, Inc. ",
  servingSize: 84.0, servingSizeUnit: "g", householdServingFullText: "3 oz",
  foodNutrients: [{ nutrientId: 1005, value: 24.0 }],
};

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
    query: "pho", pageSize: 15, dataType: ["Survey (FNDDS)", "SR Legacy", "Foundation", "Branded"],
  });
  assert.ok(calls[0].signal, "every FDC call has a timeout");
});

test("includeBranded false sends the three non-branded data types", async () => {
  const { fetchImpl, calls } = fdc({ search: { foods: [] } });

  await searchCandidates("pizza", "KEY", { fetchImpl, includeBranded: false });

  assert.deepEqual(calls[0].body.dataType, ["Survey (FNDDS)", "SR Legacy", "Foundation"]);
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

test("an SR Legacy food gets its portions from one details call, ordered by sequenceNumber", async () => {
  const { fetchImpl, calls } = fdc({ search: { foods: [NUGGETS_SR] }, details: NUGGETS_DETAILS });

  const [nuggets] = await searchCandidates("McDonald's Chicken McNuggets", "KEY", { fetchImpl });

  assert.match(calls[1].url, /\/fdc\/v1\/foods\?api_key=KEY$/);
  assert.deepEqual(calls[1].body, { fdcIds: [173297], format: "full" });
  // FDC's own order (sequenceNumber 1, 2, 3), not the order the portions arrived in.
  assert.deepEqual(nuggets.portions, [
    { id: "p1", label: "4 pieces", grams: 64 },
    { id: "p2", label: "6 pieces", grams: 95 },
    { id: "p3", label: "10 pieces", grams: 159 },
    { id: "100g", label: "100 g", grams: 100 },
  ]);
  // A nutrient the record doesn't list is unknown, not 0.
  assert.equal(nuggets.per100g.fiber, null);
});

test("details portions without a sequenceNumber sort after those that have one, in received order", async () => {
  const search = {
    fdcId: 999, dataType: "SR Legacy", description: "Mystery Meat", foodMeasures: [],
    foodNutrients: [{ nutrientId: 1005, value: 1 }],
  };
  const details = [{
    fdcId: 999, dataType: "SR Legacy",
    foodPortions: [
      { gramWeight: 10, amount: 1, modifier: "no-seq-first", measureUnit: { name: "undetermined" } },
      { gramWeight: 20, amount: 2, modifier: "seq-1", measureUnit: { name: "undetermined" }, sequenceNumber: 1 },
      { gramWeight: 30, amount: 3, modifier: "no-seq-second", measureUnit: { name: "undetermined" } },
    ],
  }];
  const { fetchImpl } = fdc({ search: { foods: [search] }, details });

  const [c] = await searchCandidates("mystery", "KEY", { fetchImpl });

  assert.deepEqual(c.portions.map((p) => p.label), ["2 seq-1", "1 no-seq-first", "3 no-seq-second", "100 g"]);
});

test("a branded food's brand is trimmed", async () => {
  const { fetchImpl } = fdc({ search: { foods: [FRIES_BRANDED] } });

  const [fries] = await searchCandidates("fries", "KEY", { fetchImpl });

  assert.equal(fries.brand, "Lamb Weston Sales, Inc.");
});

test("a brand that is only whitespace comes out null", async () => {
  const blankBrand = { ...FRIES_BRANDED, fdcId: 3002, brandOwner: "   " };
  const { fetchImpl } = fdc({ search: { foods: [blankBrand] } });

  const [fries] = await searchCandidates("fries", "KEY", { fetchImpl });

  assert.equal(fries.brand, null);
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
