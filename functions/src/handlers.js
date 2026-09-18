const { HttpsError } = require("firebase-functions/v2/https");
const { sanitizeFoodInput } = require("./perplexity");
const { parseTzOffset } = require("./quota");
const { PREMIUM_PRODUCT_IDS, isActiveTransaction } = require("./appStore");

/**
 * Builds the callable handlers from injected dependencies so they can be
 * tested without Firestore, Apple, or Perplexity.
 *
 * @param {{
 *   checkRateLimit: (uid: string, action: string, limit: number, windowSec: number) => Promise<void>,
 *   getPremiumStatus: (uid: string) => Promise<boolean>,
 *   reserveLookup: (uid: string, tzOffsetMin: number) => Promise<{dayKey: string, used: number, limit: number}>,
 *   releaseLookup: (uid: string, dayKey: string) => Promise<void>,
 *   lookupFoods: (sanitized: string) => Promise<{items: object[], citations: string[]}>,
 *   verifyTransaction: (jws: string) => Promise<object>,
 *   recordTransaction: (uid: string, payload: object) => Promise<void>,
 *   now: () => number,
 * }} deps
 */
function createHandlers(deps) {
  async function getMultipleCarbCounts(request) {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }
    const uid = request.auth.uid;

    // 20 carb lookups per minute per user
    await deps.checkRateLimit(uid, "getCarbCounts", 20, 60);

    const data = request.data || {};
    const sanitized = sanitizeFoodInput(data.input);
    const tzOffsetMin = parseTzOffset(data.tzOffsetMinutes);

    // Fail closed: if premium status or the quota can't be checked, don't
    // spend a Perplexity call.
    let premium;
    let reservation = null;
    try {
      premium = await deps.getPremiumStatus(uid);
      if (!premium) reservation = await deps.reserveLookup(uid, tzOffsetMin);
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      console.error(`[quota] Check failed for ${uid}: ${err.message}`);
      throw new HttpsError("internal", "Could not check your lookup quota. Please try again.");
    }

    let result;
    try {
      result = await deps.lookupFoods(sanitized);
    } catch (err) {
      if (reservation) {
        try {
          await deps.releaseLookup(uid, reservation.dayKey);
        } catch (releaseErr) {
          console.error(`[quota] Release failed for ${uid}: ${releaseErr.message}`);
        }
      }
      throw err;
    }

    return {
      items: result.items,
      citations: result.citations,
      quota: premium
        ? { premium: true, used: null, limit: null }
        : { premium: false, used: reservation.used, limit: reservation.limit },
    };
  }

  async function validateAppStoreReceipt(request) {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }
    const uid = request.auth.uid;

    // 10 receipt validations per hour per user
    await deps.checkRateLimit(uid, "validateReceipt", 10, 3600);

    const { receiptData, expectedProductId } = request.data || {};

    if (!receiptData || typeof receiptData !== "string") {
      throw new HttpsError("invalid-argument", "receiptData is required.");
    }

    if (
      expectedProductId != null &&
      (typeof expectedProductId !== "string" || !PREMIUM_PRODUCT_IDS.has(expectedProductId))
    ) {
      throw new HttpsError("invalid-argument", "expectedProductId is not recognized.");
    }

    let payload;
    try {
      payload = await deps.verifyTransaction(receiptData);
    } catch (err) {
      console.error(`[jws] Verification failed for ${uid}: ${err.message}`);
      throw new HttpsError("failed-precondition", "App Store could not verify this transaction.");
    }

    const environment = payload.environment ?? null;
    const bundleId = payload.bundleId ?? null;

    if (!isActiveTransaction(payload, deps.now())) {
      return { isValid: false, reason: "no-active-subscription", environment, bundleId };
    }

    // Any verified, active premium transaction grants premium, even if it is
    // not the product the client expected (e.g. a plan change).
    await deps.recordTransaction(uid, payload);

    if (expectedProductId && payload.productId !== expectedProductId) {
      return {
        isValid: false,
        reason: "product-mismatch",
        productId: payload.productId,
        expiresDateMs: payload.expiresDate,
        environment,
        bundleId,
      };
    }

    return {
      isValid: true,
      productId: payload.productId,
      transactionId: payload.transactionId ?? null,
      originalTransactionId: payload.originalTransactionId ?? null,
      expiresDateMs: payload.expiresDate,
      environment,
      bundleId,
    };
  }

  return { getMultipleCarbCounts, validateAppStoreReceipt };
}

module.exports = { createHandlers };
