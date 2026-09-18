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
    evaluateEntitlement({ ...expiredDoc, expiresDateMs: NOW + HOUR, lastCheckedMs: NOW - HOUR }, NOW),
    { premium: true, needsRefresh: false }
  );
});

test("active doc is re-checked daily so refunds are noticed", () => {
  assert.deepEqual(
    evaluateEntitlement({ ...expiredDoc, expiresDateMs: NOW + HOUR, lastCheckedMs: NOW - 24 * HOUR }, NOW),
    { premium: true, needsRefresh: true }
  );
});

test("expired doc needs a refresh", () => {
  assert.deepEqual(evaluateEntitlement(expiredDoc, NOW), { premium: false, needsRefresh: true });
});

test("refresh waits 6h after the last successful check", () => {
  const doc = { ...expiredDoc, expiresDateMs: NOW - 24 * HOUR, lastCheckedMs: NOW - 5 * HOUR };
  assert.equal(evaluateEntitlement(doc, NOW).needsRefresh, false);
  assert.equal(evaluateEntitlement({ ...doc, lastCheckedMs: NOW - 6 * HOUR }, NOW).needsRefresh, true);
});

test("a check made before the expiry does not delay the refresh", () => {
  const doc = { ...expiredDoc, expiresDateMs: NOW - 60_000, lastCheckedMs: NOW - HOUR };
  assert.equal(evaluateEntitlement(doc, NOW).needsRefresh, true);
});

test("fail-open covers every request in the backoff after a failed refresh", () => {
  const doc = { ...expiredDoc, lastCheckedMs: NOW - 30 * 24 * HOUR, lastRefreshAttemptMs: NOW - 60_000 };
  assert.deepEqual(evaluateEntitlement(doc, NOW), { premium: true, needsRefresh: false });
});

test("refresh waits 15 min after a failed attempt", () => {
  const doc = { ...expiredDoc, lastRefreshAttemptMs: NOW - 10 * 60 * 1000 };
  assert.equal(evaluateEntitlement(doc, NOW).needsRefresh, false);
  assert.equal(evaluateEntitlement({ ...doc, lastRefreshAttemptMs: NOW - 15 * 60 * 1000 }, NOW).needsRefresh, true);
});

