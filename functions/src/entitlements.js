const { Status } = require("@apple/app-store-server-library");

const HOUR_MS = 60 * 60 * 1000;
const REFRESH_INTERVAL_MS = 6 * HOUR_MS;
const RETRY_BACKOFF_MS = 15 * 60 * 1000;
const FAIL_OPEN_WINDOW_MS = 72 * HOUR_MS;
const ACTIVE_RECHECK_MS = 24 * HOUR_MS;

/**
 * Decides premium status from a stored entitlement doc.
 *
 * @param {object | null} doc - entitlements/{uid}
 * @param {number} nowMs
 * @returns {{premium: boolean, needsRefresh: boolean}}
 */
function evaluateEntitlement(doc, nowMs) {
  if (!doc || doc.revoked) return { premium: false, needsRefresh: false };

  const lastChecked = doc.lastCheckedMs ?? 0;
  const lastAttempt = doc.lastRefreshAttemptMs ?? 0;
  // A refresh attempt newer than the last good check means Apple was unreachable.
  // Only a failed attempt starts the 15 min backoff: successful checks stamp
  // lastRefreshAttemptMs too, and a sandbox monthly renews every 5 min.
  const lastAttemptFailed = lastAttempt > lastChecked;
  const canRefresh =
    Boolean(doc.originalTransactionId) && (!lastAttemptFailed || nowMs - lastAttempt >= RETRY_BACKOFF_MS);

  if (typeof doc.expiresDateMs === "number" && doc.expiresDateMs > nowMs) {
    // Active: re-check daily so a refund is noticed without waiting for expiry.
    return { premium: true, needsRefresh: canRefresh && nowMs - lastChecked >= ACTIVE_RECHECK_MS };
  }

  // Expired. Only a check made after the stored expiry can confirm the lapse;
  // a check from before it (e.g. at purchase) says nothing about renewal.
  const confirmedLapsedRecently =
    lastChecked > doc.expiresDateMs && nowMs - lastChecked < REFRESH_INTERVAL_MS;
  // After a failed attempt, keep the 72 h fail-open for every request in the
  // backoff window, not just the one that attempted.
  return {
    premium: lastAttemptFailed && failOpenPremium(doc, nowMs),
    needsRefresh: canRefresh && !confirmedLapsedRecently,
  };
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
 * @param {{status: number | null, transaction: {expiresDate?: number, productId?: string, revocationDate?: number} | null}} result
 * @param {number} nowMs
 */
function entitlementUpdateFromStatus(result, nowMs) {
  const update = { lastCheckedMs: nowMs, lastRefreshAttemptMs: nowMs };
  if (result.status === Status.REVOKED) {
    update.revoked = true;
    update.revokedAtMs = result.transaction?.revocationDate ?? nowMs;
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

  /**
   * Stores a verified, active transaction as this user's entitlement.
   *
   * Refuses a transaction purchased before this entitlement was revoked
   * (a replay of the pre-refund JWS), or with no purchase date to prove
   * otherwise. A later purchase with the same originalTransactionId is a
   * resubscription and is accepted.
   *
   * The doc is written as never checked (lastCheckedMs: 0), so the first
   * lookup re-checks the subscription with Apple: a refunded receipt replayed
   * on a fresh UID is caught there instead of getting 24 h of premium. If
   * Apple is down, the unexpired doc still fails open.
   *
   * @returns {Promise<boolean>} true if the entitlement was written
   */
  async function recordTransaction(uid, payload) {
    const ref = refFor(uid);
    const snap = await ref.get();
    const existing = snap.exists ? snap.data() : null;
    if (
      existing?.revoked &&
      existing.originalTransactionId === payload.originalTransactionId &&
      !(payload.purchaseDate > (existing.revokedAtMs ?? Infinity))
    ) {
      console.warn(
        `[entitlements] Ignoring revoked transaction ${payload.originalTransactionId} replayed by ${uid}`
      );
      return false;
    }

    await ref.set({
      productId: payload.productId,
      originalTransactionId: payload.originalTransactionId,
      expiresDateMs: payload.expiresDate,
      environment: payload.environment,
      revoked: false,
      lastCheckedMs: 0,
      lastRefreshAttemptMs: 0,
    });
    return true;
  }

  return { getPremiumStatus, recordTransaction };
}

module.exports = {
  evaluateEntitlement,
  failOpenPremium,
  entitlementUpdateFromStatus,
  createEntitlementStore,
};
