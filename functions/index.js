const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const crypto = require("crypto");
const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

const perplexityApiKey = defineSecret("PERPLEXITY_API_KEY");
const appStoreSharedSecret = defineSecret("APP_STORE_SHARED_SECRET");

/**
 * Fixed-window rate limiter backed by Firestore.
 *
 * @param {string} uid       - Firebase Auth UID
 * @param {string} action    - Logical action name (used as part of the doc key)
 * @param {number} limit     - Max requests allowed within the window
 * @param {number} windowSec - Window size in seconds
 */
async function checkRateLimit(uid, action, limit, windowSec) {
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
}

const APPLE_PRODUCTION_VERIFY_URL = "https://buy.itunes.apple.com/verifyReceipt";
const APPLE_SANDBOX_VERIFY_URL = "https://sandbox.itunes.apple.com/verifyReceipt";
const PREMIUM_PRODUCT_IDS = new Set([
  "premium_monthlysub",
  "premium_yearly",
]);

function parseMillis(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function getReceiptTransactions(body) {
  const latest = Array.isArray(body.latest_receipt_info) ? body.latest_receipt_info : [];
  const receiptInApp = Array.isArray(body.receipt?.in_app) ? body.receipt.in_app : [];
  return [...latest, ...receiptInApp];
}

function findLatestActiveSubscription(body) {
  const now = Date.now();
  const transactions = getReceiptTransactions(body);

  let latestActive = null;

  for (const transaction of transactions) {
    const productId = typeof transaction.product_id === "string"
      ? transaction.product_id
      : null;

    if (!productId || !PREMIUM_PRODUCT_IDS.has(productId)) {
      continue;
    }

    const expiresDateMs = parseMillis(transaction.expires_date_ms);
    if (expiresDateMs == null || expiresDateMs <= now) {
      continue;
    }

    if (!latestActive || expiresDateMs > latestActive.expiresDateMs) {
      latestActive = {
        productId,
        expiresDateMs,
        transactionId: transaction.transaction_id ?? null,
        originalTransactionId: transaction.original_transaction_id ?? null,
      };
    }
  }

  return latestActive;
}

async function postReceiptVerification(url, receiptData, sharedSecret) {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      "receipt-data": receiptData,
      password: sharedSecret,
      "exclude-old-transactions": true,
    }),
  });

  if (!response.ok) {
    const body = await response.text();
    console.error(`Apple receipt verification HTTP ${response.status}: ${body}`);
    throw new HttpsError("internal", "Apple receipt verification request failed.");
  }

  return response.json();
}

async function verifyReceiptWithApple(receiptData, sharedSecret, preferSandbox = false) {
  const firstUrl = preferSandbox
    ? APPLE_SANDBOX_VERIFY_URL
    : APPLE_PRODUCTION_VERIFY_URL;
  const firstResponse = await postReceiptVerification(firstUrl, receiptData, sharedSecret);

  if (firstResponse.status === 21007 && !preferSandbox) {
    return postReceiptVerification(APPLE_SANDBOX_VERIFY_URL, receiptData, sharedSecret);
  }

  if (firstResponse.status === 21008 && preferSandbox) {
    return postReceiptVerification(APPLE_PRODUCTION_VERIFY_URL, receiptData, sharedSecret);
  }

  return firstResponse;
}

// ---- StoreKit 2 JWS transaction verification ----

function isJWSTransaction(data) {
  const parts = data.split(".");
  return parts.length === 3 && parts.every((p) => /^[A-Za-z0-9_-]+$/.test(p));
}

