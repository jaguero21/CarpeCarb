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
| `quota.js` | Pure `dayKey(nowMs, tzOffsetMin)` and `applyReservation(doc, dayKey, limit)` → `{ allowed, dayKey, used, next }`. `reserveLookup(uid, tzOffsetMin)` runs `applyReservation` in a Firestore transaction. `releaseLookup(uid, dayKey)` decrements best-effort. |
| `perplexity.js` | `lookupFoods(input, apiKey)` — the existing prompt, retry loop, and response mapping from `index.js:392-562`. Errors thrown before Perplexity produced a completion are marked `notBilled` (`isNotBilled(err)`); output truncated at `max_tokens` is not retried. |
| `rateLimit.js` | Existing `checkRateLimit`, moved unchanged. |

Handlers are built by `createHandlers(deps)` in `src/handlers.js`, taking the
store functions as dependencies (`checkRateLimit`, `getPremiumStatus`,
`reserveLookup`, `releaseLookup`, `lookupFoods`, `verifyTransaction`,
`recordTransaction`, `now`) so tests can inject fakes.

### Data (Firestore, Admin SDK only)

- `entitlements/{uid}`: `productId`, `originalTransactionId`, `expiresDateMs`,
  `environment` (`Production` | `Sandbox`), `revoked` (bool), `revokedAtMs`
  (set with `revoked`), `lastCheckedMs`, `lastRefreshAttemptMs`.
- `lookupQuota/{uid}`: `dayKey` (`YYYY-MM-DD`), `count`, `expiresAt`
  (TTL field, set to 2 days out). The limit is a single constant,
  `FREE_DAILY_LOOKUP_LIMIT = 4`, in `quota.js`.
- New `firestore.rules` in the repo, `allow read, write: if false;` for all
  paths. The app has no `cloud_firestore` dependency, so nothing client-side
  breaks; functions use the Admin SDK, which bypasses rules.

### Entitlement evaluation

As implemented in `evaluateEntitlement` and `recordTransaction`
(`functions/src/entitlements.js`):

- No doc, or `revoked` → free, never refreshed.
- Active (`expiresDateMs > now`) → premium. Re-checked with Apple once
  `lastCheckedMs` is 24 h old, so a refund is noticed without waiting for the
  stored expiry (up to a year for `premium_yearly`).
- Expired, with `originalTransactionId` set → refresh, unless a check made
  *after* the stored expiry confirmed the lapse less than 6 h ago. A check from
  before the expiry (e.g. the first-lookup check right after purchase) says
  nothing about renewal: sandbox monthly subscriptions renew every 5 min, and
  waiting 6 h after the purchase-time check dropped a new buyer (App Review
  included) to free about 5 min after buying.
- No refresh within 15 min of the last attempt (`lastRefreshAttemptMs`).
- Refresh maps Apple subscription status: `ACTIVE (1)` and
  `BILLING_GRACE_PERIOD (4)` → premium, with `expiresDateMs` taken from the
  verified `signedTransactionInfo`; `EXPIRED (2)`, `BILLING_RETRY (3)` → not
  premium; `REVOKED (5)` → `revoked = true` and `revokedAtMs` = the
  transaction's `revocationDate` (now, if absent).
- If the refresh call fails: record `lastRefreshAttemptMs`, log the error, and
  stay premium while `now - expiresDateMs < 72 h` (an unexpired doc stays
  premium). The fail-open covers every request in the 15-min backoff, not just
  the one that attempted: a `lastRefreshAttemptMs` newer than `lastCheckedMs`
  means Apple was unreachable, so evaluation keeps the 72 h window.
- New entitlements: `recordTransaction` writes `lastCheckedMs: 0`, so the
  first lookup after a purchase or restore re-checks with Apple. A refunded
  receipt replayed on a fresh UID (no revoked doc to compare against) is
  caught there instead of getting 24 h of premium; if Apple is down, the
  unexpired doc still fails open.
- Replay after a refund: `recordTransaction` refuses a transaction with the
  revoked doc's `originalTransactionId` unless its `purchaseDate` is after
  `revokedAtMs` (a missing `purchaseDate` or `revokedAtMs` refuses), so the
  pre-refund JWS can't un-revoke the doc; `validateAppStoreReceipt` answers
  `{ isValid: false, reason: "revoked" }`.
- Resubscribe exception: Apple keeps the same `originalTransactionId` when a
  user resubscribes in the same group, so the rule compares purchase time with
  revocation time rather than blocking the ID. A purchase after the revocation
  is accepted and rewrites the doc with `revoked: false`.

### `getMultipleCarbCounts` flow

