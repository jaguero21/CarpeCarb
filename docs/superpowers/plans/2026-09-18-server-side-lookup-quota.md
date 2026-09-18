# Server-side Lookup Quota Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `getMultipleCarbCounts` Cloud Function the authority for the free tier (4 AI lookups per local day), with premium derived only from Apple-verified StoreKit 2 transactions.

**Architecture:** `functions/index.js` becomes wiring only; logic moves into small CommonJS modules under `functions/src/` (rate limit, Perplexity call, quota, App Store verification, entitlements, handlers), each with pure functions plus a thin Firestore-backed store, tested with `node:test` and an in-memory Firestore fake. The Flutter app and the Siri client send their UTC offset, read a `quota` object from each lookup response, and map a `daily-quota` error to the existing limit dialog / a spoken message.

**Tech Stack:** Node 22 Cloud Functions (firebase-functions 6.6, firebase-admin 12.7), `@apple/app-store-server-library` 3.1, `node:test`; Flutter 3.41 / Dart 3.11 with `flutter_test`; Swift 6.4 toolchain with Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-18-server-side-lookup-quota-design.md`

## Global Constraints

- Free limit: exactly 4 lookups per local calendar day, app and Siri combined (`FREE_DAILY_LOOKUP_LIMIT = 4` in `functions/src/quota.js`).
- Premium product IDs: `premium_monthlysub`, `premium_yearly`. Bundle ID: `com.jamesaguero.mycarbtracker`.
- Accepted StoreKit environments: `Production` and `Sandbox` only.
- `tzOffsetMinutes`: integer, clamped to [-840, 840]; missing/invalid → 0 (UTC).
- Daily-quota error: `HttpsError("resource-exhausted", …, { reason: "daily-quota", used, limit })` (HTTP 429).
- JWS verification failure → `failed-precondition` (HTTP 400), never `permission-denied` (the app maps 403 to "Receipt verification blocked", `lib/services/purchase_service.dart:90`).
- Entitlement refresh: at most every 6 h after a successful check, 15 min after a failed attempt; fail open for 72 h past stored expiry.
- Quota/premium check failure fails closed (no Perplexity call).
- No new Node test dependencies (`node:test` only). No force unwraps / `try!` in shipped Swift.
- Commits carry NO `Co-Authored-By` (or other) trailer — James, 2026-09-18. Drop the `-m "Co-Authored-By: …"` part of any commit command in this plan.
- Work on branch `feature/server-side-lookup-quota` (already created; the spec is committed there).

## File Map

**Cloud Functions (`functions/`)**
| File | Status | Responsibility |
|---|---|---|
| `package.json` | modify | add `test` script and `@apple/app-store-server-library` |
| `index.js` | rewrite (Task 5) | defines secrets, builds handlers lazily, exports the two callables |
| `src/rateLimit.js` | create | existing per-minute limiter, as a factory over `db` |
| `src/perplexity.js` | create | `sanitizeFoodInput`, `lookupFoods` (moved from `index.js`) |
| `src/quota.js` | create | `parseTzOffset`, `dayKey`, `applyReservation`, `applyRelease`, `createQuotaStore` |
| `src/appStore.js` | create | `PREMIUM_PRODUCT_IDS`, `peekEnvironment`, `isActiveTransaction`, `createAppStore` |
| `src/entitlements.js` | create | `evaluateEntitlement`, `failOpenPremium`, `entitlementUpdateFromStatus`, `createEntitlementStore` |
| `src/handlers.js` | create | `createHandlers(deps)` → `{ getMultipleCarbCounts, validateAppStoreReceipt }` |
| `certs/AppleRootCA-G3.cer` | create | Apple root the JWS chain must end in |
| `scripts/make-forged-jws.js` | create | generates the #3 regression fixture |
| `test/helpers/fakeFirestore.js` | create | in-memory Firestore stand-in |
| `test/fixtures/forged-jws.txt` | create | JWS signed by a self-made "Apple Root CA - G3" chain |
| `test/*.test.js` | create | one test file per module |

**Repo root:** `firestore.rules` (create, deny-all), `firebase.json` (modify: rules + deploy ignores).

**Flutter (`lib/`, `test/`, `integration_test/`)**
| File | Status | Responsibility |
|---|---|---|
| `lib/models/server_quota.dart` | create | `ServerQuota` + `fromJson` |
| `lib/services/lookup_api.dart` | create | `LookupResult`, `parseLookupResponse`, `parseCallableError` (pure) |
| `lib/utils/user_facing_exception.dart` | modify | add `DailyLimitReachedException` |
| `lib/config/storage_keys.dart` | modify | add `dailyLookupLimit`, fix stale "15/day" comment |
| `lib/services/premium_service.dart` | rewrite | `applyServerQuota`, date-aware count, injectable clock; drop `incrementLookupCount` |
| `lib/services/perplexity_firebase_service.dart` | rewrite | send `tzOffsetMinutes`, return `LookupResult`, use the parsers |
| `lib/main.dart` | modify | `_addFood` applies server quota / shows dialog on `DailyLimitReachedException` |
| `lib/screens/settings_page.dart` | modify | limit comes from `PremiumService.dailyLookupLimit` |
| `test/lookup_api_test.dart`, `test/premium_service_test.dart` | create | unit tests |
| `test/perplexity_service_test.dart` | delete | only asserted string constants |
| `integration_test/app_test.dart` | modify | replace the `incrementLookupCount` test |

**Siri (`ios/CarbShared/`)**: `Package.swift` (add `.macOS(.v13)`), `Sources/CarbShared/PerplexityClient.swift` (rewrite), `Tests/CarbSharedTests/PerplexityClientTests.swift` (create).

---

### Task 1: Functions test harness, rate limiter and Perplexity modules

Moves existing code into modules with tests. `index.js` keeps its own copies until Task 5 rewires it, so the deployed behavior does not change in this task.

**Files:**
- Modify: `functions/package.json`
- Create: `functions/src/rateLimit.js`, `functions/src/perplexity.js`, `functions/test/helpers/fakeFirestore.js`
- Test: `functions/test/rateLimit.test.js`, `functions/test/perplexity.test.js`

**Interfaces:**
- Produces: `createRateLimiter(db) → checkRateLimit(uid, action, limit, windowSec): Promise<void>`; `sanitizeFoodInput(input: unknown): string` (throws `HttpsError` `invalid-argument`); `lookupFoods(sanitized: string, apiKey: string): Promise<{items: object[], citations: string[]}>`; `createFakeFirestore(initialDocs?: Record<string, object>)` → `{ docs: Map<path, object>, state: {failTransactions, failReads}, collection(name).doc(id).get()/set(data, {merge}), runTransaction(fn) }` where paths are `"collection/id"`.

- [ ] **Step 1: Commit the pending product-ID fix on its own**

The working tree has an uncommitted change to `functions/index.js` lines 58-61 renaming the product IDs to `premium_monthlysub` / `premium_yearly` (matches `lib/services/purchase_service.dart:12-13`). Commit it first so it is not mixed into the refactor. Leave `pubspec.yaml` (version bump) uncommitted.

```bash
cd /Volumes/APFS2/Developer/CarpeCarb
git diff functions/index.js   # expect only the two PREMIUM_PRODUCT_IDS lines
git add functions/index.js
git commit -m "fix: accept renamed premium product IDs in receipt validation" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 2: Add the test script**

Edit `functions/package.json` so it reads exactly:

```json
{
  "name": "carpecarb-functions",
  "description": "Firebase Cloud Functions for CarpeCarb API proxy",
  "version": "1.0.0",
  "engines": {
    "node": "22"
  },
  "main": "index.js",
  "scripts": {
    "test": "node --test test/*.test.js"
  },
  "dependencies": {
    "firebase-admin": "^12.0.0",
    "firebase-functions": "^6.0.0"
  },
  "devDependencies": {
    "firebase-functions-test": "^3.1.0"
  },
  "private": true
}
```

- [ ] **Step 3: Create the in-memory Firestore fake**

Create `functions/test/helpers/fakeFirestore.js`:

```js
// Minimal in-memory stand-in for the parts of the Firestore Admin API the
// functions use: collection().doc().get()/set(), and runTransaction with
// tx.get/tx.set/tx.update. Transactions run sequentially (no contention).
function createFakeFirestore(initialDocs = {}) {
  const docs = new Map(Object.entries(initialDocs));
  const state = { failTransactions: false, failReads: false };

  function write(path, data, options = {}) {
    const base = options.merge ? docs.get(path) ?? {} : {};
    docs.set(path, { ...base, ...data });
  }

  function ref(path) {
    return {
      path,
      async get() {
        if (state.failReads) throw new Error("fake read failure");
        return {
          exists: docs.has(path),
          data: () => (docs.has(path) ? { ...docs.get(path) } : undefined),
        };
      },
      async set(data, options) {
        write(path, data, options);
      },
    };
  }

  return {
    docs,
    state,
    collection: (name) => ({ doc: (id) => ref(`${name}/${id}`) }),
    async runTransaction(fn) {
      if (state.failTransactions) throw new Error("fake transaction failure");
      return fn({
        get: (r) => r.get(),
        set: (r, data, options) => write(r.path, data, options),
        update: (r, data) => write(r.path, data, { merge: true }),
      });
    },
  };
}

module.exports = { createFakeFirestore };
```

- [ ] **Step 4: Write the failing tests**

Create `functions/test/rateLimit.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const { HttpsError } = require("firebase-functions/v2/https");
const { createRateLimiter } = require("../src/rateLimit");
const { createFakeFirestore } = require("./helpers/fakeFirestore");

test("allows up to the limit, then throws resource-exhausted", async () => {
  const db = createFakeFirestore();
  const checkRateLimit = createRateLimiter(db);

  await checkRateLimit("u1", "act", 2, 60);
  await checkRateLimit("u1", "act", 2, 60);
  await assert.rejects(checkRateLimit("u1", "act", 2, 60), (err) => {
    assert.ok(err instanceof HttpsError);
    assert.equal(err.code, "resource-exhausted");
    return true;
  });
});

test("limits are tracked per uid", async () => {
  const db = createFakeFirestore();
  const checkRateLimit = createRateLimiter(db);

  await checkRateLimit("u1", "act", 1, 60);
  await assert.doesNotReject(checkRateLimit("u2", "act", 1, 60));
});
```

Create `functions/test/perplexity.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const { sanitizeFoodInput } = require("../src/perplexity");

const isInvalidArgument = (err) => err.code === "invalid-argument";

test("sanitizeFoodInput trims and collapses whitespace", () => {
  assert.equal(sanitizeFoodInput("  big   mac\tand fries \n"), "big mac and fries");
});

test("sanitizeFoodInput normalizes apostrophe and dash lookalikes", () => {
  assert.equal(sanitizeFoodInput("Wendy\u2019s chili \u2014 large"), "Wendy's chili - large");
});

test("sanitizeFoodInput rejects non-strings, too-short and too-long input", () => {
  assert.throws(() => sanitizeFoodInput(undefined), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput(42), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput(" a "), isInvalidArgument);
  assert.throws(() => sanitizeFoodInput("x".repeat(101)), isInvalidArgument);
});
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `cd functions && npm test`
Expected: FAIL with `Cannot find module '../src/rateLimit'` and `Cannot find module '../src/perplexity'`.

- [ ] **Step 6: Create `functions/src/rateLimit.js`**

Same logic as `checkRateLimit` in `functions/index.js:20-54`, wrapped in a factory so `db` is injected:

```js
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
```

- [ ] **Step 7: Create `functions/src/perplexity.js`**

`sanitizeFoodInput` is `functions/index.js:366-388` as a function; `lookupFoods` is the retry loop from `functions/index.js:392-562`, de-indented, with `perplexityApiKey.value()` replaced by the `apiKey` parameter. No behavior change.

```js
const { HttpsError } = require("firebase-functions/v2/https");

/**
 * Validates and sanitizes the raw `input` from a lookup request.
 * Mirrors InputValidation.sanitizeForApi + _normalizeUnicode in the Flutter app.
 *
 * @param {unknown} input
 * @returns {string} sanitized input
 */