async function verifyAndDecodeJWSTransaction(jws) {
  const [headerB64, payloadB64, signatureB64] = jws.split(".");

  let header, payload;
  try {
    header = JSON.parse(Buffer.from(headerB64, "base64url").toString("utf8"));
    payload = JSON.parse(Buffer.from(payloadB64, "base64url").toString("utf8"));
  } catch {
    throw new HttpsError("invalid-argument", "Malformed JWS transaction data.");
  }

  if (!Array.isArray(header.x5c) || header.x5c.length < 2) {
    throw new HttpsError("internal", "JWS transaction missing certificate chain.");
  }

  const certPems = header.x5c.map((b64) => {
    const lines = b64.match(/.{1,64}/g).join("\n");
    return `-----BEGIN CERTIFICATE-----\n${lines}\n-----END CERTIFICATE-----`;
  });

  let certs;
  try {
    certs = certPems.map((pem) => new crypto.X509Certificate(pem));
  } catch {
    throw new HttpsError("internal", "Failed to parse JWS certificates.");
  }

  // Verify each cert is signed by the next in the chain
  for (let i = 0; i < certs.length - 1; i++) {
    if (!certs[i].verify(certs[i + 1].publicKey)) {
      console.error(`[jws] Certificate chain broken at index ${i}`);
      throw new HttpsError("internal", "JWS certificate chain is invalid.");
    }
  }

  // Root cert must be from Apple. Check against known Apple Root CA CN values
  // rather than a loose substring match that any cert with "Apple" could pass.
  const rootCert = certs[certs.length - 1];
  const APPLE_ROOT_CA_CNS = ["CN=Apple Root CA", "CN=Apple Root CA - G3"];
  const isAppleRoot = APPLE_ROOT_CA_CNS.some((cn) => rootCert.subject.includes(cn));
  if (!isAppleRoot) {
    console.error(`[jws] Unexpected root cert subject: ${rootCert.subject}`);
    throw new HttpsError("internal", "JWS root certificate is not from Apple.");
  }

  // Verify the JWS signature (ES256 = ECDSA P-256 with SHA-256)
  const leafKeyDer = certs[0].publicKey.export({ type: "spki", format: "der" });
  let leafKey;
  try {
    leafKey = await globalThis.crypto.subtle.importKey(
      "spki",
      leafKeyDer,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"]
    );
  } catch {
    throw new HttpsError("internal", "Failed to import JWS signing key.");
  }

  const signedBytes = Buffer.from(`${headerB64}.${payloadB64}`);
  const sigBytes = Buffer.from(signatureB64, "base64url");
  const valid = await globalThis.crypto.subtle.verify(
    { name: "ECDSA", hash: { name: "SHA-256" } },
    leafKey,
    sigBytes,
    signedBytes
  );

  if (!valid) {
    throw new HttpsError("internal", "JWS transaction signature is invalid.");
  }

  return payload;
}

function findActiveSubscriptionFromJWSPayload(payload) {
  const productId = typeof payload.productId === "string" ? payload.productId : null;
  if (!productId || !PREMIUM_PRODUCT_IDS.has(productId)) return null;

  // expiresDate in StoreKit 2 JWS payload is milliseconds since epoch
  const expiresDateMs = typeof payload.expiresDate === "number" ? payload.expiresDate : null;
  if (expiresDateMs == null || expiresDateMs <= Date.now()) return null;

  return {
    productId,
    expiresDateMs,
    transactionId: payload.transactionId ?? null,
    originalTransactionId: payload.originalTransactionId ?? null,
  };
}

exports.validateAppStoreReceipt = onCall(
  {
    secrets: [appStoreSharedSecret],
    timeoutSeconds: 30,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }

    // 10 receipt validations per hour per user
    await checkRateLimit(request.auth.uid, "validateReceipt", 10, 3600);

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

    let activeSubscription;
    let environment = null;
    let bundleId = null;

    if (isJWSTransaction(receiptData)) {
      // StoreKit 2 path: JWS signed transaction
      console.log("[jws] Processing StoreKit 2 JWS transaction");
      const payload = await verifyAndDecodeJWSTransaction(receiptData);
      console.log(`[jws] bundleId=${payload.bundleId} productId=${payload.productId} environment=${payload.environment}`);
      bundleId = payload.bundleId ?? null;
      environment = payload.environment ?? null;
      activeSubscription = findActiveSubscriptionFromJWSPayload(payload);
    } else {
      // StoreKit 1 path: legacy base64 App Store receipt
      console.log("[receipt] Processing legacy App Store receipt");
      const sharedSecret = appStoreSharedSecret.value();
      if (!sharedSecret) {
        console.error("APP_STORE_SHARED_SECRET is not configured.");
        throw new HttpsError("internal", "Receipt verification is not configured.");
      }

      const verification = await verifyReceiptWithApple(receiptData, sharedSecret);

      if (verification.status === 21004) {
        console.error("App Store shared secret mismatch.");
        throw new HttpsError("internal", "Receipt verification is misconfigured.");
      }

      if (![0, 21006].includes(verification.status)) {
        console.error("App Store rejected receipt:", verification.status, verification.environment);
        throw new HttpsError("failed-precondition", "App Store could not validate this receipt.");
      }

      bundleId = verification.receipt?.bundle_id ?? null;
      environment = verification.environment ?? null;
      activeSubscription = findLatestActiveSubscription(verification);
    }

    if (!activeSubscription) {
      return {
        isValid: false,
        reason: "no-active-subscription",
        environment,
        bundleId,
      };
    }

    if (expectedProductId && activeSubscription.productId !== expectedProductId) {
      return {
        isValid: false,
        reason: "product-mismatch",
        productId: activeSubscription.productId,
        expiresDateMs: activeSubscription.expiresDateMs,
        environment,
        bundleId,
      };
    }

    return {
      isValid: true,
      productId: activeSubscription.productId,
      transactionId: activeSubscription.transactionId,
      originalTransactionId: activeSubscription.originalTransactionId,
      expiresDateMs: activeSubscription.expiresDateMs,
      environment,
      bundleId,
    };
  }
);

