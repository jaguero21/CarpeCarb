const test = require("node:test");
const assert = require("node:assert/strict");
const { HttpsError } = require("firebase-functions/v2/https");
const { createRateLimiter } = require("../src/rateLimit");
const { createFakeFirestore } = require("./helpers/fakeFirestore");

test("allows up to the limit, then throws resource-exhausted", async () => {
  const db = createFakeFirestore();
  const checkRateLimit = createRateLimiter(db);

  await checkRateLimit("u1", "act", 2, 60);
  await checkRateLimit("u1", "act", 2, 60);
  await assert.rejects(checkRateLimit("u1", "act", 2, 60), (err) => {
    assert.ok(err instanceof HttpsError);
    assert.equal(err.code, "resource-exhausted");
    return true;
  });
});

test("limits are tracked per uid", async () => {
  const db = createFakeFirestore();
  const checkRateLimit = createRateLimiter(db);

  await checkRateLimit("u1", "act", 1, 60);
  await assert.doesNotReject(checkRateLimit("u2", "act", 1, 60));
});
