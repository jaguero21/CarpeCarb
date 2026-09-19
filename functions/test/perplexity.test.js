const test = require("node:test");
const assert = require("node:assert/strict");
const { sanitizeFoodInput, lookupFoods, isNotBilled } = require("../src/perplexity");

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
