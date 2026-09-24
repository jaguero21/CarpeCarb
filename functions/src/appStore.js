const {
  AppStoreServerAPIClient,
  Environment,
  SignedDataVerifier,
} = require("@apple/app-store-server-library");

const PREMIUM_PRODUCT_IDS = new Set([
  "premium_monthlysub",
  "premium_yearly",
]);

const SUPPORTED_ENVIRONMENTS = [Environment.PRODUCTION, Environment.SANDBOX];

/**
 * Reads the `environment` claim from a JWS payload WITHOUT verifying it.
 * Only used to pick which verifier to run; the verifier then enforces it.
 *
 * @param {string} jws
 * @returns {string}
 */
/**
 * A transaction that could never verify: not a JWS, an unreadable payload, or
 * an environment this app doesn't serve. A distinct type so it can be told
 * apart from an unexpected error, which must not be treated as final.
 */
class MalformedTransactionError extends Error {}

function peekEnvironment(jws) {
  const parts = typeof jws === "string" ? jws.split(".") : [];
  if (parts.length !== 3) throw new MalformedTransactionError("Malformed JWS.");
  let payload;
  try {
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    throw new MalformedTransactionError("Malformed JWS payload.");
  }
  if (!SUPPORTED_ENVIRONMENTS.includes(payload.environment)) {
    throw new MalformedTransactionError(`Unsupported environment: ${payload.environment}`);
  }
  return payload.environment;
}

/**
 * True when a verified transaction grants premium right now.
 *
 * @param {{productId?: string, expiresDate?: number, revocationDate?: number}} payload
 * @param {number} nowMs
 */
function isActiveTransaction(payload, nowMs) {
  return (
    PREMIUM_PRODUCT_IDS.has(payload.productId) &&
    typeof payload.expiresDate === "number" &&
    payload.expiresDate > nowMs &&
    payload.revocationDate == null
  );
}

/**
 * @param {{
 *   rootCerts: Buffer[],   // Apple root CA certificates (DER)
 *   bundleId: string,
 *   appAppleId: number,    // numeric App Store app ID (required for Production)
 *   signingKey: string,    // In-App Purchase key (.p8 contents)
 *   keyId: string,
 *   issuerId: string,
 * }} config
 */
function createAppStore(config) {
  const verifiers = {};
  for (const env of SUPPORTED_ENVIRONMENTS) {
    verifiers[env] = new SignedDataVerifier(
      config.rootCerts,
      true, // online checks: OCSP revocation + current-date validity
      env,
      config.bundleId,
      config.appAppleId
    );
  }

  const apiClients = {};
  function apiClientFor(env) {
    if (!apiClients[env]) {
      apiClients[env] = new AppStoreServerAPIClient(
        config.signingKey,
        config.keyId,
        config.issuerId,
        config.bundleId,
        env
      );
    }
    return apiClients[env];
  }

  /**
   * Verifies a StoreKit 2 signed transaction (chain to Apple root, bundle ID,
   * app Apple ID, environment) and returns the decoded payload.
   * Throws on any failure.
   */
  async function verifyTransaction(jws) {
    const env = peekEnvironment(jws);
    return verifiers[env].verifyAndDecodeTransaction(jws);
  }

  /**
   * Asks the App Store Server API for the current state of a subscription.
   *
   * @returns {Promise<{status: number | null, transaction: object | null}>}
   */
  async function fetchSubscriptionStatus(originalTransactionId, env) {
    if (!SUPPORTED_ENVIRONMENTS.includes(env)) {
      throw new Error(`Unsupported environment: ${env}`);
    }
    const response = await apiClientFor(env).getAllSubscriptionStatuses(originalTransactionId);
    const lastTransactions = (response.data ?? []).flatMap((group) => group.lastTransactions ?? []);
    const match =
      lastTransactions.find((t) => t.originalTransactionId === originalTransactionId) ??
      lastTransactions[0];
    if (!match) return { status: null, transaction: null };

    const transaction = match.signedTransactionInfo
      ? await verifiers[env].verifyAndDecodeTransaction(match.signedTransactionInfo)
      : null;
    return { status: match.status ?? null, transaction };
  }

  return { verifyTransaction, fetchSubscriptionStatus };
}

/**
 * Whether a verification failure is final for this transaction.
 *
 * This decides whether the client finishes the transaction, which drops it
 * from StoreKit's queue for good. So the bar is certainty, and only one case
 * meets it: a transaction too malformed to even read. It could never verify.
 *
 * Every failure from Apple's verifier stays non-final, whatever status it
 * carries. The verifier runs online and calls Apple's OCSP responder, and the
 * library only reports a *network* failure there as retryable: an OCSP
 * `tryLater` answer, a connection reset while reading the response, or a stale
 * cached response all surface as VERIFICATION_FAILURE or FAILURE, the same
 * statuses a bad signature produces. Trusting those as final would, during any
 * hiccup at Apple, tell every client to finish real purchases ungranted. A
 * misconfigured or rotated root certificate would do the same to every
 * transaction. Holding costs a retry; finishing wrongly costs a paid purchase.
 *
 * @param {unknown} err
 * @returns {boolean}
 */
function isPermanentVerificationFailure(err) {
  return err instanceof MalformedTransactionError;
}

module.exports = {
  PREMIUM_PRODUCT_IDS,
  MalformedTransactionError,
  isPermanentVerificationFailure,
  peekEnvironment,
  isActiveTransaction,
  createAppStore,
};
