const test = require("node:test");
const assert = require("node:assert/strict");
const { HttpsError } = require("firebase-functions/v2/https");
const { createHandlers } = require("../src/handlers");
const { notBilled } = require("../src/perplexity");
const {
  VerificationException,
  VerificationStatus,
} = require("@apple/app-store-server-library");
const { MalformedTransactionError } = require("../src/appStore");

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
      return true;
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
  assert.deepEqual(res.quota, { premium: false, used: 1, limit: 4, dayKey: "2026-09-18" });
  assert.equal(res.items[0].name, "Apple");
});

test("premium lookup skips the quota", async () => {
  const { deps, calls } = makeDeps({ getPremiumStatus: async () => true });
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({ auth, data: { input: "an apple" } });

  assert.deepEqual(calls, [["lookup", "an apple"]]);
  assert.deepEqual(res.quota, { premium: true, used: null, limit: null, dayKey: null });
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

test("Perplexity failure that wasn't billed releases the reserved lookup and rethrows", async () => {
  const boom = notBilled(new HttpsError("internal", "Server error. Try again later."));
  const { deps, calls } = makeDeps({
    lookupFoods: async () => { throw boom; },
  });

  await assert.rejects(createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } }), boom);
  assert.deepEqual(calls, [["reserve", "u1", 0], ["release", "u1", "2026-09-18"]]);
});

test("billed Perplexity failure rethrows without releasing the lookup", async () => {
  const boom = new HttpsError("internal", "Could not parse food items");
  const { deps, calls } = makeDeps({
    lookupFoods: async () => { throw boom; },
  });

  await assert.rejects(createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } }), boom);
  assert.deepEqual(calls, [["reserve", "u1", 0]]);
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

test("a transaction refunded before it was replayed is reported revoked", async () => {
  const { deps } = makeDeps({
    verifyTransaction: async () => activePayload,
    recordTransaction: async () => false,
  });

  const res = await createHandlers(deps).validateAppStoreReceipt({
    auth, data: { receiptData: "a.b.c", expectedProductId: "premium_monthlysub" },
  });

  assert.deepEqual(res, {
    isValid: false,
    reason: "revoked",
    environment: "Sandbox",
    bundleId: "com.jamesaguero.mycarbtracker",
  });
});

// How a verification failure is reported decides whether the client finishes
// the transaction. A rejection tells it to complete, which drops the purchase
// from StoreKit's queue for good; an error tells it to hold and retry. Only a
// transaction too malformed to read may be reported as a rejection.

async function validateWith(verifyTransaction) {
  const { deps } = makeDeps({ verifyTransaction });
  return createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c" } });
}

test("a transaction too malformed to read is reported as unverifiable", async () => {
  // It could never verify. Held, StoreKit would re-deliver it at every launch
  // and the user would see "could not verify" on every cold start.
  const result = await validateWith(async () => {
    throw new MalformedTransactionError("Malformed JWS.");
  });

  assert.deepEqual(result, { isValid: false, reason: "unverifiable" });
});

test("no status Apple's verifier can raise is treated as final", async () => {
  // The library reports an OCSP `tryLater`, a connection reset while reading
  // the OCSP response, and a stale cached response as VERIFICATION_FAILURE or
  // FAILURE — the same statuses a bad signature produces. Treating any of them
  // as final would, during a hiccup at Apple, finish real purchases ungranted.
  // So every status, present and future, must leave the client holding.
  const statuses = Object.values(VerificationStatus).filter((v) => typeof v === "number");
  assert.ok(statuses.length >= 8, "expected the library's full status list");

  for (const status of statuses) {
    await assert.rejects(
      validateWith(async () => { throw new VerificationException(status); }),
      (err) => err.code === "unavailable",
      `status ${VerificationStatus[status]} must hold, not finish`
    );
  }
});

test("an unrecognised failure stays an error, so the client holds", async () => {
  // Not every throw is a verdict — it could be a bug here.
  await assert.rejects(
    validateWith(async () => { throw new Error("something unexpected"); }),
    (err) => err.code === "unavailable"
  );
});

test("unknown expectedProductId is rejected", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c", expectedProductId: "x" } }),
    (err) => err.code === "invalid-argument"
  );
});

// ── Unknown carb values (review #12) ──

const burgerAndUnknownFries = async () => ({
  items: [{ name: "Burger", carbs: 30 }, { name: "Fries", carbs: null }],
  citations: [],
});

test("a client that accepts unknown carbs gets them as null", async () => {
  const { deps } = makeDeps({ lookupFoods: burgerAndUnknownFries });
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({
    auth, data: { input: "burger and fries", acceptsUnknownCarbs: true },
  });

  assert.deepEqual(res.items.map((i) => [i.name, i.carbs]), [["Burger", 30], ["Fries", null]]);
});

test("an older client never sees a null: foods with unknown carbs are dropped", async () => {
  // Those builds turn null into 0 g, which is the bug being fixed.
  const { deps } = makeDeps({ lookupFoods: burgerAndUnknownFries });
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({ auth, data: { input: "burger and fries" } });

  assert.deepEqual(res.items.map((i) => i.name), ["Burger"]);
});

test("an older client gets a named error when nothing was found, and it still counts", async () => {
  const { deps, calls } = makeDeps({
    lookupFoods: async () => ({
      items: [{ name: "Fries", carbs: null }, { name: "Shake", carbs: null }],
      citations: [],
    }),
  });
  const { getMultipleCarbCounts } = createHandlers(deps);

  await assert.rejects(
    getMultipleCarbCounts({ auth, data: { input: "fries and shake" } }),
    (err) => {
      assert.equal(err.code, "not-found");
      assert.equal(err.message, "Couldn't find carbs for Fries and Shake.");
      return true;
    }
  );
  // Perplexity billed the call, so the lookup is not given back.
  assert.equal(calls.some(([kind]) => kind === "release"), false);
});
