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
    '[{"name":"pho","query":"pho","amount":"a bowl of","text":"a bowl of pho","brand":null},' +
    '{"name":"McDonald\'s nuggets","query":"McDonald\'s Chicken McNuggets","amount":"10",' +
    '"text":"10 mcdonalds nuggets","brand":"McDonald\'s"}]'
  ));
  const billing = { billed: false };

  const foods = await parseFoods("a bowl of pho and 10 mcdonalds nuggets", "KEY", opts(fetchImpl, billing));

  assert.deepEqual(foods, [
    { name: "pho", query: "pho", amount: "a bowl of", text: "a bowl of pho", brand: null },
    {
      name: "McDonald's nuggets", query: "McDonald's Chicken McNuggets", amount: "10",
      text: "10 mcdonalds nuggets", brand: "McDonald's",
    },
  ]);
  assert.equal(bodies[0].model, "sonar");
  assert.equal(bodies[0].disable_search, true);
  assert.equal(bodies[0].temperature, 0);
  assert.equal(bodies[0].messages[1].content, "a bowl of pho and 10 mcdonalds nuggets");
  assert.match(bodies[0].messages[0].content, /use it with the product name/i);
  assert.match(bodies[0].messages[0].content, /USDA's own naming style/);
  assert.equal(billing.billed, true);
});

test("parseFoods accepts fenced output and a missing amount or brand", async () => {
  const { fetchImpl } = sonar(completion('```json\n[{"name":"pizza","query":"pizza","text":"pizza"}]\n```'));

  const [food] = await parseFoods("pizza", "KEY", opts(fetchImpl));

  assert.equal(food.amount, null);
  assert.equal(food.brand, null);
});

test("parseFoods rejects output that is not a usable food list", async () => {
  for (const content of [
    "no json here",
    "[]",
    '[{"name":"pizza"}]',
    '[{"name":"","query":"pizza","text":"pizza"}]',
    '[{"name":"pizza","query":"pizza","text":"pizza","amount":3}]',
    '[{"name":"pizza","query":"pizza","text":"pizza","brand":5}]',
    JSON.stringify(Array.from({ length: 11 }, () => ({ name: "a", query: "a", text: "a" }))),
  ]) {
    const { fetchImpl } = sonar(completion(content));
    await assert.rejects(parseFoods("pizza", "KEY", opts(fetchImpl)), ParseError, content);
  }
});

