const test = require("node:test");
const assert = require("node:assert/strict");
const {
  sanitizeFoodInput, lookupFoods, isNotBilled, splitUnknownCarbs, listNames,
} = require("../src/perplexity");

const isInvalidArgument = (err) => err.code === "invalid-argument";

test("sanitizeFoodInput trims and collapses whitespace", () => {
  assert.equal(sanitizeFoodInput("  big   mac\tand fries \n"), "big mac and fries");
});

test("sanitizeFoodInput normalizes apostrophe and dash lookalikes", () => {
  assert.equal(sanitizeFoodInput("Wendy\u2019s chili \u2014 large"), "Wendy's chili - large");
});

test("sanitizeFoodInput rejects non-strings, too-short and too-long input", () => {
  assert.throws(() => sanitizeFoodInput(undefined), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput(42), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput(" a "), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput("x".repeat(101)), isInvalidArgument);
});

const noSleep = async () => {};

/** A fetch stand-in that returns the given responses in order (repeating the last) and counts calls. */
function stubFetch(...responses) {
  const stub = async () => {
    stub.calls += 1;
    return responses[Math.min(stub.calls, responses.length) - 1];
  };
  stub.calls = 0;
  return stub;
}

function completion(content, finishReason = "stop") {
  const body = { choices: [{ message: { content }, finish_reason: finishReason }], citations: [] };
  return { status: 200, ok: true, json: async () => body, text: async () => JSON.stringify(body) };
}

function httpError(status) {
  return { status, ok: false, json: async () => ({}), text: async () => "error" };
}

test("lookupFoods does not retry output truncated at max_tokens", async () => {
  const fetchImpl = stubFetch(completion('[{"name":"Egg","carbs":1},{"name":"Ha', "length"));

  await assert.rejects(lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(err.code, "invalid-argument");
    assert.equal(isNotBilled(err), false);
    return true;
  });
  assert.equal(fetchImpl.calls, 1);
});

test("lookupFoods does not retry truncated output that fails to parse", async () => {
  // Greedy array match ends at the citation's "]", so this reaches the JSON-parse branch.
  const fetchImpl = stubFetch(completion('[{"name":"Egg","carbs":1,"details":"USDA [1]"},{"name":"Ha', "length"));

  await assert.rejects(lookupFoods("eggs and ham", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(err.code, "invalid-argument");
    assert.equal(isNotBilled(err), false);
    return true;
  });
  assert.equal(fetchImpl.calls, 1);
});

test("lookupFoods keeps a complete array that is followed by truncated prose", async () => {
  const fetchImpl = stubFetch(completion('[{"name":"Egg","carbs":1}] and then some trunc', "length"));

  const res = await lookupFoods("an egg", "key", { fetchImpl, sleep: noSleep });

  assert.equal(res.items.length, 1);
  assert.equal(res.items[0].name, "Egg");
  assert.equal(fetchImpl.calls, 1);
});

test("lookupFoods treats null array elements as no items, and they stay billed", async () => {
  const fetchImpl = stubFetch(completion("[null]"));

  await assert.rejects(lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(isNotBilled(err), false);
    return true;
  });
  assert.equal(fetchImpl.calls, 3);
});

test("lookupFoods treats null message content as billed", async () => {
  const fetchImpl = stubFetch(completion(null));

  await assert.rejects(lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(isNotBilled(err), false);
    return true;
  });
});

test("lookupFoods keeps a billed attempt billed when later attempts hit 5xx", async () => {
  const fetchImpl = stubFetch(completion("Sorry, I can't find that food."), httpError(503));

  await assert.rejects(lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(isNotBilled(err), false);
    return true;
  });
  assert.equal(fetchImpl.calls, 3);
});

test("lookupFoods gives up after three unparseable responses, all billed", async () => {
  const fetchImpl = stubFetch(completion("Sorry, I can't find that food."));

  await assert.rejects(lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(err.code, "internal");
    assert.equal(isNotBilled(err), false);
    return true;
  });
  assert.equal(fetchImpl.calls, 3);
});

test("lookupFoods marks repeated 5xx errors as not billed", async () => {
  const fetchImpl = stubFetch(httpError(503));

  await assert.rejects(lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(isNotBilled(err), true);
    return true;
  });
  assert.equal(fetchImpl.calls, 3);
});

test("lookupFoods marks an auth failure as not billed", async () => {
  const fetchImpl = stubFetch(httpError(401));

  await assert.rejects(lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(isNotBilled(err), true);
    return true;
  });
});

