# Server-side lookup quota and premium entitlement — design

Date: 2026-09-18 · Status: approved design, pending implementation plan

## Problem

The free tier (4 AI lookups/day) is enforced only on the client, and the server
has no idea who is premium.

- The limit check is `PremiumService.hasReachedDailyLimit`, read from
  SharedPreferences in `lib/main.dart:588`. The counter is incremented
  client-side (`lib/services/premium_service.dart:47`).
- `getMultipleCarbCounts` (`functions/index.js:351`) only applies a
  20-requests/minute per-UID limit. Auth is anonymous (`lib/main.dart:41`), so
  any caller can mint UIDs and run `sonar-pro` lookups without bound.
- The Siri path (`ios/CarbShared/Sources/CarbShared/PerplexityClient.swift`)
  calls the same function and never checks the limit at all.
- Premium is a local `is_premium` bool set on purchase/restore
  (`lib/screens/settings_page.dart:1654`, `:1694`) and never cleared, so a
  lapsed or refunded subscription stays premium forever.
- `validateAppStoreReceipt` trusts the JWS root certificate by subject-name
  match (`functions/index.js:190-196`) and checks no bundle ID. Because
  `in_app_purchase_storekit` 0.4.8 defaults to StoreKit 2
  (`_useStoreKit2 = true`), this JWS path is the live purchase path. A forged
  chain with a root named "Apple Root CA" passes today.

Moving the quota server-side requires the server to know premium status, which
requires trustworthy transaction verification. So this design covers review
findings #1 (quota), #3 (JWS verification), the server half of #2 (expiry),
and #9 (client daily-count reset) as a side effect.

## Goals

- The server is the authority for "may this UID run an AI lookup right now".
- Free UIDs get 4 lookups per local calendar day across app and Siri combined.
- Premium is derived only from Apple-verified transactions, kept current
  through expiry, renewal, and refund.
- The app's premium display follows the server, so lapsed subscriptions revert.

## Non-goals

