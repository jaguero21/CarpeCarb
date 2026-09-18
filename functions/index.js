const fs = require("fs");
const path = require("path");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");

const { createRateLimiter } = require("./src/rateLimit");
const { lookupFoods } = require("./src/perplexity");
const { createQuotaStore } = require("./src/quota");
const { createAppStore } = require("./src/appStore");
const { createEntitlementStore } = require("./src/entitlements");
const { createHandlers } = require("./src/handlers");

admin.initializeApp();
const db = admin.firestore();

const perplexityApiKey = defineSecret("PERPLEXITY_API_KEY");
const appStoreIapKey = defineSecret("APP_STORE_IAP_KEY");
const appStoreKeyId = defineSecret("APP_STORE_KEY_ID");
const appStoreIssuerId = defineSecret("APP_STORE_ISSUER_ID");
const appAppleId = defineSecret("APP_APPLE_ID");
const APP_STORE_SECRETS = [appStoreIapKey, appStoreKeyId, appStoreIssuerId, appAppleId];

const BUNDLE_ID = "com.jamesaguero.mycarbtracker";
// StoreKit 2 transactions chain to Apple Root CA - G3.
// SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
const APPLE_ROOT_CERTS = [fs.readFileSync(path.join(__dirname, "certs", "AppleRootCA-G3.cer"))];

/** Reads App Store secrets at request time; throws `internal` if any is unset. */
function readAppStoreConfig() {
  const config = {
    signingKey: appStoreIapKey.value(),
    keyId: appStoreKeyId.value(),
    issuerId: appStoreIssuerId.value(),
    appAppleId: Number(appAppleId.value()),
  };
  const missing = [];
  if (!config.signingKey) missing.push("APP_STORE_IAP_KEY");
  if (!config.keyId) missing.push("APP_STORE_KEY_ID");
  if (!config.issuerId) missing.push("APP_STORE_ISSUER_ID");
  if (!Number.isInteger(config.appAppleId) || config.appAppleId <= 0) missing.push("APP_APPLE_ID");
  if (missing.length > 0) {
    console.error(`[config] Missing or invalid secrets: ${missing.join(", ")}`);
    throw new HttpsError("internal", "Server is not configured.");
  }
  return config;
}

let handlers = null;

/** Builds the handlers once per instance (secrets are only readable at runtime). */
function getHandlers() {
  if (handlers) return handlers;

  const appStore = createAppStore({
    ...readAppStoreConfig(),
    rootCerts: APPLE_ROOT_CERTS,
    bundleId: BUNDLE_ID,
  });
  const now = () => Date.now();
  const quota = createQuotaStore({ db, now });
  const entitlements = createEntitlementStore({ db, appStore, now });

  handlers = createHandlers({
    checkRateLimit: createRateLimiter(db),
    getPremiumStatus: entitlements.getPremiumStatus,
    reserveLookup: quota.reserveLookup,
    releaseLookup: quota.releaseLookup,
    lookupFoods: (sanitized) => lookupFoods(sanitized, perplexityApiKey.value()),
    verifyTransaction: appStore.verifyTransaction,
    recordTransaction: entitlements.recordTransaction,
    now,
  });
  return handlers;
}

exports.validateAppStoreReceipt = onCall(
  {
    secrets: APP_STORE_SECRETS,
    timeoutSeconds: 30,
  },
  (request) => getHandlers().validateAppStoreReceipt(request)
);

/**
 * Looks up carb counts for one or more food items. Free users get
 * FREE_DAILY_LOOKUP_LIMIT lookups per local day; premium is derived from
 * Apple-verified transactions (see src/entitlements.js).
 *
 * Called over HTTPS from Flutter (PerplexityFirebaseService) and Siri
 * (PerplexityClient.swift) with {"data": {"input", "tzOffsetMinutes"}}.
 */
exports.getMultipleCarbCounts = onCall(
  {
    secrets: [perplexityApiKey, ...APP_STORE_SECRETS],
    timeoutSeconds: 60,
    // Keep one instance warm to avoid cold starts
    minInstances: 1,
  },
  (request) => getHandlers().getMultipleCarbCounts(request)
);