function sanitizeFoodInput(input) {
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

  return trimmed
    // Normalize Unicode confusables before allow-list enforcement
    .replace(/[\u2019\u2018\u02BC\u0060\u00B4]/g, "'") // apostrophe lookalikes
    .replace(/[\u2013\u2014\u2212]/g, "-")              // dash lookalikes
    .replace(/[\n\r\t]/g, " ")
    .replace(/\0/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Looks up carb counts for a sanitized food description via Perplexity.
 *
 * @param {string} sanitized - output of sanitizeFoodInput
 * @param {string} apiKey - Perplexity API key
 * @returns {Promise<{items: object[], citations: string[]}>}
 */
async function lookupFoods(sanitized, apiKey) {
  console.log(`Looking up: "${sanitized}"`);

  const maxAttempts = 3;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const response = await fetch(
        "https://api.perplexity.ai/chat/completions",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${apiKey}`,
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

module.exports = { sanitizeFoodInput, lookupFoods };
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd functions && npm test`
Expected: `ℹ pass 5`, `ℹ fail 0`.

- [ ] **Step 9: Commit**

```bash
git add functions/package.json functions/src/rateLimit.js functions/src/perplexity.js functions/test
git commit -m "refactor(functions): extract rate limiter and Perplexity lookup into modules" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Daily quota module

**Files:**
- Create: `functions/src/quota.js`
- Test: `functions/test/quota.test.js`

**Interfaces:**
- Consumes: `createFakeFirestore` (Task 1).
- Produces: `FREE_DAILY_LOOKUP_LIMIT = 4`; `parseTzOffset(value: unknown): number`; `dayKey(nowMs: number, tzOffsetMin: number): string` (`YYYY-MM-DD`); `applyReservation(doc, key, limit) → {allowed: boolean, used: number, next: {dayKey, count} | null}`; `applyRelease(doc, key) → {dayKey, count} | null`; `createQuotaStore({db, now, limit?})` → `{ reserveLookup(uid, tzOffsetMin): Promise<{dayKey, used, limit}>, releaseLookup(uid, dayKey): Promise<void> }`. `reserveLookup` throws `HttpsError("resource-exhausted", "You've used today's 4 free lookups.", {reason: "daily-quota", used, limit})`. Firestore doc: `lookupQuota/{uid}` = `{dayKey, count, expiresAt: Date}`.

- [ ] **Step 1: Write the failing test**

Create `functions/test/quota.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  FREE_DAILY_LOOKUP_LIMIT,
  parseTzOffset,
  dayKey,
  applyReservation,
  applyRelease,
  createQuotaStore,
} = require("../src/quota");
const { createFakeFirestore } = require("./helpers/fakeFirestore");

test("free limit is 4", () => {
  assert.equal(FREE_DAILY_LOOKUP_LIMIT, 4);
});

test("parseTzOffset accepts integers and clamps to ±14h", () => {
  assert.equal(parseTzOffset(-300), -300);
  assert.equal(parseTzOffset(2000), 840);
  assert.equal(parseTzOffset(-2000), -840);
});

test("parseTzOffset turns missing or non-integer values into UTC", () => {
  assert.equal(parseTzOffset(undefined), 0);
  assert.equal(parseTzOffset("-300"), 0);
  assert.equal(parseTzOffset(-300.5), 0);
  assert.equal(parseTzOffset(NaN), 0);
});

test("dayKey uses the caller's local calendar day", () => {
  const nowMs = Date.parse("2026-09-18T03:30:00Z"); // 22:30 on the 17th in UTC-5
  assert.equal(dayKey(nowMs, 0), "2026-09-18");
  assert.equal(dayKey(nowMs, -300), "2026-09-17");
  assert.equal(dayKey(nowMs, 330), "2026-09-18"); // UTC+5:30
});

test("dayKey rolls over exactly at local midnight", () => {
  const offset = -240; // UTC-4 (e.g. EDT)
  assert.equal(dayKey(Date.parse("2026-09-18T03:59:59Z"), offset), "2026-09-17");
  assert.equal(dayKey(Date.parse("2026-09-18T04:00:00Z"), offset), "2026-09-18");
});

test("dayKey follows a DST change through the reported offset", () => {
  const instant = Date.parse("2026-11-01T04:30:00Z");
  assert.equal(dayKey(instant, -240), "2026-11-01"); // EDT: 00:30
  assert.equal(dayKey(instant, -300), "2026-10-31"); // EST: 23:30
});

test("applyReservation starts a new day at one", () => {
  assert.deepEqual(applyReservation(null, "2026-09-18", 4), {
    allowed: true, used: 1, next: { dayKey: "2026-09-18", count: 1 },
  });
  assert.deepEqual(applyReservation({ dayKey: "2026-09-17", count: 4 }, "2026-09-18", 4), {
    allowed: true, used: 1, next: { dayKey: "2026-09-18", count: 1 },
  });
});

test("applyReservation counts up to the limit, then refuses", () => {
  assert.deepEqual(applyReservation({ dayKey: "2026-09-18", count: 3 }, "2026-09-18", 4), {
    allowed: true, used: 4, next: { dayKey: "2026-09-18", count: 4 },
  });
  assert.deepEqual(applyReservation({ dayKey: "2026-09-18", count: 4 }, "2026-09-18", 4), {
    allowed: false, used: 4, next: null,
  });
});

test("applyRelease only decrements the matching day", () => {
  assert.deepEqual(applyRelease({ dayKey: "2026-09-18", count: 2 }, "2026-09-18"), { dayKey: "2026-09-18", count: 1 });
  assert.equal(applyRelease({ dayKey: "2026-09-19", count: 2 }, "2026-09-18"), null);
  assert.equal(applyRelease({ dayKey: "2026-09-18", count: 0 }, "2026-09-18"), null);
  assert.equal(applyRelease(null, "2026-09-18"), null);
});

test("reserveLookup allows 4 per day and throws daily-quota on the 5th", async () => {
  const db = createFakeFirestore();
  const store = createQuotaStore({ db, now: () => Date.parse("2026-09-18T15:00:00Z") });

  for (let i = 1; i <= 4; i++) {
    const r = await store.reserveLookup("u1", -300);
    assert.deepEqual(r, { dayKey: "2026-09-18", used: i, limit: 4 });
  }
  await assert.rejects(store.reserveLookup("u1", -300), (err) => {
    assert.equal(err.code, "resource-exhausted");
    assert.deepEqual(err.details, { reason: "daily-quota", used: 4, limit: 4 });
    return true;
  });
  assert.ok(db.docs.get("lookupQuota/u1").expiresAt instanceof Date);
});

test("releaseLookup gives a reserved lookup back", async () => {
  const db = createFakeFirestore();
  const store = createQuotaStore({ db, now: () => Date.parse("2026-09-18T15:00:00Z") });

  const r = await store.reserveLookup("u1", 0);
  await store.releaseLookup("u1", r.dayKey);
  assert.equal(db.docs.get("lookupQuota/u1").count, 0);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd functions && npm test`
Expected: FAIL with `Cannot find module '../src/quota'`.

- [ ] **Step 3: Implement `functions/src/quota.js`**

```js
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd functions && npm test`
Expected: `ℹ pass 16`, `ℹ fail 0`.

- [ ] **Step 5: Commit**

```bash
git add functions/src/quota.js functions/test/quota.test.js
git commit -m "feat(functions): add per-user daily lookup quota" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: App Store verification with Apple's library (fixes review #3)

**Files:**
- Modify: `functions/package.json`, `functions/package-lock.json` (via npm)
- Create: `functions/certs/AppleRootCA-G3.cer`, `functions/scripts/make-forged-jws.js`, `functions/test/fixtures/forged-jws.txt`, `functions/src/appStore.js`
- Test: `functions/test/appStore.test.js`

**Interfaces:**
- Produces: `PREMIUM_PRODUCT_IDS: Set<string>`; `peekEnvironment(jws: string): "Production" | "Sandbox"` (throws `Error` "Malformed JWS…" / "Unsupported environment…"); `isActiveTransaction(payload, nowMs): boolean`; `createAppStore({rootCerts: Buffer[], bundleId, appAppleId: number, signingKey, keyId, issuerId})` → `{ verifyTransaction(jws): Promise<JWSTransactionDecodedPayload>, fetchSubscriptionStatus(originalTransactionId, env): Promise<{status: number | null, transaction: object | null}> }`. Status numbers are Apple's `Status` enum: ACTIVE 1, EXPIRED 2, BILLING_RETRY 3, BILLING_GRACE_PERIOD 4, REVOKED 5.

- [ ] **Step 1: Install Apple's library**

```bash
cd functions && npm install @apple/app-store-server-library@^3.1.0
```

Expected: `package.json` dependencies now include `"@apple/app-store-server-library": "^3.1.0"`.

- [ ] **Step 2: Download and check Apple Root CA - G3**

```bash
mkdir -p functions/certs
curl -sSf -o functions/certs/AppleRootCA-G3.cer https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
openssl x509 -inform der -in functions/certs/AppleRootCA-G3.cer -noout -fingerprint -sha256
```

Expected output exactly:
`sha256 Fingerprint=63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79`
Stop if it differs.

- [ ] **Step 3: Create the forged-JWS fixture generator and fixture**

Create `functions/scripts/make-forged-jws.js`:

```js
// Generates a StoreKit-2-shaped JWS signed by a self-made certificate chain
// whose root claims the subject "CN=Apple Root CA - G3". Used as a regression
// fixture: a correct verifier must reject it (review finding #3).
// Usage: node scripts/make-forged-jws.js > test/fixtures/forged-jws.txt
"use strict";
const { execFileSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "forged-jws-"));
const ossl = (...args) => execFileSync("openssl", args, { cwd: dir, stdio: "pipe" });

for (const name of ["root", "int", "leaf"]) {
  ossl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", `${name}.key`);
}
ossl("req", "-new", "-x509", "-key", "root.key", "-days", "3650", "-out", "root.pem",
  "-subj", "/CN=Apple Root CA - G3/OU=Apple Certification Authority/O=Apple Inc./C=US");
ossl("req", "-new", "-key", "int.key", "-out", "int.csr",
  "-subj", "/CN=Apple Worldwide Developer Relations Certification Authority/OU=G6/O=Apple Inc./C=US");
fs.writeFileSync(path.join(dir, "ca.ext"), "basicConstraints=critical,CA:true\n");
ossl("x509", "-req", "-in", "int.csr", "-CA", "root.pem", "-CAkey", "root.key",
  "-CAcreateserial", "-days", "3650", "-extfile", "ca.ext", "-out", "int.pem");
ossl("req", "-new", "-key", "leaf.key", "-out", "leaf.csr",
  "-subj", "/CN=Prod ECC Mac App Store and iTunes Store Receipt Signing/OU=Apple Worldwide Developer Relations/O=Apple Inc./C=US");
ossl("x509", "-req", "-in", "leaf.csr", "-CA", "int.pem", "-CAkey", "int.key",
  "-CAcreateserial", "-days", "3650", "-out", "leaf.pem");

const der = (name) => new crypto.X509Certificate(fs.readFileSync(path.join(dir, `${name}.pem`))).raw.toString("base64");
const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");

const now = Date.now();
const header = { alg: "ES256", x5c: [der("leaf"), der("int"), der("root")] };
const payload = {
  transactionId: "2000000999999999",
  originalTransactionId: "2000000999999999",
  bundleId: "com.jamesaguero.mycarbtracker",
  productId: "premium_yearly",
  purchaseDate: now,
  expiresDate: now + 10 * 365 * 24 * 3600 * 1000,
  type: "Auto-Renewable Subscription",
  inAppOwnershipType: "PURCHASED",
  signedDate: now,
  environment: "Production",
};
const signingInput = `${b64url(header)}.${b64url(payload)}`;
const signature = crypto.sign("sha256", Buffer.from(signingInput), {
  key: fs.readFileSync(path.join(dir, "leaf.key")),
  dsaEncoding: "ieee-p1363",
}).toString("base64url");
fs.rmSync(dir, { recursive: true, force: true });
process.stdout.write(`${signingInput}.${signature}\n`);
```

Generate the fixture (needs `openssl` on PATH):

```bash
cd functions && mkdir -p test/fixtures && node scripts/make-forged-jws.js > test/fixtures/forged-jws.txt && wc -c test/fixtures/forged-jws.txt
```

Expected: roughly 3,600 bytes, one line.

- [ ] **Step 4: Write the failing test**

Create `functions/test/appStore.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { VerificationException } = require("@apple/app-store-server-library");
const {
  PREMIUM_PRODUCT_IDS,
  peekEnvironment,
  isActiveTransaction,
  createAppStore,
} = require("../src/appStore");

const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
const fakeJws = (payload) => `${b64url({ alg: "ES256" })}.${b64url(payload)}.sig`;

const appStore = createAppStore({
  rootCerts: [fs.readFileSync(path.join(__dirname, "..", "certs", "AppleRootCA-G3.cer"))],
  bundleId: "com.jamesaguero.mycarbtracker",
  appAppleId: 1234567890,
  signingKey: "unused-in-these-tests",
  keyId: "unused",
  issuerId: "unused",
});

test("premium product IDs match the app", () => {
  assert.deepEqual([...PREMIUM_PRODUCT_IDS].sort(), ["premium_monthlysub", "premium_yearly"]);
});

test("peekEnvironment reads Production and Sandbox", () => {
  assert.equal(peekEnvironment(fakeJws({ environment: "Production" })), "Production");
  assert.equal(peekEnvironment(fakeJws({ environment: "Sandbox" })), "Sandbox");
});

test("peekEnvironment rejects malformed input and other environments", () => {
  assert.throws(() => peekEnvironment("not-a-jws"), /Malformed JWS/);
  assert.throws(() => peekEnvironment("a.%%%.c"), /Malformed JWS payload/);
  assert.throws(() => peekEnvironment(fakeJws({ environment: "Xcode" })), /Unsupported environment/);
  assert.throws(() => peekEnvironment(fakeJws({})), /Unsupported environment/);
});

test("isActiveTransaction requires a premium product, future expiry, and no revocation", () => {
  const now = Date.parse("2026-09-18T12:00:00Z");
  const active = { productId: "premium_yearly", expiresDate: now + 1000 };
  assert.equal(isActiveTransaction(active, now), true);
  assert.equal(isActiveTransaction({ ...active, productId: "other_app_premium" }, now), false);
  assert.equal(isActiveTransaction({ ...active, expiresDate: now }, now), false);
  assert.equal(isActiveTransaction({ ...active, expiresDate: undefined }, now), false);
  assert.equal(isActiveTransaction({ ...active, revocationDate: now - 1 }, now), false);
});

// Regression for review finding #3: the old verifier trusted any chain whose
// root subject contained "CN=Apple Root CA". This fixture is signed by a
// self-made chain with exactly that subject (see scripts/make-forged-jws.js).
test("verifyTransaction rejects a JWS signed by a forged 'Apple Root CA - G3' chain", async () => {
  const forged = fs.readFileSync(path.join(__dirname, "fixtures", "forged-jws.txt"), "utf8").trim();
  await assert.rejects(appStore.verifyTransaction(forged), VerificationException);
});

test("verifyTransaction rejects garbage before touching the verifier", async () => {
  await assert.rejects(appStore.verifyTransaction("garbage"), /Malformed JWS/);
});

test("fetchSubscriptionStatus rejects unsupported environments", async () => {
  await assert.rejects(appStore.fetchSubscriptionStatus("1000", "Xcode"), /Unsupported environment/);
});
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `cd functions && npm test`
Expected: FAIL with `Cannot find module '../src/appStore'`.

- [ ] **Step 6: Implement `functions/src/appStore.js`**

```js
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
function peekEnvironment(jws) {
  const parts = typeof jws === "string" ? jws.split(".") : [];
  if (parts.length !== 3) throw new Error("Malformed JWS.");
  let payload;
  try {
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    throw new Error("Malformed JWS payload.");
  }
  if (!SUPPORTED_ENVIRONMENTS.includes(payload.environment)) {
    throw new Error(`Unsupported environment: ${payload.environment}`);
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

module.exports = {
  PREMIUM_PRODUCT_IDS,
  peekEnvironment,
  isActiveTransaction,
  createAppStore,
};
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd functions && npm test`
Expected: `ℹ pass 23`, `ℹ fail 0`. The forged-chain test must pass: this is the fixture the current `functions/index.js` verifier accepts.

- [ ] **Step 8: Commit**

```bash
git add functions/package.json functions/package-lock.json functions/certs functions/scripts functions/test/fixtures functions/src/appStore.js functions/test/appStore.test.js
git commit -m "feat(functions): verify StoreKit 2 transactions with Apple's server library" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Entitlements module

**Files:**
- Create: `functions/src/entitlements.js`
- Test: `functions/test/entitlements.test.js`

**Interfaces:**
- Consumes: `createFakeFirestore` (Task 1); an `appStore` with `fetchSubscriptionStatus(originalTransactionId, env)` (Task 3 shape).
- Produces: `evaluateEntitlement(doc, nowMs) → {premium, needsRefresh}`; `failOpenPremium(doc, nowMs): boolean`; `entitlementUpdateFromStatus({status, transaction}, nowMs) → object` (fields to merge); `createEntitlementStore({db, appStore, now})` → `{ getPremiumStatus(uid): Promise<boolean>, recordTransaction(uid, payload): Promise<void> }`. Firestore doc `entitlements/{uid}` = `{productId, originalTransactionId, expiresDateMs, environment, revoked, lastCheckedMs, lastRefreshAttemptMs}`.

- [ ] **Step 1: Write the failing test**

Create `functions/test/entitlements.test.js`:

```js
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
    evaluateEntitlement({ ...expiredDoc, expiresDateMs: NOW + HOUR }, NOW),
    { premium: true, needsRefresh: false }
  );
});

test("expired doc needs a refresh", () => {
  assert.deepEqual(evaluateEntitlement(expiredDoc, NOW), { premium: false, needsRefresh: true });
});

test("refresh waits 6h after the last successful check", () => {
  const doc = { ...expiredDoc, lastCheckedMs: NOW - 5 * HOUR };
  assert.equal(evaluateEntitlement(doc, NOW).needsRefresh, false);
  assert.equal(evaluateEntitlement({ ...doc, lastCheckedMs: NOW - 6 * HOUR }, NOW).needsRefresh, true);
});

test("refresh waits 15 min after a failed attempt", () => {
  const doc = { ...expiredDoc, lastRefreshAttemptMs: NOW - 10 * 60 * 1000 };
  assert.equal(evaluateEntitlement(doc, NOW).needsRefresh, false);
  assert.equal(evaluateEntitlement({ ...doc, lastRefreshAttemptMs: NOW - 15 * 60 * 1000 }, NOW).needsRefresh, true);
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

test("getPremiumStatus does not call Apple for a user with no entitlement", async () => {
  const db = createFakeFirestore();
  const appStore = { fetchSubscriptionStatus: async () => assert.fail("should not be called") };
  const store = createEntitlementStore({ db, appStore, now: () => NOW });

  assert.equal(await store.getPremiumStatus("nobody"), false);
});

test("recordTransaction writes a fresh entitlement doc", async () => {
  const db = createFakeFirestore();
  const store = createEntitlementStore({ db, appStore: {}, now: () => NOW });

  await store.recordTransaction("u1", {
    productId: "premium_yearly",
    originalTransactionId: "2000000222",
    expiresDate: NOW + 365 * 24 * HOUR,
    environment: "Sandbox",
  });
  assert.deepEqual(db.docs.get("entitlements/u1"), {
    productId: "premium_yearly",
    originalTransactionId: "2000000222",
    expiresDateMs: NOW + 365 * 24 * HOUR,
    environment: "Sandbox",
    revoked: false,
    lastCheckedMs: NOW,
    lastRefreshAttemptMs: 0,
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd functions && npm test`
Expected: FAIL with `Cannot find module '../src/entitlements'`.

- [ ] **Step 3: Implement `functions/src/entitlements.js`**

```js
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd functions && npm test`
Expected: `ℹ pass 38`, `ℹ fail 0`.

- [ ] **Step 5: Commit**

```bash
git add functions/src/entitlements.js functions/test/entitlements.test.js
git commit -m "feat(functions): server-side premium entitlements with lazy Apple refresh" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Handlers, `index.js` wiring, Firestore rules

Switches both deployed functions to the new modules. After this task `getMultipleCarbCounts` enforces the quota and `validateAppStoreReceipt` is JWS-only.

**Files:**
- Create: `functions/src/handlers.js`, `firestore.rules`
- Rewrite: `functions/index.js`
- Modify: `firebase.json`
- Test: `functions/test/handlers.test.js`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: `createHandlers(deps)` where `deps = { checkRateLimit, getPremiumStatus, reserveLookup, releaseLookup, lookupFoods(sanitized), verifyTransaction, recordTransaction, now }` → `{ getMultipleCarbCounts(request), validateAppStoreReceipt(request) }`. Lookup response: `{ items, citations, quota: {premium: boolean, used: number | null, limit: number | null} }`. Receipt response shape unchanged from today.

- [ ] **Step 1: Write the failing test**

Create `functions/test/handlers.test.js`:

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const { HttpsError } = require("firebase-functions/v2/https");
const { createHandlers } = require("../src/handlers");

const NOW = Date.parse("2026-09-18T12:00:00Z");
const auth = { uid: "u1" };

function makeDeps(overrides = {}) {
  const calls = [];
  const deps = {
    checkRateLimit: async () => {},
    getPremiumStatus: async () => false,
    reserveLookup: async (uid, tz) => {
      calls.push(["reserve", uid, tz]);
      return { dayKey: "2026-09-18", used: 1, limit: 4 };
    },
    releaseLookup: async (uid, key) => {
      calls.push(["release", uid, key]);
    },
    lookupFoods: async (input) => {
      calls.push(["lookup", input]);
      return { items: [{ name: "Apple", carbs: 25 }], citations: [] };
    },
    verifyTransaction: async () => ({}),
    recordTransaction: async (uid, payload) => {
      calls.push(["record", uid, payload.productId]);
    },
    now: () => NOW,
    ...overrides,
  };
  return { deps, calls };
}

test("free lookup reserves quota before calling Perplexity and returns it", async () => {
  const { deps, calls } = makeDeps();
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({ auth, data: { input: "an apple", tzOffsetMinutes: -300 } });

  assert.deepEqual(calls, [["reserve", "u1", -300], ["lookup", "an apple"]]);
  assert.deepEqual(res.quota, { premium: false, used: 1, limit: 4 });
  assert.equal(res.items[0].name, "Apple");
});

test("premium lookup skips the quota", async () => {
  const { deps, calls } = makeDeps({ getPremiumStatus: async () => true });
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({ auth, data: { input: "an apple" } });

  assert.deepEqual(calls, [["lookup", "an apple"]]);
  assert.deepEqual(res.quota, { premium: true, used: null, limit: null });
});

test("missing tzOffsetMinutes reserves against UTC", async () => {
  const { deps, calls } = makeDeps();
  await createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } });
  assert.deepEqual(calls[0], ["reserve", "u1", 0]);
});

test("daily-quota error passes through without calling Perplexity", async () => {
  const quotaErr = new HttpsError("resource-exhausted", "You've used today's 4 free lookups.", {
    reason: "daily-quota", used: 4, limit: 4,
  });
  const { deps, calls } = makeDeps({ reserveLookup: async () => { throw quotaErr; } });

  await assert.rejects(createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } }), quotaErr);
  assert.deepEqual(calls, []);
});

test("Perplexity failure releases the reserved lookup and rethrows", async () => {
  const boom = new HttpsError("internal", "Server error. Try again later.");
  const { deps, calls } = makeDeps({
    lookupFoods: async () => { throw boom; },
  });

  await assert.rejects(createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } }), boom);
  assert.deepEqual(calls, [["reserve", "u1", 0], ["release", "u1", "2026-09-18"]]);
});

test("quota infrastructure failure fails closed with internal", async () => {
  const { deps, calls } = makeDeps({ getPremiumStatus: async () => { throw new Error("firestore down"); } });

  await assert.rejects(
    createHandlers(deps).getMultipleCarbCounts({ auth, data: { input: "an apple" } }),
    (err) => err.code === "internal"
  );
  assert.deepEqual(calls, []);
});

test("unauthenticated calls are rejected", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    createHandlers(deps).getMultipleCarbCounts({ data: { input: "an apple" } }),
    (err) => err.code === "unauthenticated"
  );
});

const activePayload = {
  productId: "premium_yearly",
  transactionId: "2000000333",
  originalTransactionId: "2000000222",
  expiresDate: NOW + 1000,
  environment: "Sandbox",
  bundleId: "com.jamesaguero.mycarbtracker",
};

test("valid active transaction is recorded and reported valid", async () => {
  const { deps, calls } = makeDeps({ verifyTransaction: async () => activePayload });

  const res = await createHandlers(deps).validateAppStoreReceipt({
    auth, data: { receiptData: "a.b.c", expectedProductId: "premium_yearly" },
  });

  assert.deepEqual(calls, [["record", "u1", "premium_yearly"]]);
  assert.deepEqual(res, {
    isValid: true,
    productId: "premium_yearly",
    transactionId: "2000000333",
    originalTransactionId: "2000000222",
    expiresDateMs: NOW + 1000,
    environment: "Sandbox",
    bundleId: "com.jamesaguero.mycarbtracker",
  });
});

test("expired transaction is not recorded", async () => {
  const { deps, calls } = makeDeps({
    verifyTransaction: async () => ({ ...activePayload, expiresDate: NOW - 1 }),
  });

  const res = await createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c" } });

  assert.equal(res.reason, "no-active-subscription");
  assert.deepEqual(calls, []);
});

test("product mismatch still records the entitlement", async () => {
  const { deps, calls } = makeDeps({ verifyTransaction: async () => activePayload });

  const res = await createHandlers(deps).validateAppStoreReceipt({
    auth, data: { receiptData: "a.b.c", expectedProductId: "premium_monthlysub" },
  });

  assert.equal(res.reason, "product-mismatch");
  assert.deepEqual(calls, [["record", "u1", "premium_yearly"]]);
});

test("verification failure maps to failed-precondition", async () => {
  const { deps } = makeDeps({ verifyTransaction: async () => { throw new Error("bad chain"); } });

  await assert.rejects(
    createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c" } }),
    (err) => err.code === "failed-precondition"
  );
});

test("unknown expectedProductId is rejected", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c", expectedProductId: "x" } }),
    (err) => err.code === "invalid-argument"
  );
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd functions && npm test`
Expected: FAIL with `Cannot find module '../src/handlers'`.

- [ ] **Step 3: Implement `functions/src/handlers.js`**

```js
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd functions && npm test`
Expected: `ℹ pass 50`, `ℹ fail 0`.

- [ ] **Step 5: Rewrite `functions/index.js`**

Replace the whole file. This removes the legacy `verifyReceipt` path, the hand-rolled JWS verifier, and the `APP_STORE_SHARED_SECRET` secret.

```js
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
```

- [ ] **Step 6: Check the entry point loads**

Run: `cd functions && node -e 'console.log(Object.keys(require("./index.js")))'`
Expected: `[ 'validateAppStoreReceipt', 'getMultipleCarbCounts' ]`

- [ ] **Step 7: Add Firestore rules**

Create `firestore.rules` at the repo root. The app has no `cloud_firestore` dependency; the functions use the Admin SDK, which bypasses rules.

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Only Cloud Functions (Admin SDK) read or write Firestore.
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
```

- [ ] **Step 8: Point `firebase.json` at the rules and skip tests on deploy**

Replace `firebase.json` with (same Flutter config as today; adds `firestore` and two `ignore` entries):

```json
{
  "firestore": {
    "rules": "firestore.rules"
  },
  "functions": [
    {
      "source": "functions",
      "codebase": "default",
      "ignore": [
        "node_modules",
        ".git",
        "firebase-debug.log",
        "firebase-debug.*.log",
        "*.local",
        "test",
        "scripts"
      ]
    }
  ],
  "flutter": {
    "platforms": {
      "ios": {
        "default": {
          "projectId": "carpecarb",
          "appId": "1:3524983216:ios:32627602ca3cfced9d7e75",
          "uploadDebugSymbols": false,
          "fileOutput": "ios/Runner/GoogleService-Info.plist"
        },
        "buildConfigurations": {
          "Release": {
            "projectId": "carpecarb",
            "appId": "1:3524983216:ios:32627602ca3cfced9d7e75",
            "uploadDebugSymbols": false,
            "fileOutput": "ios/Runner/GoogleService-Info.plist"
          }
        }
      },
      "dart": {
        "lib/firebase_options.dart": {
          "projectId": "carpecarb",
          "configurations": {
            "ios": "1:3524983216:ios:32627602ca3cfced9d7e75"
          }
        }
      }
    }
  }
}
```

Run: `node -e 'JSON.parse(require("fs").readFileSync("firebase.json","utf8")); console.log("ok")'`
Expected: `ok`

- [ ] **Step 9: Run the full functions suite once more**

Run: `cd functions && npm test`
Expected: `ℹ pass 50`, `ℹ fail 0`.

- [ ] **Step 10: Commit**

```bash
git add functions/src/handlers.js functions/test/handlers.test.js functions/index.js firestore.rules firebase.json
git commit -m "feat(functions): enforce free lookup quota server-side; JWS-only receipt validation" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Flutter response and error parsing

**Files:**
- Create: `lib/models/server_quota.dart`, `lib/services/lookup_api.dart`
- Modify: `lib/utils/user_facing_exception.dart`
- Test: `test/lookup_api_test.dart`

**Interfaces:**
- Produces: `ServerQuota({required bool premium, int? used, int? limit})` + `static ServerQuota? fromJson(Object?)`; `DailyLimitReachedException({int? used, int? limit}) extends UserFacingException`; `LookupResult({required List<FoodItem> items, ServerQuota? quota})`; `LookupResult parseLookupResponse(String body)`; `UserFacingException parseCallableError(int statusCode, String body)`.

- [ ] **Step 1: Write the failing test**

Create `test/lookup_api_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/utils/user_facing_exception.dart';
import 'package:flutter_test/flutter_test.dart';

String callableResult(Map<String, dynamic> result) => jsonEncode({'result': result});
String callableError(String status, String message, [Map<String, dynamic>? details]) =>
    jsonEncode({
      'error': {'status': status, 'message': message, if (details != null) 'details': details},
    });

void main() {
  group('parseLookupResponse', () {
    test('parses items, citations, and a free-tier quota', () {
      final result = parseLookupResponse(callableResult({
        'items': [
          {'name': 'Apple', 'carbs': 25, 'protein': 0.5, 'details': 'USDA [1]'},
        ],
        'citations': ['https://fdc.nal.usda.gov'],
        'quota': {'premium': false, 'used': 2, 'limit': 4},
      }));

      expect(result.items.single.name, 'Apple');
      expect(result.items.single.carbs, 25.0);
      expect(result.items.single.protein, 0.5);
      expect(result.items.single.citations, ['https://fdc.nal.usda.gov']);
      expect(result.quota!.premium, isFalse);
      expect(result.quota!.used, 2);
      expect(result.quota!.limit, 4);
    });

    test('parses a premium quota with null counts', () {
      final result = parseLookupResponse(callableResult({
        'items': [{'name': 'Rice', 'carbs': 45}],
        'quota': {'premium': true, 'used': null, 'limit': null},
      }));

      expect(result.quota!.premium, isTrue);
      expect(result.quota!.used, isNull);
    });

    test('tolerates a response without quota', () {
      final result = parseLookupResponse(callableResult({
        'items': [{'name': 'Rice', 'carbs': '45'}],
      }));

      expect(result.quota, isNull);
      expect(result.items.single.carbs, 45.0);
    });

    test('throws a user-facing error for empty or malformed bodies', () {
      expect(() => parseLookupResponse(callableResult({'items': []})),
          throwsA(isA<UserFacingException>()));
      expect(() => parseLookupResponse('{}'), throwsA(isA<UserFacingException>()));
      expect(() => parseLookupResponse('not json'), throwsA(isA<UserFacingException>()));
    });
  });

  group('parseCallableError', () {
    test('daily-quota 429 becomes DailyLimitReachedException', () {
      final e = parseCallableError(
        429,
        callableError('RESOURCE_EXHAUSTED', "You've used today's 4 free lookups.",
            {'reason': 'daily-quota', 'used': 4, 'limit': 4}),
      );

      expect(e, isA<DailyLimitReachedException>());
      final limitError = e as DailyLimitReachedException;
      expect(limitError.used, 4);
      expect(limitError.limit, 4);
      expect(limitError.message, "You've used all 4 free AI lookups for today.");
    });

    test('per-minute 429 keeps the rate-limit message', () {
      final e = parseCallableError(
          429, callableError('RESOURCE_EXHAUSTED', 'Rate limit exceeded. Try again in 12 second(s).'));

      expect(e, isNot(isA<DailyLimitReachedException>()));
      expect(e.message, 'Rate limit exceeded. Please try again later.');
    });

    test('auth failures ask the user to restart', () {
      expect(parseCallableError(401, '').message, 'Authentication error. Please restart the app.');
      expect(parseCallableError(403, '').message, 'Authentication error. Please restart the app.');
    });

    test('other errors surface the server message, or a fallback', () {
      expect(parseCallableError(400, callableError('INVALID_ARGUMENT', 'input must be 2-100 characters')).message,
          'input must be 2-100 characters');
      expect(parseCallableError(500, '<html>oops</html>').message,
          'Failed to get carb count. Please try again.');
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/lookup_api_test.dart`
Expected: FAIL to compile: `Error when reading 'lib/services/lookup_api.dart'` / `DailyLimitReachedException` isn't a type.

- [ ] **Step 3: Add `ServerQuota`**

Create `lib/models/server_quota.dart`:

```dart
/// The caller's AI-lookup quota as reported by the getMultipleCarbCounts
/// Cloud Function. The server is the authority; the app caches this for
/// display and as a fast pre-check.
class ServerQuota {
  const ServerQuota({required this.premium, this.used, this.limit});

  final bool premium;

  /// Lookups used today. Null for premium users.
  final int? used;

  /// Free lookups per day. Null for premium users.
  final int? limit;

  /// Parses the `quota` object from a lookup response, or returns null if it
  /// is missing or malformed (e.g. an older function deployment).
  static ServerQuota? fromJson(Object? json) {
    if (json is! Map) return null;
    final premium = json['premium'];
    if (premium is! bool) return null;
    final used = json['used'];
    final limit = json['limit'];
    return ServerQuota(
      premium: premium,
      used: used is int ? used : null,
      limit: limit is int ? limit : null,
    );
  }
}
```

- [ ] **Step 4: Add `DailyLimitReachedException`**

Replace `lib/utils/user_facing_exception.dart` with:

```dart
/// An exception whose message is safe to display directly to the user.
///
/// Throw this (instead of a generic [Exception]) whenever the message has
/// already been translated into a user-friendly string. Callers can then
/// distinguish it from unexpected internal errors and show the message
/// verbatim rather than a generic fallback.
class UserFacingException implements Exception {
  const UserFacingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The server refused a lookup because this free user has used today's
/// quota. [used] and [limit] come from the error details and may be null if
/// the server omitted them.
class DailyLimitReachedException extends UserFacingException {
  DailyLimitReachedException({this.used, this.limit})
      : super(limit == null
            ? "You've used today's free AI lookups."
            : "You've used all $limit free AI lookups for today.");

  final int? used;
  final int? limit;
}
```

- [ ] **Step 5: Add the parsers**

Create `lib/services/lookup_api.dart` (the item mapping is moved from `lib/services/perplexity_firebase_service.dart:101-141`):

```dart
import 'dart:convert';

import '../models/food_item.dart';
import '../models/server_quota.dart';
import '../utils/user_facing_exception.dart';

/// Result of one getMultipleCarbCounts call.
class LookupResult {
  const LookupResult({required this.items, this.quota});

  final List<FoodItem> items;

  /// Null when the server response has no `quota` (older deployment).
  final ServerQuota? quota;
}

/// Parses a 200 response body from the getMultipleCarbCounts callable.
/// Throws [UserFacingException] when the body has no usable items.
LookupResult parseLookupResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw const UserFacingException('No results returned. Please try again.');
  }
  final result = decoded is Map ? (decoded['result'] ?? decoded['data']) : null;
  if (result is! Map || result['items'] is! List) {
    throw const UserFacingException('No results returned. Please try again.');
  }

  final items = result['items'] as List;
  final citations = result['citations'] is List
      ? (result['citations'] as List).whereType<String>().toList()
      : <String>[];

  if (items.isEmpty) {
    throw const UserFacingException(
        'No food items found. Please try a different description.');
  }

  double? parseOptional(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  final foods = items.whereType<Map>().map((item) {
    final carbsRaw = item['carbs'];
    final carbs = carbsRaw is num
        ? carbsRaw.toDouble()
        : double.tryParse(carbsRaw.toString()) ?? 0.0;

    return FoodItem(
      name: (item['name'] as String?) ?? 'Unknown',
      carbs: carbs,
      protein: parseOptional(item['protein']),
      fat: parseOptional(item['fat']),
      fiber: parseOptional(item['fiber']),
      calories: parseOptional(item['calories']),
      details: item['details'] as String?,
      citations: citations,
    );
  }).toList();

  return LookupResult(items: foods, quota: ServerQuota.fromJson(result['quota']));
}

/// Maps a non-200 callable response to the exception the UI should show.
/// Callable errors have the body `{"error": {"message", "status", "details"}}`.
UserFacingException parseCallableError(int statusCode, String body) {
  Map? error;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['error'] is Map) error = decoded['error'] as Map;
  } on FormatException {
    error = null; // Non-JSON body (e.g. a proxy error page): use the fallbacks.
  }
  final details = error?['details'];

  if (statusCode == 429 && details is Map && details['reason'] == 'daily-quota') {
    final used = details['used'];
    final limit = details['limit'];
    return DailyLimitReachedException(
      used: used is int ? used : null,
      limit: limit is int ? limit : null,
    );
  }
  if (statusCode == 401 || statusCode == 403) {
    return const UserFacingException('Authentication error. Please restart the app.');
  }
  if (statusCode == 429) {
    return const UserFacingException('Rate limit exceeded. Please try again later.');
  }
  final message = error?['message'];
  if (message is String && message.isNotEmpty) return UserFacingException(message);
  return const UserFacingException('Failed to get carb count. Please try again.');
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `flutter test test/lookup_api_test.dart`
Expected: `+8: All tests passed!`

- [ ] **Step 7: Commit**

```bash
git add lib/models/server_quota.dart lib/services/lookup_api.dart lib/utils/user_facing_exception.dart test/lookup_api_test.dart
git commit -m "feat: parse server lookup quota and daily-limit errors" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: App follows the server quota and premium status

**Files:**
- Rewrite: `lib/services/premium_service.dart`, `lib/services/perplexity_firebase_service.dart`
- Modify: `lib/config/storage_keys.dart:50-53`, `lib/main.dart` (imports ~line 18; `_addFood` ~lines 587-655; `_showLookupLimitDialog` ~line 719), `lib/screens/settings_page.dart:1592`, `integration_test/app_test.dart` (imports ~line 27; test at ~line 321)
- Delete: `test/perplexity_service_test.dart`
- Test: `test/premium_service_test.dart`

**Interfaces:**
- Consumes: `ServerQuota`, `LookupResult`, `parseLookupResponse`, `parseCallableError`, `DailyLimitReachedException` (Task 6).
- Produces: `PremiumService({DateTime Function()? clock})`; `Future<void> applyServerQuota(ServerQuota quota)`; `int get dailyLookupLimit`; `int get dailyLookupCount` (0 when the cached date isn't today); `bool get hasReachedDailyLimit`. `incrementLookupCount()` is removed. New storage key `StorageKeys.dailyLookupLimit = 'daily_lookup_limit'`. `PerplexityFirebaseService.getMultipleCarbCounts(String) → Future<LookupResult>`; request body `{"data": {"input", "tzOffsetMinutes"}}`.

- [ ] **Step 1: Write the failing test**

Create `test/premium_service_test.dart`:

```dart
import 'package:carb_tracker/models/server_quota.dart';
import 'package:carb_tracker/services/premium_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime now;
  PremiumService makeService() => PremiumService(clock: () => now);

  setUp(() {
    now = DateTime(2026, 9, 18, 21, 0);
    SharedPreferences.setMockInitialValues({});
  });

  test('applyServerQuota caches used and limit for today', () async {
    final svc = makeService();
    await svc.init();

    await svc.applyServerQuota(const ServerQuota(premium: false, used: 3, limit: 4));

    expect(svc.dailyLookupCount, 3);
    expect(svc.dailyLookupLimit, 4);
    expect(svc.hasReachedDailyLimit, isFalse);

    await svc.applyServerQuota(const ServerQuota(premium: false, used: 4, limit: 4));
    expect(svc.hasReachedDailyLimit, isTrue);
  });

  test('cached count stops blocking once the day rolls over, without a restart', () async {
    final svc = makeService();
    await svc.init();
    await svc.applyServerQuota(const ServerQuota(premium: false, used: 4, limit: 4));
    expect(svc.hasReachedDailyLimit, isTrue);

    now = DateTime(2026, 9, 19, 0, 5); // app stayed alive past midnight

    expect(svc.dailyLookupCount, 0);
    expect(svc.hasReachedDailyLimit, isFalse);
  });

  test('server premium=false turns off a local premium flag', () async {
    SharedPreferences.setMockInitialValues({'is_premium': true, 'premium_plan': 'monthly'});
    final svc = makeService();
    await svc.init();

    await svc.applyServerQuota(const ServerQuota(premium: false, used: 1, limit: 4));

    expect(svc.isPremium, isFalse);
    expect(svc.premiumPlan, isNull);
  });

  test('server premium=true turns premium on and keeps the stored plan', () async {
    SharedPreferences.setMockInitialValues({'premium_plan': 'yearly'});
    final svc = makeService();
    await svc.init();

    await svc.applyServerQuota(const ServerQuota(premium: true));

    expect(svc.isPremium, isTrue);
    expect(svc.premiumPlan, 'yearly');
    expect(svc.hasReachedDailyLimit, isFalse);
  });

  test('limit falls back to 4 before the server has reported one', () async {
    final svc = makeService();
    await svc.init();
    expect(svc.dailyLookupLimit, PremiumService.freeDailyLookupLimit);
    expect(PremiumService.freeDailyLookupLimit, 4);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/premium_service_test.dart`
Expected: FAIL to compile: `No named parameter with the name 'clock'` and `The method 'applyServerQuota' isn't defined`.

- [ ] **Step 3: Add the storage key**

In `lib/config/storage_keys.dart`, replace:

```dart
  // Daily AI lookup rate limiting (free users: 15/day)
  static const String dailyLookupCount = 'daily_lookup_count';
  static const String dailyLookupDate = 'daily_lookup_date';
```

with:

```dart
  // Daily AI lookup quota, cached from the server's `quota` response
  // (free users: 4/day, enforced by getMultipleCarbCounts)
  static const String dailyLookupCount = 'daily_lookup_count';
  static const String dailyLookupDate = 'daily_lookup_date';
  static const String dailyLookupLimit = 'daily_lookup_limit';
```

- [ ] **Step 4: Rewrite `lib/services/premium_service.dart`**

```dart
import 'package:shared_preferences/shared_preferences.dart';
import '../config/storage_keys.dart';
import '../models/server_quota.dart';

class PremiumService {
  PremiumService({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const String monthlyPlan = 'monthly';
  static const String yearlyPlan = 'yearly';

  /// Fallback for display before the server has reported a limit. The
  /// server's FREE_DAILY_LOOKUP_LIMIT (functions/src/quota.js) is the authority.
  static const int freeDailyLookupLimit = 4;

  final DateTime Function() _clock;
  SharedPreferences? _prefs;

  bool get _isReady => _prefs != null;

  bool get isPremium =>
      (_isReady ? _prefs!.getBool(StorageKeys.isPremium) : null) ?? false;
  String? get premiumPlan =>
      _isReady ? _prefs!.getString(StorageKeys.premiumPlan) : null;

  // All features are available to everyone — subscription unlocks unlimited AI lookups.
  bool get isManualEntryEnabled => true;
  bool get isHealthSyncEnabled => true;
  bool get isCloudSyncEnabled => true;
  bool get isMacrosEnabled => true;

  /// Local calendar day, matching the server's dayKey for this device.
  String _todayKey() => _clock().toIso8601String().substring(0, 10);

  /// Lookups used today, as last reported by the server. 0 once the cached
  /// day is no longer today, so a long-running app doesn't stay locked out.
  int get dailyLookupCount {
    if (!_isReady) return 0;
    if (_prefs!.getString(StorageKeys.dailyLookupDate) != _todayKey()) return 0;
    return _prefs!.getInt(StorageKeys.dailyLookupCount) ?? 0;
  }

  int get dailyLookupLimit =>
      (_isReady ? _prefs!.getInt(StorageKeys.dailyLookupLimit) : null) ??
      freeDailyLookupLimit;

  /// Fast pre-check that skips a request the server would refuse. The server
  /// still decides; this only reflects its last answer.
  bool get hasReachedDailyLimit =>
      !isPremium && dailyLookupCount >= dailyLookupLimit;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await resetLookupCountIfNewDay();
  }

  /// Resets the daily lookup count if the stored date is not today.
  Future<void> resetLookupCountIfNewDay() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    final today = _todayKey();
    final storedDate = prefs.getString(StorageKeys.dailyLookupDate);
    if (storedDate != today) {
      await prefs.setInt(StorageKeys.dailyLookupCount, 0);
      await prefs.setString(StorageKeys.dailyLookupDate, today);
    }
  }

  /// Caches the server's view of this user's quota and premium status.
  /// Premium follows the server, so a lapsed or refunded subscription
  /// reverts to free on the next lookup.
  Future<void> applyServerQuota(ServerQuota quota) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    if (quota.premium != isPremium) {
      await setPremiumEnabled(quota.premium);
    }
    final used = quota.used;
    final limit = quota.limit;
    if (!quota.premium && used != null && limit != null) {
      await prefs.setInt(StorageKeys.dailyLookupCount, used);
      await prefs.setInt(StorageKeys.dailyLookupLimit, limit);
      await prefs.setString(StorageKeys.dailyLookupDate, _todayKey());
    }
  }

  Future<void> setPremiumPlan(String? plan) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    if (plan == null || plan.isEmpty) {
      await prefs.remove(StorageKeys.premiumPlan);
      return;
    }
    await prefs.setString(StorageKeys.premiumPlan, plan);
  }

  Future<void> setPremiumEnabled(bool value, {String? plan}) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setBool(StorageKeys.isPremium, value);
    if (value && plan != null && plan.isNotEmpty) {
      await prefs.setString(StorageKeys.premiumPlan, plan);
    }
    if (!value) {
      await prefs.remove(StorageKeys.premiumPlan);
    }
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/premium_service_test.dart`
Expected: `+5: All tests passed!`

- [ ] **Step 6: Update the integration test that used `incrementLookupCount`**

In `integration_test/app_test.dart`, add this import directly above `import 'package:carb_tracker/services/premium_service.dart';`:

```dart
import 'package:carb_tracker/models/server_quota.dart';
```

Then replace:

```dart
    test('incrementLookupCount increments correctly', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = PremiumService();
      await svc.init();

      await svc.incrementLookupCount();
      await svc.incrementLookupCount();

      expect(svc.dailyLookupCount, 2);
    });
```

with:

```dart
    test('applyServerQuota caches the server count', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = PremiumService();
      await svc.init();

      await svc.applyServerQuota(
          const ServerQuota(premium: false, used: 2, limit: 4));

      expect(svc.dailyLookupCount, 2);
    });
```

- [ ] **Step 7: Rewrite `lib/services/perplexity_firebase_service.dart`**

```dart
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../config/storage_keys.dart';
import '../utils/input_validation.dart';
import '../utils/user_facing_exception.dart';
import 'lookup_api.dart';

class PerplexityFirebaseService {
  static const _tokenChannel = MethodChannel(StorageKeys.tokenStorageChannel);
  // Rate limiting to prevent UI-level spamming
  static DateTime? _lastRequestTime;
  static const Duration _minRequestInterval = Duration(milliseconds: 1500);

  static const String _functionUrl =
      'https://us-central1-carpecarb.cloudfunctions.net/getMultipleCarbCounts';

  /// Looks up one or more food items via the Firebase Cloud Function.
  /// Throws [DailyLimitReachedException] when the server refuses a free
  /// user's lookup for today, and [UserFacingException] for other failures.
  /// Uses direct HTTPS REST call to avoid Firebase Functions SDK AOT crash
  /// (swift_task_switch in HTTPSCallable.call on iOS 12.9.x SDK).
  Future<LookupResult> getMultipleCarbCounts(String input) async {
    await _enforceRateLimit();

    final validationError = InputValidation.validateFoodInput(input);
    if (validationError != null) {
      throw UserFacingException(validationError);
    }

    // Normalize Unicode (curly apostrophes, smart quotes, etc.) before sending
    // to the API so the Cloud Function receives clean ASCII-safe text.
    final sanitizedInput = InputValidation.sanitizeForApi(input);

    // Get the current user's ID token for authentication
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw UserFacingException('Authentication error. Please restart the app.');
    }

    String idToken;
    try {
      idToken = await user.getIdToken() ?? '';
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to get ID token: $e');
      throw UserFacingException('Authentication error. Please restart the app.');
    }

    if (idToken.isEmpty) {
      throw UserFacingException('Authentication error. Please restart the app.');
    }

    // Keep the shared token fresh so Siri/Watch extensions can auth.
    // Stored in Keychain (secure) + App Group UserDefaults (backward compat).
    try {
      await _tokenChannel.invokeMethod<void>('saveToken', idToken);
    } catch (_) {
      // Non-fatal — token sharing is best-effort.
    }

    final body = jsonEncode({
      'data': {
        'input': sanitizedInput,
        // Lets the server count the free quota per local calendar day.
        'tzOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
      }
    });

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 60);
      try {
        final request = await client.postUrl(Uri.parse(_functionUrl));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('Authorization', 'Bearer $idToken');
        request.write(body);

        final response = await request.close().timeout(const Duration(seconds: 60));
        final responseBody = await response.transform(utf8.decoder).join();

        if (kDebugMode) debugPrint('Cloud Function HTTP ${response.statusCode}');

        if (response.statusCode != 200) {
          if (kDebugMode) debugPrint('Cloud Function error body: $responseBody');
          throw parseCallableError(response.statusCode, responseBody);
        }

        return parseLookupResponse(responseBody);
      } finally {
        client.close();
      }
    } on UserFacingException {
      rethrow;
    } on SocketException {
      throw UserFacingException('Network error. Please check your connection.');
    } catch (e) {
      if (kDebugMode) debugPrint('PerplexityFirebaseService error: $e');
      throw UserFacingException('Network error. Please check your connection.');
    }
  }

  /// Enforces rate limiting between API requests
  Future<void> _enforceRateLimit() async {
    if (_lastRequestTime != null) {
      final timeSinceLastRequest = DateTime.now().difference(_lastRequestTime!);
      if (timeSinceLastRequest < _minRequestInterval) {
        final waitTime = _minRequestInterval - timeSinceLastRequest;
        await Future.delayed(waitTime);
      }
    }
    _lastRequestTime = DateTime.now();
  }
}
```

- [ ] **Step 8: Update `lib/main.dart` imports**

Replace:

```dart
import 'models/food_item.dart';
import 'screens/settings_page.dart';
```

with:

```dart
import 'models/food_item.dart';
import 'models/server_quota.dart';
import 'screens/settings_page.dart';
```

- [ ] **Step 9: Update the pre-check comment in `_addFood`**

Replace:

```dart
    // Enforce daily lookup limit for free users
    if (_premiumService.hasReachedDailyLimit) {
```

with:

```dart
    // Fast pre-check for free users; the server enforces the real limit.
    if (_premiumService.hasReachedDailyLimit) {
```

- [ ] **Step 10: Apply the server quota on success**

Replace:

```dart
      final items = await _perplexityService.getMultipleCarbCounts(foodText);

      if (!mounted) return;

      await _premiumService.incrementLookupCount();
```

with:

```dart
      final result = await _perplexityService.getMultipleCarbCounts(foodText);
      final quota = result.quota;
      if (quota != null) await _premiumService.applyServerQuota(quota);

      if (!mounted) return;

      final items = result.items;
```

- [ ] **Step 11: Show the limit dialog when the server refuses**

Replace:

```dart
      for (final item in items) {
        _writeToHealthKit(item);
      }
    } catch (e) {
      if (!mounted) return;
```

with:

```dart
      for (final item in items) {
        _writeToHealthKit(item);
      }
    } on DailyLimitReachedException catch (e) {
      final limit = e.limit ?? _premiumService.dailyLookupLimit;
      await _premiumService.applyServerQuota(
          ServerQuota(premium: false, used: e.used ?? limit, limit: limit));
      if (!mounted) return;
      setState(() {
        isLoading = false;
      });
      _showLookupLimitDialog();
    } catch (e) {
      if (!mounted) return;
```

- [ ] **Step 12: Use the server's limit in the dialog copy**

In `_showLookupLimitDialog`, replace:

```dart
          "You've used all ${PremiumService.freeDailyLookupLimit} free AI lookups for today.\n\n"
```

with:

```dart
          "You've used all ${_premiumService.dailyLookupLimit} free AI lookups for today.\n\n"
```

- [ ] **Step 13: Use the server's limit in Settings**

In `lib/screens/settings_page.dart` (`_buildPremiumTab`), replace:

```dart
    final limit = PremiumService.freeDailyLookupLimit;
```

with:

```dart
    final limit = ps?.dailyLookupLimit ?? PremiumService.freeDailyLookupLimit;
```

- [ ] **Step 14: Delete the placeholder test**

`test/perplexity_service_test.dart` only asserts string constants; `test/lookup_api_test.dart` now covers the parsing for real.

```bash
git rm test/perplexity_service_test.dart
```

- [ ] **Step 15: Analyze and run the whole suite**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` then `All tests passed!` (64 tests).

- [ ] **Step 16: Commit**

```bash
git add lib/config/storage_keys.dart lib/services/premium_service.dart test/premium_service_test.dart integration_test/app_test.dart lib/services/perplexity_firebase_service.dart lib/main.dart lib/screens/settings_page.dart
git commit -m "feat: app follows server lookup quota and premium status" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Siri client sends its offset and speaks the quota error

**Files:**
- Modify: `ios/CarbShared/Package.swift` (platforms)
- Rewrite: `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift`
- Test: `ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift` (the directory doesn't exist yet; `Package.swift` already declares the target)

**Interfaces:**
- Produces: `PerplexityClient.errorMessage(status: Int, body: Data) -> String` (internal; tested via `@testable import`). Request body adds `tzOffsetMinutes`.

- [ ] **Step 1: Let the package test on the Mac host**

In `ios/CarbShared/Package.swift`, replace:

```swift
        .iOS(.v16),
        .watchOS(.v9),
    ],
```

with:

```swift
        .iOS(.v16),
        .watchOS(.v9),
        .macOS(.v13),
    ],
```

- [ ] **Step 2: Write the failing test**

Create `ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift`:

```swift
import Foundation
import Testing
@testable import CarbShared

struct PerplexityClientErrorMessageTests {
    private func errorBody(reason: String? = nil, limit: Int? = nil) throws -> Data {
        var details: [String: Any] = [:]
        if let reason { details["reason"] = reason }
        if let limit { details["limit"] = limit }
        let body: [String: Any] = [
            "error": [
                "status": "RESOURCE_EXHAUSTED",
                "message": "irrelevant",
                "details": details,
            ] as [String: Any]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test func dailyQuotaNamesTheLimit() throws {
        let message = PerplexityClient.errorMessage(status: 429, body: try errorBody(reason: "daily-quota", limit: 4))
        #expect(message == "You've used today's 4 free lookups. Open CarpeCarb to go unlimited.")
    }

    @Test func dailyQuotaWithoutLimitStillReadsNaturally() throws {
        let message = PerplexityClient.errorMessage(status: 429, body: try errorBody(reason: "daily-quota"))
        #expect(message == "You've used today's free lookups. Open CarpeCarb to go unlimited.")
    }

    @Test func perMinuteRateLimitKeepsItsMessage() throws {
        let message = PerplexityClient.errorMessage(status: 429, body: try errorBody())
        #expect(message == "Rate limit exceeded. Try again shortly.")
    }

    @Test func otherStatusesReportTheCode() {
        #expect(PerplexityClient.errorMessage(status: 500, body: Data("oops".utf8)) == "Server error (500).")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd ios/CarbShared && swift test`
Expected: FAIL to compile: `type 'PerplexityClient' has no member 'errorMessage'`.

- [ ] **Step 4: Rewrite `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift`**

```swift
import Foundation

public struct PerplexityClient {
    private static var lastRequestTime: Date?
    private static let minInterval: TimeInterval = 1.5

    // Firebase Cloud Function endpoint
    private static let cloudFunctionURL = "https://us-central1-carpecarb.cloudfunctions.net/getMultipleCarbCounts"

    private static func enforceRateLimit() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    public static func lookupCarbs(for foodItem: String) async throws -> (name: String, carbs: Double, details: String?, citations: [String]) {
        await enforceRateLimit()

        let url = URL(string: cloudFunctionURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        if let token = CarbDataStore.firebaseIdToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "data": [
                "input": foodItem,
                // Lets the server count the free quota per local calendar day.
                "tzOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            ] as [String: Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntentError.message("Invalid response from server.")
        }

        guard httpResponse.statusCode == 200 else {
            throw IntentError.message(errorMessage(status: httpResponse.statusCode, body: data))
        }

        // Firebase callable functions wrap the response in {"result": ...}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let items = result["items"] as? [[String: Any]],
              let first = items.first else {
            throw IntentError.message("Could not parse server response.")
        }

        let name = first["name"] as? String ?? "Unknown"
        let carbs: Double
        if let carbNum = first["carbs"] as? NSNumber {
            carbs = carbNum.doubleValue
        } else if let carbStr = first["carbs"] as? String, let parsed = Double(carbStr) {
            carbs = parsed
        } else {
            carbs = 0
        }
        let details = first["details"] as? String

        let citations: [String]
        if let citationArray = result["citations"] as? [String] {
            citations = citationArray
        } else {
            citations = []
        }

        return (name: name, carbs: carbs, details: details, citations: citations)
    }

    /// Maps a non-200 response from the callable function to a message Siri
    /// can speak. Callable errors have the body
    /// `{"error": {"message", "status", "details"}}`.
    static func errorMessage(status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let details = (json?["error"] as? [String: Any])?["details"] as? [String: Any]

        if status == 429, details?["reason"] as? String == "daily-quota" {
            let limit = (details?["limit"] as? NSNumber)?.intValue
            let count = limit.map { "\($0) " } ?? ""
            return "You've used today's \(count)free lookups. Open CarpeCarb to go unlimited."
        }
        if status == 429 {
            return "Rate limit exceeded. Try again shortly."
        }
        return "Server error (\(status))."
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/CarbShared && swift test`
Expected: `✔ Test run with 4 tests in 1 suite passed`.

- [ ] **Step 6: Confirm the iOS app still builds**

Run: `flutter build ios --debug --no-codesign`
Expected: ends with `✓ Built build/ios/iphoneos/Runner.app`.

- [ ] **Step 7: Commit**

```bash
git add ios/CarbShared/Package.swift ios/CarbShared/Sources/CarbShared/PerplexityClient.swift ios/CarbShared/Tests
git commit -m "feat(siri): send UTC offset and speak the daily lookup limit" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Deploy and verify (needs James — App Store Connect and Firebase access)

No code. Steps 1-2 and 7 need App Store Connect access; steps 4-5 and 8 change production. Confirm with James before running each deploy command.

- [ ] **Step 1: Confirm there are no production subscribers**

Confirm in App Store Connect → Sales/Subscriptions that there are no active production subscriptions. (The rollout has no migration path for existing subscribers.)

- [ ] **Step 2: Create the In-App Purchase API key**

App Store Connect → Users and Access → Integrations → In-App Purchase → Generate. Download the `.p8` (only downloadable once). Note the **Key ID** and the **Issuer ID** shown on that page. Find the app's numeric **Apple ID** under App Store Connect → the app → App Information → General Information → Apple ID.

- [ ] **Step 3: Set the four secrets**

```bash
firebase functions:secrets:set APP_STORE_IAP_KEY --data-file path/to/SubscriptionKey_XXXXXXXXXX.p8
firebase functions:secrets:set APP_STORE_KEY_ID      # paste Key ID
firebase functions:secrets:set APP_STORE_ISSUER_ID   # paste Issuer ID
firebase functions:secrets:set APP_APPLE_ID          # paste numeric Apple ID
```

- [ ] **Step 4: Deploy Firestore rules**

Run: `firebase deploy --only firestore:rules`
Expected: `✔ firestore: released rules firestore.rules to cloud.firestore`

- [ ] **Step 5: Enable TTL cleanup**

Google Cloud console → Firestore → Time-to-live → Create policy: collection group `lookupQuota`, field `expiresAt`. Repeat for `rateLimits` / `expiresAt` if no policy exists yet.

- [ ] **Step 6: Set a spend alert**

Perplexity bills separately from Google Cloud, so set both:
- Perplexity: in the Perplexity API console (Settings → Billing), set a monthly usage limit or low-balance alert.
- Google Cloud: Billing → Budgets & alerts → create a budget for project `carpecarb` covering Cloud Functions and Firestore.

- [ ] **Step 7: Submit app 1.0.2 for review with "Manually release"**

Archive and submit the build containing Tasks 6-8 as usual. In App Store Connect → the 1.0.2 version → App Store Version Release, choose **Manually release this version**.

- [ ] **Step 8: Once 1.0.2 is approved, deploy the functions and immediately release 1.0.2**

Run: `firebase deploy --only functions`
Expected: both `validateAppStoreReceipt` and `getMultipleCarbCounts` report `Successful update operation`. Then release 1.0.2 in App Store Connect right away. Optionally remove the now-unused secret afterwards: `firebase functions:secrets:destroy APP_STORE_SHARED_SECRET`.

> **Order matters.** Don't release 1.0.2 before the functions deploy: 1.0.2 has no limit against the old server (its limit comes from the server's `quota`). 1.0.2 works against the old server during review (a missing `quota` is ignored), so review can happen before the deploy.

- [ ] **Step 9: Verify on a TestFlight device**

1. Fresh install (free): four lookups succeed; Settings shows `AI lookups today: 4 / 4`; the fifth shows the Daily Limit Reached dialog.
2. Siri: "Log food in CarpeCarb" after the limit → speaks "You've used today's 4 free lookups. Open CarpeCarb to go unlimited."
3. Sandbox purchase (or Restore for existing TestFlight subscribers) → lookups unlimited; Firestore has `entitlements/{uid}` with `environment: "Sandbox"`.
4. Wait more than 5 minutes (one sandbox renewal) and confirm lookups are still unlimited.
5. After sandbox renewals stop (monthly renews every 5 min, up to 12 times), the next lookup reverts the app to the free plan.
6. Cloud Logging for `getMultipleCarbCounts` shows no `[config] Missing or invalid secrets` lines.