test("a successful check does not start the 15 min backoff", () => {
  // Checked successfully 2 min ago (1 min before the expiry), no failure since.
  const doc = { ...expiredDoc, expiresDateMs: NOW - 60_000, lastCheckedMs: NOW - 2 * 60_000, lastRefreshAttemptMs: NOW - 2 * 60_000 };
  assert.equal(evaluateEntitlement(doc, NOW).needsRefresh, true);
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

test("REVOKED records when the refund happened", () => {
  const withDate = entitlementUpdateFromStatus({ status: 5, transaction: { revocationDate: NOW - HOUR } }, NOW);
  assert.equal(withDate.revokedAtMs, NOW - HOUR);
  assert.equal(entitlementUpdateFromStatus({ status: 5, transaction: null }, NOW).revokedAtMs, NOW);
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

test("getPremiumStatus refreshes after a sandbox renewal passes the recorded expiry", async () => {
  const db = createFakeFirestore();
  let clock = NOW;
  const calls = [];
  const appStore = {
    async fetchSubscriptionStatus(id, env) {
      calls.push([id, env]);
      return { status: 1, transaction: { expiresDate: NOW + 10 * 60_000, productId: "premium_monthlysub" } };
    },
  };
  const store = createEntitlementStore({ db, appStore, now: () => clock });

  await store.recordTransaction("u1", {
    productId: "premium_monthlysub",
    originalTransactionId: "2000000111",
    expiresDate: NOW + 5 * 60_000,
    purchaseDate: NOW,
    environment: "Sandbox",
  });
  clock = NOW + 6 * 60_000;

  assert.equal(await store.getPremiumStatus("u1"), true);
  assert.deepEqual(calls, [["2000000111", "Sandbox"]]);
});

test("getPremiumStatus keeps failing open through the retry backoff", async () => {
  const db = createFakeFirestore({ "entitlements/u1": expiredDoc });
  let clock = NOW;
  let appleCalls = 0;
  const appStore = {
    async fetchSubscriptionStatus() {
      appleCalls += 1;
      throw new Error("503");
    },
  };
  const store = createEntitlementStore({ db, appStore, now: () => clock });

  assert.equal(await store.getPremiumStatus("u1"), true);
  clock = NOW + 60_000;
  assert.equal(await store.getPremiumStatus("u1"), true);
  assert.equal(appleCalls, 1);
});

test("getPremiumStatus trusts a recently checked active doc without calling Apple", async () => {
  const db = createFakeFirestore({
    "entitlements/u1": { ...expiredDoc, expiresDateMs: NOW + 24 * HOUR, lastCheckedMs: NOW - HOUR },
  });
  const appStore = { fetchSubscriptionStatus: async () => assert.fail("should not be called") };
  const store = createEntitlementStore({ db, appStore, now: () => NOW });

  assert.equal(await store.getPremiumStatus("u1"), true);
});

test("getPremiumStatus does not call Apple for a revoked doc", async () => {
  const db = createFakeFirestore({
    "entitlements/u1": { ...expiredDoc, expiresDateMs: NOW + 24 * HOUR, revoked: true, revokedAtMs: NOW - HOUR },
  });
  const appStore = { fetchSubscriptionStatus: async () => assert.fail("should not be called") };
  const store = createEntitlementStore({ db, appStore, now: () => NOW });

  assert.equal(await store.getPremiumStatus("u1"), false);
});

test("getPremiumStatus notices a refund on the daily re-check", async () => {
  const db = createFakeFirestore({
    "entitlements/u1": { ...expiredDoc, expiresDateMs: NOW + 300 * 24 * HOUR, lastCheckedMs: NOW - 25 * HOUR },
  });
  const appStore = {
    fetchSubscriptionStatus: async () => ({ status: 5, transaction: { revocationDate: NOW - HOUR } }),
  };
  const store = createEntitlementStore({ db, appStore, now: () => NOW });

  assert.equal(await store.getPremiumStatus("u1"), false);
  const doc = db.docs.get("entitlements/u1");
  assert.equal(doc.revoked, true);
  assert.equal(doc.revokedAtMs, NOW - HOUR);
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

  const granted = await store.recordTransaction("u1", {
    productId: "premium_yearly",
    originalTransactionId: "2000000222",
    expiresDate: NOW + 365 * 24 * HOUR,
    environment: "Sandbox",
  });
  assert.equal(granted, true);
  assert.deepEqual(db.docs.get("entitlements/u1"), {
    productId: "premium_yearly",
    originalTransactionId: "2000000222",
    expiresDateMs: NOW + 365 * 24 * HOUR,
    environment: "Sandbox",
    revoked: false,
    lastCheckedMs: 0,
    lastRefreshAttemptMs: 0,
  });
});

const revokedDoc = {
  ...expiredDoc,
  expiresDateMs: NOW + 300 * 24 * HOUR,
  revoked: true,
  revokedAtMs: NOW - HOUR,
};
const replayPayload = {
  productId: "premium_monthlysub",
  originalTransactionId: "2000000111",
  expiresDate: NOW + 24 * HOUR,
  environment: "Production",
};

test("recordTransaction refuses to replay a transaction bought before its refund", async () => {
  const db = createFakeFirestore({ "entitlements/u1": revokedDoc });
  const store = createEntitlementStore({ db, appStore: {}, now: () => NOW });

  const granted = await store.recordTransaction("u1", { ...replayPayload, purchaseDate: NOW - 30 * 24 * HOUR });

  assert.equal(granted, false);
  assert.deepEqual(db.docs.get("entitlements/u1"), revokedDoc);
});

test("recordTransaction accepts a resubscription after a refund", async () => {
  const db = createFakeFirestore({ "entitlements/u1": revokedDoc });
  const store = createEntitlementStore({ db, appStore: {}, now: () => NOW });

  const granted = await store.recordTransaction("u1", { ...replayPayload, purchaseDate: NOW });

  assert.equal(granted, true);
  assert.deepEqual(db.docs.get("entitlements/u1"), {
    productId: "premium_monthlysub",
    originalTransactionId: "2000000111",
    expiresDateMs: NOW + 24 * HOUR,
    environment: "Production",
    revoked: false,
    lastCheckedMs: 0,
    lastRefreshAttemptMs: 0,
  });
});

test("recordTransaction refuses an undated transaction for a revoked entitlement", async () => {
  const db = createFakeFirestore({ "entitlements/u1": revokedDoc });
  const store = createEntitlementStore({ db, appStore: {}, now: () => NOW });

  const granted = await store.recordTransaction("u1", replayPayload);

  assert.equal(granted, false);
  assert.deepEqual(db.docs.get("entitlements/u1"), revokedDoc);
});

test("the first lookup after recordTransaction re-checks with Apple, then trusts the result", async () => {
  const db = createFakeFirestore();
  let clock = NOW;
  let appleCalls = 0;
  const appStore = {
    async fetchSubscriptionStatus() {
      appleCalls += 1;
      return { status: 1, transaction: { expiresDate: NOW + 30 * 24 * HOUR, productId: "premium_monthlysub" } };
    },
  };
  const store = createEntitlementStore({ db, appStore, now: () => clock });

  await store.recordTransaction("u1", { ...replayPayload, expiresDate: NOW + 30 * 24 * HOUR, purchaseDate: NOW });
  assert.equal(await store.getPremiumStatus("u1"), true);
  assert.equal(appleCalls, 1);

  clock = NOW + HOUR;
  assert.equal(await store.getPremiumStatus("u1"), true);
  assert.equal(appleCalls, 1);
});

test("a refunded receipt replayed on a fresh UID is caught on the first lookup", async () => {
  const db = createFakeFirestore();
  const appStore = {
    fetchSubscriptionStatus: async () => ({ status: 5, transaction: { revocationDate: NOW - HOUR } }),
  };
  const store = createEntitlementStore({ db, appStore, now: () => NOW });

  const granted = await store.recordTransaction("fresh", { ...replayPayload, purchaseDate: NOW - 30 * 24 * HOUR });

  assert.equal(granted, true);
  assert.equal(await store.getPremiumStatus("fresh"), false);
});

test("a sandbox renewal is picked up minutes after the previous successful check", async () => {
  const db = createFakeFirestore();
  let clock = NOW;
  let appleCalls = 0;
  const appStore = {
    async fetchSubscriptionStatus() {
      appleCalls += 1;
      // Sandbox monthly: each renewal runs 5 min from now.
      return { status: 1, transaction: { expiresDate: clock + 5 * 60_000, productId: "premium_monthlysub" } };
    },
  };
  const store = createEntitlementStore({ db, appStore, now: () => clock });

  await store.recordTransaction("u1", { ...replayPayload, expiresDate: NOW + 5 * 60_000, purchaseDate: NOW });
  assert.equal(await store.getPremiumStatus("u1"), true);
  assert.equal(appleCalls, 1);

  clock = NOW + 6 * 60_000;
  assert.equal(await store.getPremiumStatus("u1"), true);
  assert.equal(appleCalls, 2);
});