1. Require auth.
2. Existing per-minute rate limit (20/min).
3. Validate and sanitize input (unchanged).
4. `premium = getPremiumStatus(uid)`.
5. If not premium: `reserveLookup(uid, tzOffsetMinutes)`. Over limit →
   `HttpsError('resource-exhausted', "You've used today's 4 free lookups.",
   { reason: 'daily-quota', used, limit, dayKey })`. Reserving before the
   Perplexity call keeps concurrent requests from exceeding the limit.
6. `lookupFoods(...)`. On failure, `releaseLookup` only when Perplexity didn't
   bill the call (`isNotBilled(err)`: 401, 429, 5xx after retries, any other
   non-OK status, network failure), then rethrow. A billed completion that
   fails afterwards (e.g. no parseable JSON after 3 attempts) keeps the
   reservation; refunding it would let one input cost 3 billed calls and no
   quota.
   Output truncated at `max_tokens` (`finish_reason: "length"`) isn't retried:
   `invalid-argument`, "Too many foods in one lookup. Try fewer items."
7. Return `{ items, citations, quota: { premium, used, limit, dayKey } }`
   (`used`/`limit`/`dayKey` are `null` when premium).

`tzOffsetMinutes` is taken from request data, must be an integer, and is
clamped to [-840, 840]. Missing or invalid → 0 (UTC); old app builds send
nothing and get UTC days.

The stored day key never moves backwards: a request whose `dayKey` is earlier
than the stored one counts against the stored (later) day (`applyReservation`
in `quota.js`). Otherwise alternating `tzOffsetMinutes` between +840 and −840
reset the count on every call. `reserveLookup` returns that effective day key,
so `releaseLookup` decrements the same day, and both the lookup response's
`quota` and the daily-quota error details carry it as `dayKey`.

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
    `used`, `limit` (new `StorageKeys.dailyLookupLimit`), and the server's
    `dayKey` (the device's local calendar date if the server sent none), and
    sets `is_premium` from `quota.premium`. Caching under the server's day
    matters at midnight: a lookup counted against yesterday that completes
    just after local midnight must not block today.
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
| Perplexity billed but failed | No refund; the lookup counts |
| JWS verification fails | `failed-precondition` (400); app shows existing "Could not verify…" message |
| Missing secret | `internal` + log |
| Response lacks `quota` | Client ignores, keeps cached values |

## Rollout

No active production subscriptions are expected (step 1 confirms), so there is
no migration path beyond Restore. The detailed checklist is plan Task 9.

1. Check what's deployed: whether the live `validateAppStoreReceipt` accepts
   `premium_monthlysub`/`premium_yearly` (`main`'s only accepts
   `carpecarb_premium_*`), and whether App Store Connect shows any active
   production subscriptions. A 1.0.1 buyer charged without premium taps
   Restore after step 4.
2. Create an In-App Purchase key in App Store Connect (Users and Access →
   Integrations); note key ID and issuer ID; find the app's numeric Apple ID.
   `firebase functions:secrets:set` for the four new secrets.
3. Deploy `firestore.rules`; enable TTL on `lookupQuota.expiresAt` (and on
   `rateLimits.expiresAt` if not already on); set up both spend alerts
   (Perplexity console and a GCP budget).
4. Deploy `validateAppStoreReceipt` only. Safe for 1.0.1 and 1.0.2; lookups
   are unchanged. TestFlight sandbox subscribers tap Restore once to create
   their entitlement doc.
5. Verify a sandbox purchase on a TestFlight build of 1.0.2 (entitlement doc
   created).
6. Submit 1.0.2 for review with "Manually release this version".
7. Once approved, deploy `getMultipleCarbCounts` and immediately run the
   TestFlight quota checks (about 15 minutes). From here, live 1.0.1 free
   users are capped server-side at 4 (their client already stops at 4).
8. Release 1.0.2.

The receipt function goes first so App Review's purchase works; the quota
function goes last and right before release, so 1.0.1 users see the server
limit for as short a time as possible and 1.0.2 never runs without a server
limit.

## Testing

- **Functions** — `node:test` (built into Node 22; no new test deps),
  `npm test` in `functions/`:
  - `dayKey`: offset clamp, invalid input, local-midnight edges, DST offsets.
  - `evaluateEntitlement`: active, expired → refresh, 6 h / 15 min backoff,
    72 h fail-open window, revoked.
  - `applyReservation`: new day resets, under limit, at limit.
  - Handler tests with injected fakes: reserve happens before `lookupFoods`;
    release only on an unbilled failure; premium skips the quota;
    daily-quota error details.
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

- A modified client can shift its day key forward once for up to ~3× the
  limit on one day; afterwards 4/day.
- A leaked JWS grants premium to other UIDs while that subscription is active.
- Sandbox transactions are accepted in production (TestFlight testers).
- Reinstalling can produce a new anonymous UID with a fresh daily quota.
- Scripted anonymous-account minting still gets 4 free lookups per new account
  until App Check; add a Perplexity spend alert.
