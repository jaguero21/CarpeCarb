const test = require("node:test");
const assert = require("node:assert/strict");
const { HttpsError } = require("firebase-functions/v2/https");
const { createHandlers } = require("../src/handlers");

const NOW = Date.parse("2026-09-18T12:00:00Z");
const auth = { uid: "u1" };

function makeDeps(overrides = {}) {
  const calls = [];
  const deps = {
    checkRateLimit: async () => {},
    getPremiumStatus: async () => false,
    reserveLookup: async (uid, tz) => {
      calls.push(["reserve", uid, tz]);
      return { dayKey: "2026-09-18", used: 1, limit: 4 };
    },
    releaseLookup: async (uid, key) => {
      calls.push(["release", uid, key]);
    },
    lookupFoods: async (input) => {
      calls.push(["lookup", input]);
      return { items: [{ name: "Apple", carbs: 25 }], citations: [] };
    },
    verifyTransaction: async () => ({}),
    recordTransaction: async (uid, payload) => {
      calls.push(["record", uid, payload.productId]);
    },
    now: () => NOW,
    ...overrides,
  };
  return { deps, calls };
}

test("free lookup reserves quota before calling Perplexity and returns it", async () => {
  const { deps, calls } = makeDeps();
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({ auth, data: { input: "an apple", tzOffsetMinutes: -300 } });

  assert.deepEqual(calls, [["reserve", "u1", -300], ["lookup", "an apple"]]);
  assert.deepEqual(res.quota, { premium: false, used: 1, limit: 4 });
  assert.equal(res.items[0].name, "Apple");
});

test("premium lookup skips the quota", async () => {
  const { deps, calls } = makeDeps({ getPremiumStatus: async () => true });
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({ auth, data: { input: "an apple" } });

  assert.deepEqual(calls, [["lookup", "an apple"]]);
  assert.deepEqual(res.quota, { premium: true, used: null, limit: null });
});

test("missing tzOffsetMinutes reserves against UTC", async () => {
  const { deps, calls } = makeDeps();
  await createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } });
  assert.deepEqual(calls[0], ["reserve", "u1", 0]);
});

test("daily-quota error passes through without calling Perplexity", async () => {
  const quotaErr = new HttpsError("resource-exhausted", "You've used today's 4 free lookups.", {
    reason: "daily-quota", used: 4, limit: 4,
  });
  const { deps, calls } = makeDeps({ reserveLookup: async () => { throw quotaErr; } });

  await assert.rejects(createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } }), quotaErr);
  assert.deepEqual(calls, []);
});

test("Perplexity failure releases the reserved lookup and rethrows", async () => {
  const boom = new HttpsError("internal", "Server error. Try again later.");
  const { deps, calls } = makeDeps({
    lookupFoods: async () => { throw boom; },
  });

  await assert.rejects(createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } }), boom);
  assert.deepEqual(calls, [["reserve", "u1", 0], ["release", "u1", "2026-09-18"]]);
});

test("quota infrastructure failure fails closed with internal", async () => {
  const { deps, calls } = makeDeps({ getPremiumStatus: async () => { throw new Error("firestore down"); } });

  await assert.rejects(
    createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } }),
    (err) => err.code === "internal"
  );
  assert.deepEqual(calls, []);
});

test("unauthenticated calls are rejected", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    createHandlers(deps).getMultipleCarbCounts({ data: { input: "an apple" } }),
    (err) => err.code === "unauthenticated"
  );
});

const activePayload = {
  productId: "premium_yearly",
  transactionId: "2000000333",
  originalTransactionId: "2000000222",
  expiresDate: NOW + 1000,
  environment: "Sandbox",
  bundleId: "com.jamesaguero.mycarbtracker",
};

test("valid active transaction is recorded and reported valid", async () => {
  const { deps, calls } = makeDeps({ verifyTransaction: async () => activePayload });

  const res = await createHandlers(deps).validateAppStoreReceipt({
    auth, data: { receiptData: "a.b.c", expectedProductId: "premium_yearly" },
  });

  assert.deepEqual(calls, [["record", "u1", "premium_yearly"]]);
  assert.deepEqual(res, {
    isValid: true,
    productId: "premium_yearly",
    transactionId: "2000000333",
    originalTransactionId: "2000000222",
    expiresDateMs: NOW + 1000,
    environment: "Sandbox",
    bundleId: "com.jamesaguero.mycarbtracker",
  });
});

test("expired transaction is not recorded", async () => {
  const { deps, calls } = makeDeps({
    verifyTransaction: async () => ({ ...activePayload, expiresDate: NOW - 1 }),
  });

  const res = await createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c" } });

  assert.equal(res.reason, "no-active-subscription");
  assert.deepEqual(calls, []);
});

test("product mismatch still records the entitlement", async () => {
  const { deps, calls } = makeDeps({ verifyTransaction: async () => activePayload });

  const res = await createHandlers(deps).validateAppStoreReceipt({
    auth, data: { receiptData: "a.b.c", expectedProductId: "premium_monthlysub" },
  });

  assert.equal(res.reason, "product-mismatch");
  assert.deepEqual(calls, [["record", "u1", "premium_yearly"]]);
});

test("verification failure maps to failed-precondition", async () => {
  const { deps } = makeDeps({ verifyTransaction: async () => { throw new Error("bad chain"); } });

  await assert.rejects(
    createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c" } }),
    (err) => err.code === "failed-precondition"
  );
});

test("unknown expectedProductId is rejected", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c", expectedProductId: "x" } }),
    (err) => err.code === "invalid-argument"
  );
});
