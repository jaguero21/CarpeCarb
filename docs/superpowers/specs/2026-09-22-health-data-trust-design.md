# Health data you can trust (review #10, #12, server logging) — design

Date: 2026-09-22 · Status: approved design, pending implementation plan

## Problem

From the 2026-09-18 code review, re-checked against the code at `1cc4cc8`:

- **#12 A missing carb value becomes a confident 0 g.** The server maps it with
  `parseNum(item.carbs) ?? 0` (`functions/src/perplexity.js:224`), the Dart client
  with `double.tryParse(...) ?? 0.0` (`lib/services/lookup_api.dart:48-51`), and
  Siri with `number(raw["carbs"]) ?? 0`
  (`ios/CarbShared/Sources/CarbShared/PerplexityClient.swift:119`). The prompt
  tells the model it must "never refuse or return empty results"
  (`perplexity.js:97`), which pushes it to invent a number rather than admit it
  has none. Lookup results go straight into today's list and on to Apple Health
  with no confirmation step (`lib/main.dart:504`, `_addFood`), so the zero is
  counted before the user sees it. For someone dosing insulin, a confident 0 g
  is worse than an error.
- **#10 Deleting one food removes its neighbours from Health.**
  `deleteFoodItem` deletes this app's food correlations whose start falls in
  `[loggedAt, loggedAt + 1 min]` (`lib/services/health_kit_service.dart:78-91`).
  Foods from one lookup are created in a loop and start within the same minute,
  so deleting the earlier one takes the later ones with it, along with anything
  else logged in the next minute. Siri is worse: it stamps every food in an
  utterance with the same whole second
  (`ios/CarbShared/Sources/CarbShared/CarbDataStore.swift:128`,
  `ISO8601DateFormatter` without fractional seconds).
- **Health-related text in Cloud Logging.** `perplexity.js` logs the user's food
  text on every lookup (`:56`) and the model's output on success and on each
  failure path (`:174`, `:182`, `:195`, `:207`, `:237`).

## Facts the design relies on

- The `health` plugin (13.3.2) maps `NUTRITION` to HealthKit's food correlation
  (`HealthPlugin.swift:467`). Its range delete filters with `.strictStartDate`
  and only this app's own objects (`HealthDataOperations.swift:222-225`), so the
  window only needs to match an entry's *start*.
- On iOS the plugin ignores `clientRecordId` on `writeMeal` and has no
  `deleteByClientRecordId`. `deleteByUUID` exists, but finding a UUID needs
  Health *read* access, which HealthKit hides when it's denied.
- Only today's foods can be deleted (`removeItem` and `_resetTotal` are the only
  callers of `_deleteFromHealthKit`, `lib/main.dart:739`, `:773`).
- Lookups are charged by reserving one before calling Perplexity and refunding
  only if Perplexity didn't bill the call (`functions/src/handlers.js:36-62`).
- Times are shown to the minute (`lib/utils/date_format.dart`, `formatTime`).

## Scope

In: #12 across server, app and Siri; #10; removing health-related text from
server logs.

Out: #11 (purchase lock), #14 (accessibility), the remaining cleanup items, and
an edit-a-logged-food feature (logged foods stay immutable).

## Part 1 — unknown carbs (#12)

**Contract with the model.** The prompt drops "never refuse or return empty
results" and says instead: if there's no reliable carbohydrate value for a food,
still return the food with `"carbs": null` and give the reason in `details`;
never estimate a number that can't be sourced. A real zero (water, black coffee)
stays `0` — only a missing value means "unknown".

**Server parsing.** `parseNum` returns `null` for a missing, non-numeric,
negative or non-finite value, and the `?? 0` default is removed.

