const { HttpsError } = require("firebase-functions/v2/https");

const FREE_DAILY_LOOKUP_LIMIT = 4;
const MAX_TZ_OFFSET_MIN = 14 * 60;
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Parses the client-reported UTC offset in minutes. Anything that is not an
 * integer becomes 0 (UTC); values are clamped to the real-world range ±14h.
 *
 * @param {unknown} value
 * @returns {number}
 */
function parseTzOffset(value) {
  if (!Number.isInteger(value)) return 0;
  return Math.max(-MAX_TZ_OFFSET_MIN, Math.min(MAX_TZ_OFFSET_MIN, value));
}

/**
 * The caller's local calendar day as YYYY-MM-DD.
 *
 * @param {number} nowMs
 * @param {number} tzOffsetMin - minutes east of UTC (from parseTzOffset)
 * @returns {string}
 */
function dayKey(nowMs, tzOffsetMin) {
  return new Date(nowMs + tzOffsetMin * 60 * 1000).toISOString().slice(0, 10);
}

/**
 * Decides whether one more lookup fits in today's quota.
 *
 * @param {{dayKey: string, count: number} | null} doc - stored quota doc
 * @param {string} key - today's dayKey
 * @param {number} limit
 * @returns {{allowed: boolean, used: number, next: {dayKey: string, count: number} | null}}
 */
function applyReservation(doc, key, limit) {
  const used = doc && doc.dayKey === key ? doc.count : 0;
  if (used >= limit) return { allowed: false, used, next: null };
  return { allowed: true, used: used + 1, next: { dayKey: key, count: used + 1 } };
}

/**
 * Gives back one reserved lookup, if it belongs to the given day.
 *
 * @param {{dayKey: string, count: number} | null} doc
 * @param {string} key
 * @returns {{dayKey: string, count: number} | null} the updated doc, or null for no change
 */
function applyRelease(doc, key) {
  if (!doc || doc.dayKey !== key || doc.count <= 0) return null;
  return { dayKey: key, count: doc.count - 1 };
}

/**
 * @param {{db: FirebaseFirestore.Firestore, now: () => number, limit?: number}} deps
 */
function createQuotaStore({ db, now, limit = FREE_DAILY_LOOKUP_LIMIT }) {
  const refFor = (uid) => db.collection("lookupQuota").doc(uid);

  /**
   * Reserves one lookup for a free user, or throws resource-exhausted with
   * details {reason: "daily-quota", used, limit}.
   *
   * @returns {Promise<{dayKey: string, used: number, limit: number}>}
   */
  async function reserveLookup(uid, tzOffsetMin) {
    const nowMs = now();
    const key = dayKey(nowMs, tzOffsetMin);
    const ref = refFor(uid);

    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const decision = applyReservation(snap.exists ? snap.data() : null, key, limit);
      if (decision.allowed) {
        tx.set(ref, { ...decision.next, expiresAt: new Date(nowMs + 2 * DAY_MS) });
      }
      return decision;
    });

    if (!result.allowed) {
      throw new HttpsError(
        "resource-exhausted",
        `You've used today's ${limit} free lookups.`,
        { reason: "daily-quota", used: result.used, limit }
      );
    }
    return { dayKey: key, used: result.used, limit };
  }

  /** Returns a reserved lookup after a failed Perplexity call. */
  async function releaseLookup(uid, key) {
    const ref = refFor(uid);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const next = applyRelease(snap.exists ? snap.data() : null, key);
      if (next) tx.update(ref, next);
    });
  }

  return { reserveLookup, releaseLookup };
}

module.exports = {
  FREE_DAILY_LOOKUP_LIMIT,
  parseTzOffset,
  dayKey,
  applyReservation,
  applyRelease,
  createQuotaStore,
};