test("lookupFoods maps a valid completion", async () => {
  const fetchImpl = stubFetch(completion(
    '[{"name":"Apple","carbs":25,"protein":0.5,"fat":0.3,"fiber":4.4,"calories":95,"details":"USDA, 1 medium apple"}]'
  ));

  const res = await lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep });

  assert.deepEqual(res, {
    items: [{
      name: "Apple", carbs: 25, protein: 0.5, fat: 0.3, fiber: 4.4, calories: 95, details: "USDA, 1 medium apple",
    }],
    citations: [],
  });
  assert.equal(fetchImpl.calls, 1);
});

// ── Unknown carb values (review #12) ──

/** Runs one lookup of a single completion and returns the mapped items. */
async function lookUp(content) {
  const fetchImpl = stubFetch(completion(content));
  const res = await lookupFoods("some food", "key", { fetchImpl, sleep: noSleep });
  return res.items;
}

test("lookupFoods keeps a missing carb value as null, never 0", async () => {
  const [item] = await lookUp('[{"name":"Mystery stew","carbs":null,"details":"No reliable source"}]');

  // A confident 0 g is worse than no answer for someone dosing insulin.
  assert.equal(item.carbs, null);
});

test("lookupFoods keeps a real zero as zero", async () => {
  const [item] = await lookUp('[{"name":"Water","carbs":0}]');

  assert.equal(item.carbs, 0);
});

test("lookupFoods treats negative and infinite numbers as no value", async () => {
  // 1e999 parses to Infinity.
  const [item] = await lookUp('[{"name":"Odd","carbs":-5,"protein":1e999,"fat":2}]');

  assert.equal(item.carbs, null);
  assert.equal(item.protein, null);
  assert.equal(item.fat, 2);
});

test("the prompt lets the model say a carb value is unknown", async () => {
  let body;
  const fetchImpl = async (_url, init) => {
    body = JSON.parse(init.body);
    return completion('[{"name":"Apple","carbs":25}]');
  };

  await lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep });

  const system = body.messages.find((m) => m.role === "system").content;
  assert.match(system, /set "carbs" to null/);
  assert.match(system, /Never estimate or guess/);
  assert.doesNotMatch(system, /never refuse/i);
});

test("splitUnknownCarbs separates foods with no carb value from the rest", () => {
  const { known, unknownNames } = splitUnknownCarbs([
    { name: "Burger", carbs: 30 },
    { name: "Fries", carbs: null },
    { name: "Water", carbs: 0 },
  ]);

  assert.deepEqual(known.map((i) => i.name), ["Burger", "Water"]);
  assert.deepEqual(unknownNames, ["Fries"]);
});

test("listNames joins names the way a sentence would", () => {
  assert.equal(listNames(["fries"]), "fries");
  assert.equal(listNames(["fries", "shake"]), "fries and shake");
  assert.equal(listNames(["fries", "shake", "cake"]), "fries, shake and cake");
});

// ── Logging (health data must not reach Cloud Logging) ──

/** Captures every console line written while [run] executes. */
async function captureLogs(run) {
  const lines = [];
  const originals = { log: console.log, error: console.error, warn: console.warn };
  for (const level of Object.keys(originals)) {
    console[level] = (...args) => lines.push(args.map(String).join(" "));
  }
  try {
    await run();
  } finally {
    Object.assign(console, originals);
  }
  return lines;
}

test("lookupFoods never logs the food text or the model's output", async () => {
  const lines = await captureLogs(async () => {
    // A successful lookup.
    await lookupFoods("secret mystery stew", "key", {
      fetchImpl: stubFetch(completion(
        '[{"name":"Zanzibar pudding","carbs":null,"details":"PRIVATE-DETAIL"}]'
      )),
      sleep: noSleep,
    });
    // Output that never parses, on every attempt.
    await lookupFoods("secret mystery stew", "key", {
      fetchImpl: stubFetch(completion("PRIVATE-GARBAGE with no array")),
      sleep: noSleep,
    }).catch(() => {});
    // A malformed API response.
    const malformed = {
      status: 200, ok: true,
      json: async () => ({ choices: [], note: "PRIVATE-STRUCT" }),
      text: async () => "",
    };
    await lookupFoods("secret mystery stew", "key", {
      fetchImpl: stubFetch(malformed), sleep: noSleep,
    }).catch(() => {});
  });

  assert.ok(lines.length > 0, "expected some logging to inspect");
  for (const line of lines) {
    assert.doesNotMatch(line, /mystery stew|Zanzibar|PRIVATE/, `leaked: ${line}`);
  }
});