- App Check / App Attest (follow-up pass; needs a staged rollout for Siri).
- App Store Server Notifications V2 webhook (can be layered on later).
- Siri token expiry, stale-day totals, multi-item logging (review #6–8).
- Binding a subscription to a limited number of UIDs.

## Server design

### Modules

`functions/index.js` (564 lines today) becomes wiring only. Logic moves to
`functions/src/`:

| Module | Responsibility |
|---|---|
| `appStore.js` | Wraps `@apple/app-store-server-library`. `verifyTransaction(jws)` → decoded payload via `SignedDataVerifier`, using Apple root certs bundled in `functions/certs/` (from apple.com/certificateauthority; `AppleRootCA-G3.cer` at minimum), bundle ID `com.jamesaguero.mycarbtracker`, and the numeric app Apple ID (required for Production). `fetchSubscriptionStatus(originalTransactionId, environment)` → current status and decoded transaction via `AppStoreServerAPIClient.getAllSubscriptionStatuses`. |
| `entitlements.js` | Pure `evaluateEntitlement(doc, nowMs)` → `{ premium, needsRefresh }`. `getPremiumStatus(uid)` reads the doc, refreshes from Apple when needed, writes back. `recordTransaction(uid, payload)` writes the doc after a verified purchase/restore. |
| `quota.js` | Pure `dayKey(nowMs, tzOffsetMin)` and `applyReservation(doc, dayKey, limit)` → `{ allowed, next }`. `reserveLookup(uid, tzOffsetMin)` runs `applyReservation` in a Firestore transaction. `releaseLookup(uid, dayKey)` decrements best-effort. |
| `perplexity.js` | `lookupFoods(input, apiKey)` — the existing prompt, retry loop, and response mapping from `index.js:392-562`, moved unchanged. |
| `rateLimit.js` | Existing `checkRateLimit`, moved unchanged. |

Handlers are built by `createHandlers(deps)` in `src/handlers.js`, taking the
store functions as dependencies (`checkRateLimit`, `getPremiumStatus`,
`reserveLookup`, `releaseLookup`, `lookupFoods`, `verifyTransaction`,
`recordTransaction`, `now`) so tests can inject fakes.

### Data (Firestore, Admin SDK only)

- `entitlements/{uid}`: `productId`, `originalTransactionId`, `expiresDateMs`,
  `environment` (`Production` | `Sandbox`), `revoked` (bool), `lastCheckedMs`,
  `lastRefreshAttemptMs`.
- `lookupQuota/{uid}`: `dayKey` (`YYYY-MM-DD`), `count`, `expiresAt`
  (TTL field, set to 2 days out). The limit is a single constant,
  `FREE_DAILY_LOOKUP_LIMIT = 4`, in `quota.js`.
- New `firestore.rules` in the repo, `allow read, write: if false;` for all
  paths. The app has no `cloud_firestore` dependency, so nothing client-side
  breaks; functions use the Admin SDK, which bypasses rules.

### Entitlement evaluation

- Premium if `!revoked && expiresDateMs > now`.
- If expired and `originalTransactionId` is set: `needsRefresh` when
  `lastCheckedMs` is older than 6 h and `lastRefreshAttemptMs` is older than
  15 min.
- Refresh maps Apple subscription status: `ACTIVE (1)` and
  `BILLING_GRACE_PERIOD (4)` → premium, with `expiresDateMs` taken from the
  verified `signedTransactionInfo`; `EXPIRED (2)`, `BILLING_RETRY (3)`,
  `REVOKED (5)` → not premium (`revoked = true` for 5).
- If the refresh call fails: premium while `now - expiresDateMs < 72 h`, else
  free. Record `lastRefreshAttemptMs`, log the error.

### `getMultipleCarbCounts` flow

1. Require auth.
2. Existing per-minute rate limit (20/min).
3. Validate and sanitize input (unchanged).
4. `premium = getPremiumStatus(uid)`.
5. If not premium: `reserveLookup(uid, tzOffsetMinutes)`. Over limit →
   `HttpsError('resource-exhausted', "You've used today's 4 free lookups.",
   { reason: 'daily-quota', used, limit })`. Reserving before the Perplexity
   call keeps concurrent requests from exceeding the limit.
6. `lookupFoods(...)`. On failure, `releaseLookup` then rethrow.
7. Return `{ items, citations, quota: { premium, used, limit } }`
   (`used`/`limit` are `null` when premium).

`tzOffsetMinutes` is taken from request data, must be an integer, and is
clamped to [-840, 840]. Missing or invalid → 0 (UTC); old app builds send
nothing and get UTC days.

### `validateAppStoreReceipt` flow

- JWS only. The legacy `verifyReceipt` path, its helpers, and the
  `APP_STORE_SHARED_SECRET` secret are removed: the app's deployment target is
  iOS 16 and the plugin defaults to StoreKit 2, so no base64 receipts arrive.
- Read the unverified payload's `environment`; accept only `Production` or
  `Sandbox`; verify with the verifier for that environment (the library
  enforces the match, bundle ID, and chain to the bundled Apple roots).
- Active = product in `PREMIUM_PRODUCT_IDS`, `expiresDate > now`, no
  `revocationDate`. Active → `recordTransaction(uid, payload)`.
- Response shape stays the same as today (`isValid`, `reason`, `productId`,
  `transactionId`, `originalTransactionId`, `expiresDateMs`, `environment`,
  `bundleId`). Verification failure → `failed-precondition` (HTTP 400). Not
  `permission-denied`: the app maps 403 to "Receipt verification blocked"
  (`lib/services/purchase_service.dart:90`), which is the wrong message here.

### Secrets and params

New: `APP_STORE_IAP_KEY` (.p8 contents), `APP_STORE_KEY_ID`,
`APP_STORE_ISSUER_ID`, `APP_APPLE_ID`. Removed: `APP_STORE_SHARED_SECRET`.
Missing secret → `internal` error with a clear log line.

## Client design

### Flutter

- New `lib/models/server_quota.dart`: `ServerQuota` + `fromJson`.
- New `lib/services/lookup_api.dart` (pure, no I/O):
  `LookupResult { items, quota }`, `parseLookupResponse(body)`,
  `parseCallableError(statusCode, body)`. The callable error body is
  `{ "error": { "message", "status", "details" } }`.
- `lib/utils/user_facing_exception.dart`: add
  `DailyLimitReachedException extends UserFacingException`.
- `PerplexityFirebaseService.getMultipleCarbCounts` sends
  `tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes`, returns
  `LookupResult`, and throws `DailyLimitReachedException` for a 429 whose
  `details.reason == 'daily-quota'`. Other 429s keep today's message.
  A response without `quota` is tolerated (deploy gap).
- `PremiumService`:
  - `incrementLookupCount` removed; `applyServerQuota(ServerQuota)` caches
    `used`, `limit` (new `StorageKeys.dailyLookupLimit`), and the device's
    local calendar date (not the app's daily reset hour, matching the server's
    `dayKey`), and sets `is_premium` from `quota.premium`.
  - `hasReachedDailyLimit` = not premium, cached date is today, and cached
    `used >= limit`. The date comparison fixes the stale counter when the app
    stays alive past midnight (review #9). It stays a fast path only; the
    server decides.
- `main.dart` `_addFood`: on success call `applyServerQuota`; on
  `DailyLimitReachedException` show the existing Daily Limit Reached dialog.
- Settings "AI lookups today: x / 4" reads the cached server values.

### Siri (`PerplexityClient.swift`)

- Sends `tzOffsetMinutes: TimeZone.current.secondsFromGMT() / 60`.
- New pure `static func errorMessage(status: Int, body: Data) -> String`.
  Daily-quota 429 → "You've used today's 4 free lookups. Open CarpeCarb to go
  unlimited."
- Siri lookups now count against the shared server quota. The in-app counter
  won't reflect them until the next in-app lookup response (accepted).

## Error handling summary

| Failure | Behavior |
|---|---|
| Apple status API unreachable | Premium up to 72 h past stored expiry, retry ≥ 15 min apart, then free |
| Quota transaction fails | Fail closed: no Perplexity call, generic error to client |
| `releaseLookup` fails | Log only; user loses one lookup |
| JWS verification fails | `failed-precondition` (400); app shows existing "Could not verify…" message |
| Missing secret | `internal` + log |
| Response lacks `quota` | Client ignores, keeps cached values |

## Rollout

No paying subscribers exist, so no migration path.

1. Create an In-App Purchase key in App Store Connect (Users and Access →
   Integrations); note key ID and issuer ID; find the app's numeric Apple ID.
2. `firebase functions:secrets:set` for the four new secrets.
3. Deploy `firestore.rules`.
4. Enable TTL in the console on `lookupQuota.expiresAt` (and on
   `rateLimits.expiresAt` if not already on).
5. Deploy functions. Live 1.0.1 free users are capped server-side at 4 (their
   client already stops at 4). TestFlight sandbox subscribers tap Restore once
   to create their entitlement doc.
6. Release app 1.0.2 with the client changes.

## Testing

- **Functions** — `node:test` (built into Node 22; no new test deps),
  `npm test` in `functions/`:
  - `dayKey`: offset clamp, invalid input, local-midnight edges, DST offsets.
  - `evaluateEntitlement`: active, expired → refresh, 6 h / 15 min backoff,
    72 h fail-open window, revoked.
  - `applyReservation`: new day resets, under limit, at limit.
  - Handler tests with injected fakes: reserve happens before `lookupFoods`;
    release on failure; premium skips the quota; daily-quota error details.
  - #3 regression: a committed fixture JWS signed by a self-made chain whose
    root subject is `CN=Apple Root CA` (generated once with openssl; script
    committed alongside) must be rejected by `verifyTransaction`.
- **Flutter** — `applyServerQuota`, `hasReachedDailyLimit` date rollover,
  `parseLookupResponse`, `parseCallableError` (daily-quota vs per-minute 429).
  The existing `test/perplexity_service_test.dart` only asserts string
  constants; the new parsing tests replace it.
- **Swift** — Swift Testing tests for `PerplexityClient.errorMessage` in
  `ios/CarbShared/Tests/CarbSharedTests/`. `Package.swift` already declares
  this test target but the directory doesn't exist; create it and add
  `.macOS(.v13)` to `platforms` so `swift test` runs on the host.
- **Manual (TestFlight device)** — 5th in-app lookup shows the dialog; 5th
  Siri lookup speaks the quota message; sandbox purchase → unlimited; after
  sandbox renewals stop, next lookup reverts the app to free.

## Accepted risks (until App Check)

- A modified client can spoof `tzOffsetMinutes` for a few extra lookups
  around day boundaries.
- A leaked JWS grants premium to other UIDs while that subscription is active.
- Sandbox transactions are accepted in production (TestFlight testers).
- Reinstalling can produce a new anonymous UID with a fresh daily quota.
