const { HttpsError } = require("firebase-functions/v2/https");
const { sanitizeFoodInput, isNotBilled, splitUnknownCarbs, listNames } = require("./perplexity");
const { parseTzOffset } = require("./quota");
const { PREMIUM_PRODUCT_IDS, isActiveTransaction, isPermanentVerificationFailure } = require("./appStore");

/**
 * A log-safe description of a verification error. Apple's VerificationException
 * has no message, only a numeric status, so a plain `err.message` logged "".
 */
function describe(err) {
  if (err && typeof err.status === "number") return `status ${err.status}`;
  return err && err.message ? err.message : String(err);
}

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
 *   recordTransaction: (uid: string, payload: object) => Promise<boolean>,
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
    // Sent by builds that know a food can come back with no carb value.
    const acceptsUnknownCarbs = data.acceptsUnknownCarbs === true;

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
      // Refund the lookup only if Perplexity didn't bill it; a billed call
      // that failed afterwards (e.g. unparseable output) still counts.
      if (reservation && isNotBilled(err)) {
        try {
          await deps.releaseLookup(uid, reservation.dayKey);
        } catch (releaseErr) {
          console.error(`[quota] Release failed for ${uid}: ${releaseErr.message}`);
        }
      }
      throw err;
    }

    // Older builds turn a missing carb value into 0 g, the very bug this
    // replaces, so they never see one: they get the foods that were found, or
    // an error naming the ones that weren't. Thrown after the lookup, outside
    // the refund above, so it counts like any other call Perplexity billed.
    let items = result.items;
    if (!acceptsUnknownCarbs) {
      const { known, unknownNames } = splitUnknownCarbs(items);
      if (known.length === 0) {
        throw new HttpsError("not-found", `Couldn't find carbs for ${listNames(unknownNames)}.`);
      }
      items = known;
    }

    return {
      items,
      citations: result.citations,
      quota: premium
        ? { premium: true, used: null, limit: null, dayKey: null }
        : { premium: false, used: reservation.used, limit: reservation.limit, dayKey: reservation.dayKey },
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
      if (isPermanentVerificationFailure(err)) {
        // Apple's final word. Answer in-band, as a verdict, so the client
        // finishes the transaction. As an error it held it instead, StoreKit
        // re-delivered it at every launch, and the user was told "could not
        // verify" on every cold start with no way to clear it.
        console.error(`[jws] Unverifiable transaction for ${uid}: ${describe(err)}`);
        return { isValid: false, reason: "unverifiable" };
      }
      // Nothing is known about the receipt — the online check could not reach
      // Apple, or something unexpected went wrong. An error keeps the client
      // holding the transaction; a verdict here could lose a paid purchase.
      console.error(`[jws] Verification unavailable for ${uid}: ${describe(err)}`);
      throw new HttpsError("unavailable", "Couldn't verify with the App Store right now. Try again shortly.");
    }

    const environment = payload.environment ?? null;
    const bundleId = payload.bundleId ?? null;

    if (!isActiveTransaction(payload, deps.now())) {
      return { isValid: false, reason: "no-active-subscription", environment, bundleId };
    }

    // Any verified, active premium transaction grants premium, even if it is
    // not the product the client expected (e.g. a plan change).
    const granted = await deps.recordTransaction(uid, payload);
    if (!granted) {
      // Purchased before this entitlement was refunded: a replayed JWS.
      return { isValid: false, reason: "revoked", environment, bundleId };
    }

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
