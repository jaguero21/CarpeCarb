const { Status } = require("@apple/app-store-server-library");

const HOUR_MS = 60 * 60 * 1000;
const REFRESH_INTERVAL_MS = 6 * HOUR_MS;
const RETRY_BACKOFF_MS = 15 * 60 * 1000;
const FAIL_OPEN_WINDOW_MS = 72 * HOUR_MS;

/**
 * Decides premium status from a stored entitlement doc.
 *
 * @param {object | null} doc - entitlements/{uid}
 * @param {number} nowMs
 * @returns {{premium: boolean, needsRefresh: boolean}}
 */
function evaluateEntitlement(doc, nowMs) {
  if (!doc) return { premium: false, needsRefresh: false };
  if (!doc.revoked && typeof doc.expiresDateMs === "number" && doc.expiresDateMs > nowMs) {
    return { premium: true, needsRefresh: false };
  }
  if (doc.revoked || !doc.originalTransactionId) {
    return { premium: false, needsRefresh: false };
  }
  const checkedRecently = nowMs - (doc.lastCheckedMs ?? 0) < REFRESH_INTERVAL_MS;
  const attemptedRecently = nowMs - (doc.lastRefreshAttemptMs ?? 0) < RETRY_BACKOFF_MS;
  return { premium: false, needsRefresh: !checkedRecently && !attemptedRecently };
}

/**
 * Premium status to use when a refresh against Apple failed: keep premium
 * for up to 72h past the stored expiry so an Apple outage doesn't demote
 * someone who actually renewed.
 */
function failOpenPremium(doc, nowMs) {
  return (
    !doc.revoked &&
    typeof doc.expiresDateMs === "number" &&
    nowMs - doc.expiresDateMs < FAIL_OPEN_WINDOW_MS
  );
}

/**
 * Maps an App Store Server API status lookup to fields to merge into the doc.
 *
 * @param {{status: number | null, transaction: {expiresDate?: number, productId?: string} | null}} result
 * @param {number} nowMs
 */
function entitlementUpdateFromStatus(result, nowMs) {
  const update = { lastCheckedMs: nowMs, lastRefreshAttemptMs: nowMs };
  if (result.status === Status.REVOKED) {
    update.revoked = true;
  } else if (result.status === Status.ACTIVE || result.status === Status.BILLING_GRACE_PERIOD) {
    const txnExpiry = result.transaction?.expiresDate ?? 0;
    // In billing grace the transaction's own expiry is already past; grant
    // access until the next scheduled check instead.
    update.expiresDateMs =
      result.status === Status.ACTIVE && txnExpiry > nowMs ? txnExpiry : nowMs + REFRESH_INTERVAL_MS;
    update.revoked = false;
    if (result.transaction?.productId) update.productId = result.transaction.productId;
  }
  // EXPIRED, BILLING_RETRY, or unknown: leave expiresDateMs in the past.
  return update;
}

/**
 * @param {{
 *   db: FirebaseFirestore.Firestore,
 *   appStore: {fetchSubscriptionStatus: (originalTransactionId: string, env: string) => Promise<object>},
 *   now: () => number,
 * }} deps
 */
function createEntitlementStore({ db, appStore, now }) {
  const refFor = (uid) => db.collection("entitlements").doc(uid);

  /** @returns {Promise<boolean>} */
  async function getPremiumStatus(uid) {
    const ref = refFor(uid);
    const snap = await ref.get();
    const doc = snap.exists ? snap.data() : null;
    const nowMs = now();
    const { premium, needsRefresh } = evaluateEntitlement(doc, nowMs);
    if (!needsRefresh) return premium;

    try {
      const result = await appStore.fetchSubscriptionStatus(doc.originalTransactionId, doc.environment);
      const update = entitlementUpdateFromStatus(result, nowMs);
      await ref.set(update, { merge: true });
      return evaluateEntitlement({ ...doc, ...update }, nowMs).premium;
    } catch (err) {
      console.error(`[entitlements] Refresh failed for ${uid}: ${err.message}`);
      try {
        await ref.set({ lastRefreshAttemptMs: nowMs }, { merge: true });
      } catch (writeErr) {
        console.error(`[entitlements] Could not record refresh attempt for ${uid}: ${writeErr.message}`);
      }
      return failOpenPremium(doc, nowMs);
    }
  }

  /** Stores a verified, active transaction as this user's entitlement. */
  async function recordTransaction(uid, payload) {
    await refFor(uid).set({
      productId: payload.productId,
      originalTransactionId: payload.originalTransactionId,
      expiresDateMs: payload.expiresDate,
      environment: payload.environment,
      revoked: false,
      lastCheckedMs: now(),
      lastRefreshAttemptMs: 0,
    });
  }

  return { getPremiumStatus, recordTransaction };
}

module.exports = {
  evaluateEntitlement,
  failOpenPremium,
  entitlementUpdateFromStatus,
  createEntitlementStore,
};