test("the parse prompt asks for a brand field", async () => {
  const { fetchImpl, bodies } = sonar(completion("[]"));

  await assert.rejects(parseFoods("x", "KEY", opts(fetchImpl)), ParseError);

  const system = bodies[0].messages[0].content;
  assert.match(system, /"brand"/);
  assert.match(system, /McDonald's/);
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

// ── callSonar: 429 retry ──

/** A 429 response carrying a retry-after header, in the shape a real fetch Response would. */
function rateLimited(retryAfter) {
  return {
    ok: false, status: 429,
    headers: { get: (k) => (k.toLowerCase() === "retry-after" ? retryAfter : null) },
    json: async () => ({}),
  };
}
/** Records the ms passed to each sleep call; resolves immediately, so tests run fast. */
function spySleep() {
  const calls = [];
  const sleep = async (ms) => { calls.push(ms); };
  return { sleep, calls };
}

test("a 429 with a short retry-after is retried once, then succeeds", async () => {
  const { fetchImpl, bodies } = sonar(
    rateLimited("1"),
    completion('[{"name":"pizza","query":"pizza","text":"pizza"}]')
  );
  const { sleep, calls } = spySleep();
  const billing = { billed: false };

  const foods = await parseFoods("pizza", "KEY", { fetchImpl, timeoutMs: 6000, billing, sleep });

  assert.equal(foods.length, 1);
  assert.equal(bodies.length, 2);
  assert.deepEqual(calls, [1000]);
  assert.equal(billing.billed, true);
});

test("a 429 whose retry-after is over 2 seconds is not retried", async () => {
  const { fetchImpl, bodies } = sonar(rateLimited("5"));
  const { sleep, calls } = spySleep();
  const billing = { billed: false };

  await assert.rejects(
    parseFoods("pizza", "KEY", { fetchImpl, timeoutMs: 6000, billing, sleep }),
    (err) => err instanceof ParseError && err.message === "status 429"
  );

  assert.equal(bodies.length, 1);
  assert.equal(calls.length, 0);
  assert.equal(billing.billed, false);
});

test("a second 429 in a row gives up, after two calls", async () => {
  const { fetchImpl, bodies } = sonar(rateLimited("1"), rateLimited("1"));
  const { sleep, calls } = spySleep();
  const billing = { billed: false };

  await assert.rejects(
    parseFoods("pizza", "KEY", { fetchImpl, timeoutMs: 6000, billing, sleep }),
    (err) => err instanceof ParseError && err.message === "status 429"
  );

  assert.equal(bodies.length, 2);
  assert.equal(calls.length, 1, "only one retry is ever attempted");
  assert.equal(billing.billed, false);
});

// ── pickMatches ──

test("pickMatches sends one call for all foods with candidates, IDs, brand and portions only", async () => {
  const { fetchImpl, bodies } = sonar(completion('[{"index":0,"fdcId":2707124,"portionId":"p1","count":3}]'));
  const foods = [
    { name: "pho", query: "pho", amount: "a bowl of", text: "a bowl of pho", brand: null },
    { name: "zzz", query: "zzz", amount: null, text: "zzz", brand: null },
  ];

  const picks = await pickMatches(foods, [[PHO], []], "KEY", opts(fetchImpl));

  assert.equal(bodies.length, 1);
  assert.equal(bodies[0].disable_search, true);
  const sent = JSON.parse(bodies[0].messages[1].content);
  assert.deepEqual(sent, {
    foods: [{
      index: 0, name: "pho", amount: "a bowl of", brand: null,
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

test("pickMatches sends the food's own brand alongside name and amount", async () => {
  const { fetchImpl, bodies } = sonar(completion("[]"));
  const foods = [{
    name: "McDonald's nuggets", query: "McDonald's Chicken McNuggets", amount: "10", text: "10 mcdonalds nuggets",
    brand: "McDonald's",
  }];

  await pickMatches(foods, [[PHO]], "KEY", opts(fetchImpl));

  const sent = JSON.parse(bodies[0].messages[1].content);
  assert.equal(sent.foods[0].brand, "McDonald's");
});

test("pickMatches makes no call when no food has candidates", async () => {
  const { fetchImpl, bodies } = sonar(completion("[]"));

  const picks = await pickMatches(
    [{ name: "a", query: "a", amount: null, text: "a", brand: null }], [[]], "KEY", opts(fetchImpl)
  );

  assert.equal(bodies.length, 0);
  assert.deepEqual(picks, [null]);
});

test("pickMatches ignores picks for indexes it did not send", async () => {
  const { fetchImpl } = sonar(completion('[{"index":5,"fdcId":1,"portionId":"p1","count":1}]'));

  const picks = await pickMatches(
    [{ name: "pho", query: "pho", amount: null, text: "pho", brand: null }], [[PHO]], "KEY", opts(fetchImpl)
  );

  assert.deepEqual(picks, [null]);
});

test("the pick prompt requires generic entries by default, forbids other brands, and forbids nutrition values", async () => {
  const { fetchImpl, bodies } = sonar(completion("[]"));
  await pickMatches(
    [{ name: "pho", query: "pho", amount: null, text: "pho", brand: null }], [[PHO]], "KEY", opts(fetchImpl)
  );

  const system = bodies[0].messages[0].content;
  assert.match(system, /only a candidate from that brand or chain/i);
  assert.match(system, /choose a generic entry/i);
  assert.match(system, /Hamburger \(Burger King\)/);
  assert.match(system, /portionId and count to null/i);
  assert.match(system, /A variant the user did not mention/);
  assert.match(system, /fdcId is null/);
  assert.match(system, /Never give nutrition values/);
});

// ── validatePick ──

test("validatePick accepts a pick naming a sent candidate, its portion and a sane count", () => {
  assert.deepEqual(validatePick({ fdcId: 2707124, portionId: "p1", count: 3 }, [PHO], { amount: "3", brand: null }), {
    candidate: PHO, portion: PHO.portions[0], count: 3,
  });
  // Some models quote numbers.
  assert.equal(
    validatePick({ fdcId: "2707124", portionId: "100g", count: 0.25 }, [PHO], { amount: "a taste", brand: null }).count,
    0.25
  );
});

test("validatePick rejects anything else, when the user gave an amount", () => {
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
    assert.equal(validatePick(pick, [PHO], { amount: "some", brand: null }), null, JSON.stringify(pick));
  }
});

test("validatePick with no amount ignores the model's portion and count, using the typical serving", () => {
  // The model picked p1 (1 cup) with count 3; with no amount, the server overrides both.
  const pick = { fdcId: 2707124, portionId: "p1", count: 3 };

  assert.deepEqual(validatePick(pick, [PHO], { amount: null, brand: null }), {
    candidate: PHO, portion: PHO.portions[1], count: 1,
  });
});

test("validatePick with no amount falls back to the candidate's first portion when there is no typical serving", () => {
  const candidate = {
    ...PHO,
    portions: [{ id: "p1", label: "1 TORTILLA", grams: 45 }, { id: "100g", label: "100 g", grams: 100 }],
  };

  assert.deepEqual(
    validatePick({ fdcId: 2707124, portionId: "100g", count: 5 }, [candidate], { amount: null, brand: null }),
    { candidate, portion: candidate.portions[0], count: 1 }
  );
});

test("validatePick with no amount never returns the synthetic 100 g portion", () => {
  // A candidate that only ever got the appended 100 g portion (no foodMeasures,
  // no household serving text, or a failed details call). No amount means the
  // server would silently serve 100 g of it, which nobody asked for.
  const candidate = { ...PHO, portions: [{ id: "100g", label: "100 g", grams: 100 }] };

  assert.equal(
    validatePick({ fdcId: 2707124, portionId: "100g", count: 1 }, [candidate], { amount: null, brand: null }),
    null
  );
});

test("validatePick with no amount still rejects an fdcId that isn't a sent candidate", () => {
  assert.equal(validatePick({ fdcId: 999, portionId: "p1", count: 1 }, [PHO], { amount: null, brand: null }), null);
  assert.equal(validatePick(null, [PHO], { amount: null, brand: null }), null);
});

// ── validatePick: brand enforcement ──

/** A minimal candidate for brand-matching checks; PHO's portions are reused for convenience. */
function brandCandidate(description, brand) {
  return { fdcId: 1, description, dataType: "Branded", brand, portions: PHO.portions };
}

const MUST_PASS_BRANDS = [
  { brand: "McDonald's", description: "McDONALD'S, Chicken McNUGGETS", candidateBrand: null },
  { brand: "McDonald's", description: "Big Mac (McDonalds)", candidateBrand: null },
  { brand: "H-E-B", description: "Fajita Tortillas", candidateBrand: "H-E-B" },
  { brand: "H-E-B", description: "HEB Fajita Tortillas", candidateBrand: null },
  { brand: "Burger King", description: "Hamburger (Burger King)", candidateBrand: null },
  { brand: "Wendy's", description: "WENDY'S, Jr. Hamburger", candidateBrand: null },
];

test("validatePick accepts a candidate that carries the named brand, in description or brand field", () => {
  for (const { brand, description, candidateBrand } of MUST_PASS_BRANDS) {
    const candidate = brandCandidate(description, candidateBrand);
    const result = validatePick(
      { fdcId: 1, portionId: "p1", count: 1 }, [candidate], { amount: "1", brand }
    );
    assert.ok(result, `${brand} should match "${description}"`);
    assert.equal(result.candidate, candidate);
  }
});

test("validatePick rejects a candidate that doesn't carry the named brand", () => {
  const candidate = brandCandidate("Tortillas, ready-to-bake or -fry", null);

  const result = validatePick(
    { fdcId: 1, portionId: "p1", count: 1 }, [candidate], { amount: "1", brand: "H-E-B" }
  );

  assert.equal(result, null);
});

const MUST_FAIL_BRANDS = [
  // "aw" is a raw substring of "strAWberry"; a real word-boundary check must not match it.
  { brand: "A&W", description: "Strawberry shake" },
  // "sonic" is a raw substring of "superSONICburger"; same trap.
  { brand: "Sonic", description: "Supersonic burger" },
  { brand: "H-E-B", description: "Tortillas, ready-to-bake or -fry" },
];

test("validatePick rejects a brand that only appears as part of a longer word", () => {
  for (const { brand, description } of MUST_FAIL_BRANDS) {
    const candidate = brandCandidate(description, null);
    const result = validatePick(
      { fdcId: 1, portionId: "p1", count: 1 }, [candidate], { amount: "1", brand }
    );
    assert.equal(result, null, `${brand} should not match "${description}"`);
  }
});

test("validatePick skips the brand check when the food named no brand", () => {
  const candidate = brandCandidate("Tortillas, ready-to-bake or -fry", null);

  const result = validatePick(
    { fdcId: 1, portionId: "p1", count: 1 }, [candidate], { amount: "1", brand: null }
  );

  assert.ok(result);
  assert.equal(result.candidate, candidate);
});

test("validatePick applies the brand check with no amount too", () => {
  const unbranded = brandCandidate("Tortillas, ready-to-bake or -fry", null);
  const pick = { fdcId: 1, portionId: "p1", count: 3 };

  assert.equal(validatePick(pick, [unbranded], { amount: null, brand: "H-E-B" }), null);

  const branded = brandCandidate("Tortillas, ready-to-bake or -fry", "H-E-B");
  const result = validatePick(pick, [branded], { amount: null, brand: "H-E-B" });
  assert.ok(result);
  assert.equal(result.count, 1);
});
