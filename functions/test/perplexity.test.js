const test = require("node:test");
const assert = require("node:assert/strict");
const { sanitizeFoodInput } = require("../src/perplexity");

const isInvalidArgument = (err) => err.code === "invalid-argument";

test("sanitizeFoodInput trims and collapses whitespace", () => {
  assert.equal(sanitizeFoodInput("  big   mac\tand fries \n"), "big mac and fries");
});

test("sanitizeFoodInput normalizes apostrophe and dash lookalikes", () => {
  assert.equal(sanitizeFoodInput("Wendy's chili — large"), "Wendy's chili - large");
});

test("sanitizeFoodInput rejects non-strings, too-short and too-long input", () => {
  assert.throws(() => sanitizeFoodInput(undefined), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput(42), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput(" a "), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput("x".repeat(101)), isInvalidArgument);
});