**Old clients.** Current app builds and current Siri turn `null` into `0`, and
they stay on phones after the server deploys. With the model now allowed to say
"unknown", they would show 0 g *more* often than today. So new clients send
`acceptsUnknownCarbs: true` in the request body, next to `tzOffsetMinutes`
(`lib/services/perplexity_firebase_service.dart:57`,
`PerplexityClient.swift:82`). With the flag, every food comes back, unknown
ones with `carbs: null` — including a lookup where nothing was found, which
returns an all-`null` list rather than an error, so the app can hand the names
to Manual entry. Without the flag the server drops foods with unknown carbs; if
none remain it throws `HttpsError("not-found", "Couldn't find carbs for
fries.")`, naming every dropped food — an error, never a fabricated zero.

**Charging.** Unchanged. A call Perplexity billed counts toward the free
limit even when nothing usable came back — including the old-client
`not-found` error above, which is not one of the unbilled errors. Refunding lookups that found nothing
would make deliberately unfindable input a free, unlimited Perplexity call,
reopening #1.

**Dart client.** A lookup returns the foods it found plus the names of foods it
couldn't find carbs for. `FoodItem.carbs` stays non-nullable, so nothing
downstream can hold an unknown value.

**App.** Found foods log exactly as today. Unknown foods are not logged. A
snackbar says "Couldn't find carbs for fries — enter it manually." and the app
switches to Manual entry with the name filled in and the carb field focused.
With several unknown foods the message names them all and fills in the first.
If nothing was found, nothing is logged and the same hand-off happens.

**Siri.** Logs the foods it found and appends "I couldn't find carbs for fries,
so I didn't log it." If it found nothing, it keeps the existing reply, "I
couldn't find nutrition info for that."

## Part 2 — deleting from Health (#10)

**Distinct start times.** Every Health entry the app writes starts in its own
millisecond:

- Foods from one lookup are stamped 1 ms apart when the result is built.
- Siri stamps the foods of one utterance 1 ms apart and writes `loggedAt` with
  fractional seconds. The spacing lives in `CarbShared` so `swift test` covers
  it; `LogFoodIntent` (Runner target) only calls it.
- Single adds (Manual, a saved food) are already distinct.

The spacing never shows, since times are displayed to the minute.

**Exact delete.** `deleteFoodItem` deletes the window
`[loggedAt, loggedAt + 1 ms)`. With `.strictStartDate` and distinct starts, that
matches exactly one entry. Write and delete both go through the plugin's
millisecond conversion, so they round the same way. No Health read access is
needed, so users who granted write-only access keep working deletes.

**Known limit.** Entries written by the old build on update day can still take
a sibling from the same lookup if they share a millisecond. After that day it
can't happen, because only today's foods can be deleted.

## Part 3 — logging, rollout

**Logging.** The server logs metadata only: input length, item count, how many
came back unknown, attempt number, `finish_reason`, HTTP status. No food text
and no model output, including on parse failures, which log the error message
and the output's length. What is already in Cloud Logging ages out with the log
bucket's retention; purging it sooner is a manual ops step, not part of this
change.

**Rollout.** Either deploy order is safe because of the flag. New app with old
server: the server never returns `null`, which is today's behaviour. Old app
with new server: unknown foods are dropped or the lookup errors. Deploy the
functions as soon as this merges, so old builds are protected before the App
Store release reaches them.

## Testing

- **Server** (`functions/test/perplexity.test.js`, `node --test`): with the
  flag an unknown food comes back as `null`; without it unknown foods are
  dropped, and a lookup with nothing left fails; negative and NaN become
  `null`; a real `0` stays `0`; a console spy proves no log line contains the
  input or the model output.
- **Dart:** parsing splits found from unknown foods; a widget test where one
  food is found and one isn't logs the found one and switches to Manual with the
  unknown name filled in; all unknown logs nothing; foods from one batch get
  distinct millisecond times; the delete window is a pure function with its own
  test.
- **Swift** (`swift test`): `parseResponse` puts `null` carbs in the unknown
  list; Siri's reply names a skipped food; timestamps keep fractional seconds;
  the per-food 1 ms spacing.
- **By hand, on a device:** delete one food out of "burger and fries", typed and
  via Siri — only that one leaves Health; look up something obscure — the Manual
  hand-off appears; with write-only Health access, deleting still works.
