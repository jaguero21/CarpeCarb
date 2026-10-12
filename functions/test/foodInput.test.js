const test = require("node:test");
const assert = require("node:assert/strict");
const cases = require("./fixtures/food-input-cases.json");
const { validateFoodInput, sanitizeFoodInput } = require("../src/foodInput");
const perplexity = require("../src/perplexity");

const inputOf = (c) => (c.repeat ? c.repeat[0].repeat(c.repeat[1]) : c.input);

test("every shared valid case passes and normalizes as expected", () => {
  for (const c of cases.valid) {
    assert.equal(validateFoodInput(c.input), null, JSON.stringify(c.input));
    assert.equal(sanitizeFoodInput(c.input), c.normalized, JSON.stringify(c.input));
  }
});

test("every shared invalid case is rejected with the app's message", () => {
  for (const c of cases.invalid) {
    const input = inputOf(c);
    assert.equal(validateFoodInput(input), c.error, JSON.stringify(input));
    assert.throws(
      () => sanitizeFoodInput(input),
      (err) => err.code === "invalid-argument" && err.message === c.error,
      JSON.stringify(input)
    );
  }
});

test("a non-string is rejected", () => {
  for (const v of [undefined, null, 42, {}]) {
    assert.throws(() => sanitizeFoodInput(v), (err) => err.code === "invalid-argument");
  }
});

test("perplexity.js re-exports the same sanitizer the handlers use", () => {
  assert.equal(perplexity.sanitizeFoodInput, sanitizeFoodInput);
});
