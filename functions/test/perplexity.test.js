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

/** A fetch stand-in that returns the same response every call and counts calls. */
function stubFetch(response) {
  const stub = async () => {
    stub.calls += 1;
    return response;
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
  const fetchImpl = stubFetch(completion('[{"name":"Apple","carbs":25', "length"));

  await assert.rejects(lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep }), (err) => {
    assert.equal(err.code, "invalid-argument");
    assert.equal(isNotBilled(err), false);
    return true;
  });
  assert.equal(fetchImpl.calls, 1);
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