/**
 * Cloud Function to look up carb counts for one or more food items.
 *
 * Mirrors the prompt and parsing logic from the Flutter PerplexityService
 * so the API key stays server-side.
 *
 * Usage from Flutter:
 *   FirebaseFunctions.instance.httpsCallable('getMultipleCarbCounts')
 *     .call({'input': 'Big Mac and fries'});
 */
exports.getMultipleCarbCounts = onCall(
  {
    secrets: [perplexityApiKey],
    timeoutSeconds: 60,
    // Keep one instance warm to avoid cold starts
    minInstances: 1,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }

    // 20 carb lookups per minute per user
    await checkRateLimit(request.auth.uid, "getCarbCounts", 20, 60);

    const { input } = request.data;

    // Validate input
    if (!input || typeof input !== "string") {
      throw new HttpsError("invalid-argument", "input is required");
    }
    const trimmed = input.trim();
    if (trimmed.length < 2 || trimmed.length > 100) {
      throw new HttpsError(
        "invalid-argument",
        "input must be 2-100 characters"
      );
    }

    // Sanitize (mirrors InputValidation.sanitizeForApi + _normalizeUnicode)
    const sanitized = trimmed
      // Normalize Unicode confusables before allow-list enforcement
      .replace(/[\u2019\u2018\u02BC\u0060\u00B4]/g, "'") // apostrophe lookalikes
      .replace(/[\u2013\u2014\u2212]/g, "-")              // dash lookalikes
      .replace(/[\n\r\t]/g, " ")
      .replace(/\0/g, "")
      .replace(/\s+/g, " ")
      .trim();

    console.log(`Looking up: "${sanitized}"`);

    const maxAttempts = 3;

    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        const response = await fetch(
          "https://api.perplexity.ai/chat/completions",
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${perplexityApiKey.value()}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "sonar-pro",
              messages: [
                {
                  role: "system",
                  content:
                    "You are a precise nutrition assistant. The user will describe one or more food items. " +
                    "Interpret the input carefully: words may refer to a brand/store name, a style/variety, or the actual food product. " +
                    "For example, 'heb fajita tortilla' means a fajita-style tortilla sold by the brand HEB — NOT a fajita, NOT a taco. " +
                    "Parse the EXACT product the user is describing before looking up nutrition data. " +
                    "IMPORTANT: Return exactly ONE result per distinct food item the user mentions. " +
                    "If the user says 'tortilla', return only the single best match — do NOT return multiple varieties or sizes. " +
                    "Only return multiple items if the user explicitly lists multiple foods (e.g. 'burger and fries' = 2 items). " +
                    "Respond with ONLY a valid JSON array — no markdown, no code fences, no extra text. " +
                    'Each element must have "name" (string, the full product name including brand if given), "carbs" (number, grams of carbohydrates), ' +
                    '"protein" (number, grams of protein), "fat" (number, grams of total fat), "fiber" (number, grams of dietary fiber), ' +
                    '"calories" (number, kcal), and "details" (string, cite the specific source and serving size). ' +
                    "All numeric fields must be plain numbers — no units, no strings. " +
                    "Priority for data sources: " +
                    "1. Official manufacturer/restaurant/store-brand nutrition info (product packaging, website). " +
                    "2. USDA FoodData Central. " +
                    "3. Reliable nutrition databases (Nutritionix, CalorieKing, MyFitnessPal verified entries). " +
                    "If the exact brand product cannot be found, use the closest matching generic version and note this in details. " +
                    "Always include the serving size in details. " +
                    "You MUST always return a valid JSON array with at least one item — never refuse or return empty results. " +
                    'Example: [{"name":"HEB Fajita Tortilla","carbs":26,"protein":4,"fat":3,"fiber":1,"calories":150,"details":"Per HEB product nutrition label, one fajita-size flour tortilla (1 tortilla, 45g serving)."}]',
                },
                {
                  role: "user",
                  content: sanitized,
                },
              ],
              max_tokens: 1024,
              temperature: 0.1,
            }),
          }
        );

        if (response.status === 401) {
          console.error("Perplexity API auth failed (401)");
          throw new HttpsError("internal", "API authentication failed");
        }
        if (response.status === 429) {
          console.error("Perplexity API rate limited (429)");
          throw new HttpsError(
            "resource-exhausted",
            "Rate limit exceeded. Try again later."
          );
        }
        if (response.status >= 500) {
          console.error(`Perplexity API server error (${response.status}), attempt ${attempt}/${maxAttempts}`);
          if (attempt < maxAttempts) {
            await new Promise((r) => setTimeout(r, attempt * 1000));
            continue;
          }
          throw new HttpsError("internal", "Server error. Try again later.");
        }
        if (!response.ok) {
          const errorBody = await response.text();
          console.error(`Perplexity API error (${response.status}): ${errorBody}`);
          throw new HttpsError(
            "internal",
            `API request failed (${response.status})`
          );
        }

        const result = await response.json();

        if (!result.choices || !result.choices[0]) {
          console.error("Invalid API response structure:", JSON.stringify(result).substring(0, 500));
          if (attempt < maxAttempts) {
            await new Promise((r) => setTimeout(r, attempt * 1000));
            continue;
          }
          throw new HttpsError("internal", "Invalid API response");
        }

        let content = result.choices[0].message.content.trim();
        const citations = result.citations || [];

        console.log("Raw API response content:", content);

        // Strip markdown code fences if present
        content = content.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();

        // Parse JSON array from response
        const arrayMatch = content.match(/\[[\s\S]*\]/);
        if (!arrayMatch) {
          console.error(`Could not find JSON array (attempt ${attempt}/${maxAttempts}):`, content);
          if (attempt < maxAttempts) {
            await new Promise((r) => setTimeout(r, attempt * 1000));
            continue;
          }
          throw new HttpsError("internal", "Could not parse food items");
        }

        let items;
        try {
          items = JSON.parse(arrayMatch[0]);
        } catch (parseErr) {
          console.error(`JSON parse error (attempt ${attempt}/${maxAttempts}):`, parseErr.message, "Content:", arrayMatch[0]);
          if (attempt < maxAttempts) {
            await new Promise((r) => setTimeout(r, attempt * 1000));
            continue;
          }
          throw new HttpsError("internal", "Could not parse food items");
        }

        if (!Array.isArray(items) || items.length === 0) {
          console.error(`Empty result array (attempt ${attempt}/${maxAttempts}):`, JSON.stringify(items));
          if (attempt < maxAttempts) {
            await new Promise((r) => setTimeout(r, attempt * 1000));
            continue;
          }
          throw new HttpsError("internal", "No food items found in response");
        }

        const mapped = items.map((item) => {
          const parseNum = (val) => {
            if (typeof val === "string") {
              const m = val.match(/(\d+\.?\d*)/);
              val = m ? parseFloat(m[1]) : null;
            }
            return typeof val === "number" && !isNaN(val) ? val : null;
          };

          const carbs = parseNum(item.carbs) ?? 0;

          return {
            name: String(item.name || "Unknown"),
            carbs: carbs,
            protein: parseNum(item.protein),
            fat: parseNum(item.fat),
            fiber: parseNum(item.fiber),
            calories: parseNum(item.calories),
            details: item.details ? String(item.details) : null,
          };
        });

        console.log(`Returning ${mapped.length} item(s):`, JSON.stringify(mapped));

        return {
          items: mapped,
          citations: citations,
        };
      } catch (error) {
        if (error instanceof HttpsError) throw error;

        console.error(`Attempt ${attempt}/${maxAttempts} failed:`, error.message);

        // Retry on transient errors
        if (attempt < maxAttempts) {
          await new Promise((r) => setTimeout(r, attempt * 1000));
          continue;
        }

        throw new HttpsError("internal", error.message);
      }
    }
  }
);
