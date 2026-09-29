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
// Same as PHO, but with a second foodMeasure so a "typical serving" portion exists.
const PHO_WITH_TYPICAL = {
  ...PHO,
  foodMeasures: [
    { disseminationText: "1 cup", gramWeight: 245 },
    { disseminationText: "Quantity not specified", gramWeight: 245 },
  ],
};
// Carries a brand (via brandOwner, the field toCandidate actually reads), for tests where the
// food names a brand and the server must see that brand on the matched candidate.
const PHO_BRANDED = { ...PHO, brandOwner: "Pho Palace" };
const PHO_WITH_TYPICAL_BRANDED = { ...PHO_WITH_TYPICAL, brandOwner: "Pho Palace" };
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
  const usdaCalls = [];
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    if (url.startsWith("https://api.perplexity.ai")) {
      seen.sonar += 1;
      const r = seen.sonar === 1 ? parse : pick;
      if (r instanceof Error) throw r;
      return typeof r === "function" ? r() : r;
    }
    seen.usda += 1;
    if (url.includes("/foods/search")) usdaCalls.push(body);
    const r = search[body.query];
    if (r === undefined) return json({ foods: [] });
    return typeof r === "function" ? r() : r;
  };
  return { fetchImpl, seen, usdaCalls };
}

const parsed = (...foods) => completion(JSON.stringify(foods));
const food = (name, amount = null, brand = null) =>
  ({ name, query: name, amount, brand, text: amount ? `${amount} ${name}` : name });

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
    parse: parsed(food("pho", "a bowl of", "Pho Palace")),
    search: { pho: json({ foods: [PHO_BRANDED] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":3}]'),
  });
  const { webLookup, calls } = web(new Error("must not be called"));

  const res = await lookupFoodsUsda("a bowl of pho", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(res, {
    items: [{
      name: "pho", carbs: 41.2, protein: 42.7, fat: 24.5, fiber: 2.9, calories: 566,
      details: "USDA FoodData Central (Survey (FNDDS)): Soup, pho, with meat, Pho Palace, 3 × 1 cup (735 g).",
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
    parse: parsed(food("fajita tortilla", null, "Price Chopper")),
    search: { "fajita tortilla": json({ foods: [branded] }) },
    pick: completion('[{"index":0,"fdcId":2104027,"portionId":"p1","count":1}]'),
  });

  const res = await lookupFoodsUsda("fajita tortilla", KEYS, { fetchImpl, webLookup: web({}).webLookup });

  assert.equal(res.items[0].details,
    "USDA FoodData Central (Branded): FAJITA TORTILLAS, Price Chopper Supermarkets, 1 TORTILLA (45 g).");
  assert.equal(res.items[0].carbs, 21);
  assert.equal(res.items[0].protein, null);
});

test("an unbranded food makes no USDA request and goes to the web", async () => {
  const { fetchImpl, seen } = world({
    parse: parsed(food("pizza")),
  });
  const { webLookup, calls } = web({ items: [{ name: "Pizza", carbs: 35, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("pizza", KEYS, { fetchImpl, webLookup });

  assert.equal(seen.usda, 0, "no USDA call for a food with no named brand");
  assert.deepEqual(calls, ["pizza"]);
  assert.equal(res.items[0].carbs, 35);
});

test("an all-unbranded request sends exactly the original text to the web, once", async () => {
  const { fetchImpl, seen } = world({
    parse: parsed(food("pizza"), food("fries")),
  });
  const { webLookup, calls } = web({ items: [{ name: "Pizza", carbs: 35, details: "web" }], citations: [] });
  const lines = [];
  const origLog = console.log;
  console.log = (...a) => lines.push(a.join(" "));
  let res;
  try {
    res = await lookupFoodsUsda("pizza and fries", KEYS, { fetchImpl, webLookup });
  } finally {
    console.log = origLog;
  }

  assert.equal(seen.usda, 0);
  assert.equal(seen.sonar, 1, "only the parse call, no pick call");
  assert.deepEqual(calls, ["pizza and fries"]);
  assert.equal(res.items[0].carbs, 35);
  assert.match(lines.join("\n"), /foods=2 usda=0 web=2/);
});

test("a mixed request puts the USDA item first, then the web items, searching only the branded food", async () => {
  const bigMac = { ...PHO, description: "MCDONALD'S, Big Mac", brandOwner: "McDonald's" };
  const { fetchImpl, seen } = world({
    parse: parsed(food("big mac", null, "McDonald's"), food("fries")),
    search: { "big mac": json({ foods: [bigMac] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });
  const { webLookup, calls } = web({ items: [{ name: "Fries", carbs: 30, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("big mac and fries", KEYS, { fetchImpl, webLookup });

  assert.equal(seen.usda, 1, "only the branded food is searched");
  assert.deepEqual(res.items.map((i) => i.name), ["big mac", "Fries"]);
  assert.deepEqual(calls, ["fries"]);
});

test("a food parsed with a brand searches all four data types", async () => {
  // Carries the named brand in its description so the pick also validates.
  const mcnuggets = { ...PHO, description: "MCDONALD'S, Chicken McNUGGETS" };
  const { fetchImpl, usdaCalls } = world({
    parse: parsed(food("mcdonalds nuggets", null, "McDonald's")),
    search: { "mcdonalds nuggets": json({ foods: [mcnuggets] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });

  await lookupFoodsUsda("mcdonalds nuggets", KEYS, { fetchImpl, webLookup: web({}).webLookup });

  assert.deepEqual(usdaCalls[0].dataType, ["Survey (FNDDS)", "SR Legacy", "Foundation", "Branded"]);
});

test("a branded food whose pick names a candidate without that brand falls back to the web", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("heb fajita tortilla", null, "H-E-B")),
    // PHO carries no brand at all, so it cannot satisfy the "H-E-B" requirement.
    search: { "heb fajita tortilla": json({ foods: [PHO] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });
  const { webLookup, calls } = web({ items: [{ name: "Tortilla", carbs: 20, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("heb fajita tortilla", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(calls, ["heb fajita tortilla"]);
  assert.equal(res.items[0].carbs, 20);
});

test("a food with no amount gets the standard portion, not the model's own pick", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho", null, "Pho Palace")),
    search: { pho: json({ foods: [PHO_WITH_TYPICAL_BRANDED] }) },
    // The model picked p1 (1 cup) with count 3; with no amount, the server overrides both.
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":3}]'),
  });

  const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, webLookup: web({}).webLookup });

  assert.equal(res.items[0].carbs, 13.7);
  assert.equal(res.items[0].details,
    "USDA FoodData Central (Survey (FNDDS)): Soup, pho, with meat, Pho Palace, typical serving (245 g).");
});

test("a branded no-amount food whose only candidate has just the 100 g portion goes to the web", async () => {
  // No foodMeasures at all, so the candidate ends up with only the synthetic
  // 100 g portion. With no amount from the user, serving 100 g would be a
  // silent guess, so this must fall back to the web instead.
  const only100g = { ...PHO, brandOwner: "Pho Palace", foodMeasures: [] };
  const { fetchImpl } = world({
    parse: parsed(food("pho", null, "Pho Palace")),
    search: { pho: json({ foods: [only100g] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"100g","count":1}]'),
  });
  const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(calls, ["pho"]);
  assert.equal(res.items[0].carbs, 40);
});

test("foods USDA can't match go to one web lookup, labelled, after the USDA foods", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho", null, "Pho Palace"), food("grandma's casserole"), food("chipotle bowl")),
    search: { pho: json({ foods: [PHO_BRANDED] }) },
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

test("when the leftover join is over 100 chars, the web gets the original text and a duplicate USDA name is dropped", async () => {
  const bigMac = { ...PHO, description: "MCDONALD'S, Big Mac", brandOwner: "McDonald's" };
  // Each leftover food's own text is within the 100-char field limit, but
  // joined with " and " they run well past sanitizeFoodInput's 100-char cap.
  const longA = "steamed dumplings with a side of pickled vegetables and hot must".slice(0, 60);
  const longB = "a large mixed green salad with grilled chicken and vinaigrette".slice(0, 60);
  const rawSanitized = `big mac, ${longA} and ${longB}`;
  const { fetchImpl } = world({
    parse: parsed(
      food("big mac", null, "McDonald's"),
      { name: "dumplings", query: "dumplings", amount: null, brand: null, text: longA },
      { name: "salad", query: "salad", amount: null, brand: null, text: longB },
    ),
    search: { "big mac": json({ foods: [bigMac] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });
  const { webLookup, calls } = web({
    items: [
      // Same name as the USDA match (any case) - a duplicate that must be dropped.
      { name: "BIG MAC", carbs: 45, details: "web dup, must be dropped" },
      { name: "Salad", carbs: 10, details: "web salad" },
    ],
    citations: ["https://example.com"],
  });

  const res = await lookupFoodsUsda(rawSanitized, KEYS, { fetchImpl, webLookup });

  assert.deepEqual(calls, [rawSanitized], "falls back to the original text instead of the too-long leftover join");
  assert.deepEqual(res.items.map((i) => i.name), ["big mac", "Salad"]);
  assert.match(res.items[0].details, /USDA/);
  assert.equal(res.items[1].carbs, 10);
});

test("duplicate citations (USDA and web repeating the same URL) are deduplicated", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho", null, "Pho Palace"), food("grandma's casserole")),
    search: { pho: json({ foods: [PHO_BRANDED] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });
  const { webLookup } = web({
    items: [{ name: "Casserole", carbs: 20, details: "Web" }],
    // Repeats the USDA citation the pho match already added, plus its own.
    citations: ["https://fdc.nal.usda.gov/food-details/2707124/nutrients", "https://example.com"],
  });

  const res = await lookupFoodsUsda("pho and grandma's casserole", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(res.citations, [
    "https://fdc.nal.usda.gov/food-details/2707124/nutrients",
    "https://example.com",
  ]);
});

test("a pick that fails validation falls back instead of trusting it", async () => {
  // A named amount routes validatePick through its strict rules (portionId and count checked).
  for (const pick of [
    '[{"index":0,"fdcId":999,"portionId":"p1","count":1}]',
    '[{"index":0,"fdcId":2707124,"portionId":"p1","count":50}]',
    '[{"index":0,"fdcId":null,"portionId":null,"count":null}]',
    "not json",
  ]) {
    const { fetchImpl } = world({
      parse: parsed(food("pho", "a bowl of", "Pho Palace")),
      search: { pho: json({ foods: [PHO_BRANDED] }) },
      pick: completion(pick),
    });
    const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

    const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, webLookup });

    assert.deepEqual(calls, ["pho"], pick);
    assert.equal(res.items[0].carbs, 40);
  }
});

test("with no amount, an invalid fdcId still falls back, even though portion and count are ignored", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho", null, "Pho Palace")),
    search: { pho: json({ foods: [PHO] }) },
    // No amount: portionId/count would be ignored, but this fdcId is not a candidate at all.
    pick: completion('[{"index":0,"fdcId":999,"portionId":"p1","count":50}]'),
  });
  const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(calls, ["pho"]);
  assert.equal(res.items[0].carbs, 40);
});

test("USDA errors send the food to the web and the request still succeeds", async () => {
  for (const failure of [
    () => json({}, 429),
    () => json({}, 500),
    () => { throw Object.assign(new Error("t"), { name: "TimeoutError" }); },
  ]) {
    const { fetchImpl } = world({ parse: parsed(food("pho", null, "Pho Palace")), search: { pho: failure } });
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
    parse: parsed(food("pho", null, "Pho Palace"), food("mystery")),
    search: { pho: json({ foods: [PHO_BRANDED] }) },
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
    parse: () => { t = 13_000; return parsed(food("pho", null, "Pho Palace")); },
    search: { pho: json({ foods: [PHO] }) },
    pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
  });
  const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

  await lookupFoodsUsda("pho", KEYS, { fetchImpl, now, webLookup });

  assert.equal(seen.sonar, 1, "no pick call after the budget");
  assert.deepEqual(calls, ["pho"]);
});

test("a 429 during parse is not retried once the wait would run past the USDA-path deadline", async () => {
  let t = 0;
  const now = () => t;
  let sonarCalls = 0;
  const fetchImpl = async (url) => {
    if (!url.startsWith("https://api.perplexity.ai")) throw new Error("unexpected USDA call");
    sonarCalls += 1;
    // Near the end of the 12s USDA budget when the 429 comes back, so the
    // 1s retry-after wait would itself run past the deadline.
    t = 11_800;
    return {
      ok: false, status: 429,
      headers: { get: (k) => (k.toLowerCase() === "retry-after" ? "1" : null) },
      json: async () => ({}),
    };
  };
  const sleepCalls = [];
  const sleep = async (ms) => { sleepCalls.push(ms); };
  const { webLookup, calls } = web({ items: [{ name: "Pizza", carbs: 35, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("pizza", KEYS, { fetchImpl, now, webLookup, sleep });

  assert.equal(sonarCalls, 1, "the 429 must not be retried once the wait would exceed the remaining budget");
  assert.equal(sleepCalls.length, 0);
  assert.deepEqual(calls, ["pizza"]);
  assert.equal(res.items[0].carbs, 35);
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

// ── parse-failure path: web fallback timeout ──

test("a parse failure whose web fallback times out surfaces as a friendly deadline-exceeded, refundable when parse was never billed", async () => {
  let t = 0;
  const now = () => t;
  // Parse gets a 500: never billed. By the time the web fallback starts, the overall budget is
  // already spent, so its internal race times out immediately.
  const { fetchImpl } = world({ parse: () => { t = 25_000; return json({}, 500); } });
  const never = () => new Promise(() => {});

  await assert.rejects(
    lookupFoodsUsda("pizza", KEYS, { fetchImpl, now, webLookup: never }),
    (err) => {
      assert.equal(err.code, "deadline-exceeded");
      assert.match(err.message, /took too long/i);
      assert.equal(isNotBilled(err), true, "nothing was ever billed on this path");
      return true;
    }
  );
});

test("a parse failure whose web fallback times out is not refundable once parse itself was billed", async () => {
  let t = 0;
  const now = () => t;
  // Parse gets a 200 with unusable content: billed, but still fails to parse.
  const { fetchImpl } = world({ parse: () => { t = 25_000; return completion("no json"); } });
  const never = () => new Promise(() => {});

  await assert.rejects(
    lookupFoodsUsda("pizza", KEYS, { fetchImpl, now, webLookup: never }),
    (err) => {
      assert.equal(err.code, "deadline-exceeded");
      assert.equal(isNotBilled(err), false, "the parse call was billed, so the lookup isn't refunded");
      return true;
    }
  );
});

test("an unexpected error in USDA search sends the food to the web", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho", null, "Pho Palace")),
    search: { pho: json({ foods: [{ fdcId: 1, dataType: "SR Legacy", description: "x", foodNutrients: 5 }] }) },
  });
  const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(calls, ["pho"]);
  assert.equal(res.items[0].carbs, 40);
});

test("an unexpected error in the pick call sends the food to the web", async () => {
  const { fetchImpl } = world({
    parse: parsed(food("pho", null, "Pho Palace")),
    search: { pho: json({ foods: [PHO] }) },
    pick: { ok: true, status: 200, json: async () => ({ get choices() { throw new TypeError("boom"); } }) },
  });
  const { webLookup, calls } = web({ items: [{ name: "Pho", carbs: 40, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("pho", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(calls, ["pho"]);
  assert.equal(res.items[0].carbs, 40);
});

test("an unexpected error in parse falls back to the whole text", async () => {
  const { fetchImpl } = world({
    parse: { ok: true, status: 200, json: async () => ({ get choices() { throw new TypeError("boom"); } }) },
  });
  const { webLookup, calls } = web({ items: [{ name: "Pizza", carbs: 35, details: "web" }], citations: [] });

  const res = await lookupFoodsUsda("pizza", KEYS, { fetchImpl, webLookup });

  assert.deepEqual(calls, ["pizza"]);
  assert.equal(res.items[0].carbs, 35);
});

test("a failed lookup still logs one line, with no food text", async () => {
  const lines = [];
  const orig = { log: console.log, error: console.error };
  console.log = (...a) => lines.push(a.join(" "));
  console.error = (...a) => lines.push(a.join(" "));
  try {
    const { fetchImpl } = world({
      parse: completion("no json"),
    });
    await assert.rejects(
      lookupFoodsUsda("pizza", KEYS, { fetchImpl, webLookup: web(new Error("down")).webLookup }),
      (err) => err.message === "down"
    );
  } finally {
    Object.assign(console, orig);
  }
  const all = lines.join("\n");
  assert.match(all, /\[lookup\] source=usda .* outcome=error/);
  assert.doesNotMatch(all, /pizza/i);
});

test("logs carry counts and timing, never food text or keys", async () => {
  const lines = [];
  const orig = { log: console.log, error: console.error };
  console.log = (...a) => lines.push(a.join(" "));
  console.error = (...a) => lines.push(a.join(" "));
  try {
    const { fetchImpl } = world({
      parse: parsed(food("pho", null, "Pho Palace"), food("secret stew")),
      search: { pho: json({ foods: [PHO_BRANDED] }) },
      pick: completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":1}]'),
    });
    await lookupFoodsUsda("pho and secret stew", KEYS, {
      fetchImpl, webLookup: web({ items: [], citations: [] }).webLookup,
    });
  } finally {
    Object.assign(console, orig);
  }
  const all = lines.join("\n");
  assert.match(all, /\[lookup\] source=usda foods=2 usda=1 web=1 ms=\d+.*outcome=ok/);
  assert.doesNotMatch(all, /pho|stew|PKEY|UKEY|Soup/i);
});
