const { HttpsError } = require("firebase-functions/v2/https");

/**
 * Fixed-window rate limiter backed by Firestore.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @returns {(uid: string, action: string, limit: number, windowSec: number) => Promise<void>}
 */
function createRateLimiter(db) {
  return async function checkRateLimit(uid, action, limit, windowSec) {
    const docRef = db.collection("rateLimits").doc(`${uid}_${action}`);
    const nowSec = Math.floor(Date.now() / 1000);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      // expiresAt is set so a Firestore TTL policy can auto-delete stale docs.
      // Configure TTL on the `rateLimits` collection using this field in the
      // Firebase console: Firestore → Data → rateLimits → TTL policy → expiresAt
      const expiresAt = new Date((nowSec + windowSec * 2) * 1000);

      if (!snap.exists) {
        tx.set(docRef, { count: 1, windowStart: nowSec, expiresAt });
        return;
      }

      const { count, windowStart } = snap.data();

      if (nowSec - windowStart >= windowSec) {
        // Window has expired — start a fresh one
        tx.set(docRef, { count: 1, windowStart: nowSec, expiresAt });
        return;
      }

      if (count >= limit) {
        const retryAfter = windowStart + windowSec - nowSec;
        throw new HttpsError(
          "resource-exhausted",
          `Rate limit exceeded. Try again in ${retryAfter} second(s).`
        );
      }

      tx.update(docRef, { count: count + 1, expiresAt });
    });
  };
}

module.exports = { createRateLimiter };
