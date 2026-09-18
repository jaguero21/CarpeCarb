const test = require("node:test");
const assert = require("node:assert/strict");
const {
  evaluateEntitlement,
  failOpenPremium,
  entitlementUpdateFromStatus,
  createEntitlementStore,
} = require("../src/entitlements");
const { createFakeFirestore } = require("./helpers/fakeFirestore");

const HOUR = 60 * 60 * 1000;
const NOW = Date.parse("2026-09-18T12:00:00Z");
const expiredDoc = {
  productId: "premium_monthlysub",
  originalTransactionId: "2000000111",
  expiresDateMs: NOW - HOUR,
  environment: "Production",
  revoked: false,
  lastCheckedMs: NOW - 30 * 24 * HOUR,
  lastRefreshAttemptMs: 0,
};

test("no doc means free, nothing to refresh", () => {
  assert.deepEqual(evaluateEntitlement(null, NOW), { premium: false, needsRefresh: false });
});

test("unexpired, unrevoked doc is premium", () => {
  assert.deepEqual(
    evaluateEntitlement({ ...expiredDoc, expiresDateMs: NOW + HOUR }, NOW),
    { premium: true, needsRefresh: false }
  );
});

test("expired doc needs a refresh", () => {
  assert.deepEqual(evaluateEntitlement(expiredDoc, NOW), { premium: false, needsRefresh: true });
});

test("refresh waits 6h after the last successful check", () => {
  const doc = { ...expiredDoc, lastCheckedMs: NOW - 5 * HOUR };
  assert.equal(evaluateEntitlement(doc, NOW).needsRefresh, false);
  assert.equal(evaluateEntitlement({ ...doc, lastCheckedMs: NOW - 6 * HOUR }, NOW).needsRefresh, true);
});

test("refresh waits 15 min after a failed attempt", () => {
  const doc = { ...expiredDoc, lastRefreshAttemptMs: NOW - 10 * 60 * 1000 };
  assert.equal(evaluateEntitlement(doc, NOW).needsRefresh, false);
  assert.equal(evaluateEntitlement({ ...doc, lastRefreshAttemptMs: NOW - 15 * 60 * 1000 }, NOW).needsRefresh, true);
});

test("revoked doc is free and never refreshed", () => {
  assert.deepEqual(
    evaluateEntitlement({ ...expiredDoc, revoked: true, expiresDateMs: NOW + HOUR }, NOW),
    { premium: false, needsRefresh: false }
  );
});

test("failOpenPremium keeps premium for 72h past expiry", () => {
  assert.equal(failOpenPremium({ ...expiredDoc, expiresDateMs: NOW - 71 * HOUR }, NOW), true);
  assert.equal(failOpenPremium({ ...expiredDoc, expiresDateMs: NOW - 72 * HOUR }, NOW), false);
  assert.equal(failOpenPremium({ ...expiredDoc, revoked: true }, NOW), false);
});

test("ACTIVE status takes the renewed expiry", () => {
  const update = entitlementUpdateFromStatus(
    { status: 1, transaction: { expiresDate: NOW + 30 * 24 * HOUR, productId: "premium_yearly" } },
    NOW
  );
  assert.deepEqual(update, {
    lastCheckedMs: NOW,
    lastRefreshAttemptMs: NOW,
    expiresDateMs: NOW + 30 * 24 * HOUR,
    revoked: false,
    productId: "premium_yearly",
  });
});

test("BILLING_GRACE_PERIOD grants access until the next check", () => {
  const update = entitlementUpdateFromStatus({ status: 4, transaction: { expiresDate: NOW - HOUR } }, NOW);
  assert.equal(update.expiresDateMs, NOW + 6 * HOUR);
  assert.equal(update.revoked, false);
});

test("EXPIRED and BILLING_RETRY only record the check", () => {
  for (const status of [2, 3]) {
    assert.deepEqual(entitlementUpdateFromStatus({ status, transaction: null }, NOW), {
      lastCheckedMs: NOW,
      lastRefreshAttemptMs: NOW,
    });
  }
});

test("REVOKED marks the doc revoked", () => {
  assert.equal(entitlementUpdateFromStatus({ status: 5, transaction: null }, NOW).revoked, true);
});

test("getPremiumStatus refreshes an expired entitlement from Apple", async () => {
  const db = createFakeFirestore({ "entitlements/u1": expiredDoc });
  const calls = [];
  const appStore = {
    async fetchSubscriptionStatus(id, env) {
      calls.push([id, env]);
      return { status: 1, transaction: { expiresDate: NOW + 24 * HOUR, productId: "premium_monthlysub" } };
    },
  };
  const store = createEntitlementStore({ db, appStore, now: () => NOW });

  assert.equal(await store.getPremiumStatus("u1"), true);
  assert.deepEqual(calls, [["2000000111", "Production"]]);
  assert.equal(db.docs.get("entitlements/u1").expiresDateMs, NOW + 24 * HOUR);
});

test("getPremiumStatus falls back to the 72h window when Apple fails", async () => {
  const db = createFakeFirestore({ "entitlements/u1": expiredDoc });
  const appStore = { fetchSubscriptionStatus: async () => { throw new Error("503"); } };
  const store = createEntitlementStore({ db, appStore, now: () => NOW });

  assert.equal(await store.getPremiumStatus("u1"), true); // expired 1h ago
  assert.equal(db.docs.get("entitlements/u1").lastRefreshAttemptMs, NOW);
});

test("getPremiumStatus does not call Apple for a user with no entitlement", async () => {
  const db = createFakeFirestore();
  const appStore = { fetchSubscriptionStatus: async () => assert.fail("should not be called") };
  const store = createEntitlementStore({ db, appStore, now: () => NOW });

  assert.equal(await store.getPremiumStatus("nobody"), false);
});

test("recordTransaction writes a fresh entitlement doc", async () => {
  const db = createFakeFirestore();
  const store = createEntitlementStore({ db, appStore: {}, now: () => NOW });

  await store.recordTransaction("u1", {
    productId: "premium_yearly",
    originalTransactionId: "2000000222",
    expiresDate: NOW + 365 * 24 * HOUR,
    environment: "Sandbox",
  });
  assert.deepEqual(db.docs.get("entitlements/u1"), {
    productId: "premium_yearly",
    originalTransactionId: "2000000222",
    expiresDateMs: NOW + 365 * 24 * HOUR,
    environment: "Sandbox",
    revoked: false,
    lastCheckedMs: NOW,
    lastRefreshAttemptMs: 0,
  });
});
