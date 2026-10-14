# Rating Prompt — Design

**Date:** 2026-10-14
**Release:** 1.0.4
**Status:** Approved; implemented on feat/rating-prompt

## Problem

CarpeCarb has no App Store ratings, and the app never asks for one.

## Decisions

1. **Automatic prompt** after the 5th successful lookup, using Apple's own
   review popup (`SKStoreReviewController` / `AppStore.requestReview`).
2. **A "Rate CarpeCarb" link in Settings** that opens the App Store's review
   page, which always works, even after Apple's yearly limit is used up.
3. **Package:** `in_app_review` for the popup. The Settings link uses
   `url_launcher`, which the app already depends on.

## When the prompt is requested

A lookup **counts** when the user types a food in the app, the lookup
succeeds, and at least one food is logged with a carb value
(`_applyLookupResult` with a non-empty `items` list).

These don't count:
- A failed lookup (any error, including the daily limit).
- A lookup that logged nothing, because every food went to Manual entry.
- Siri lookups, relogging a saved food, and Manual entry.

Rule (`shouldAsk`):
- **First ask:** the counted lookups reach 5, and the app has never asked.
- **Later asks:** at least 120 days since the last ask, **and** at least 5
  counted lookups since then.

Counting is separate from asking. A counted lookup always counts, but the popup
is requested only when the moment fits:
- The lookup sent nothing to Manual entry (`result.unknownCarbs` is empty).
  Otherwise the popup would land on top of the Manual entry the user was just
  sent to.
- After the 1 second delay, the screen is still mounted and the app is in the
  foreground (or its lifecycle state isn't known yet). Otherwise the user
  couldn't see the popup.

The ask is recorded (count reset to 0, `lastAskedAt` saved) only when the popup
is actually requested. A skipped ask isn't used up: the count stays at 5 or
more, so the next lookup that fits asks.

Apple also limits the popup to 3 times in 365 days per person, and may choose
not to show it. The app can't tell whether it was shown, so "asked" means "the
app requested it".

Timing: the request is made about 1 second after the new food is inserted into
the list, so the popup doesn't cover the result. A request failure is ignored:
it never shows an error and never affects logging.

## Storage

These are device-local `SharedPreferences` keys, added to `StorageKeys`, and
not synced through iCloud:
- `ratingLookupCount` (int): counted lookups since the last ask (or since
  install, before the first ask). Reset to 0 only when the app asks, never
  when an ask is skipped.
- `ratingLastAskedAt` (string, ISO-8601 UTC): when the app last asked; absent
  if it never asked.

With these keys, the rule is: ask when `count >= 5` and (`lastAskedAt` is
null, or `now - lastAskedAt >= 120 days`).

## Settings

There is a "Rate CarpeCarb" text button in the Settings footer, above "Learn
more at carpecarb.app", styled the same way. It opens
`https://apps.apple.com/app/id6759311106?action=write-review` with
`LaunchMode.externalApplication`. Tapping it doesn't change the prompt's
counters. VoiceOver reads it as a button, "Rate CarpeCarb on the App Store".
Both footer links are at least 44 pt tall, so each is a comfortable tap target
and they don't crowd each other.

## Code

- `lib/services/rating_prompt.dart`:
  - `bool shouldAsk({required int count, DateTime? lastAskedAt, required DateTime now})`
    is pure, with the constants `askAfterLookups = 5` and
    `minDaysBetweenAsks = 120`.
  - The `RatingPrompt` class reads `SharedPreferences` (mocked in tests with
    `setMockInitialValues`) and holds an `InAppReview`, injectable for tests.
    Two methods split counting from asking:
    - `Future<bool> recordLookup(DateTime now)` increments the count, saves it,
      and returns whether `shouldAsk` is true. It never resets anything.
    - `Future<void> ask(DateTime now)` resets the count to 0, saves
      `lastAskedAt` in UTC, and calls `requestReview()`.
    The caller decides whether the moment fits, waits the delay, and only then
    calls `ask`.
  - The Settings link lives on the `RatingPrompt` class too: the method
    `Future<void> openStoreReview()` and a constant holding the review URL.
- `lib/main.dart`: `_applyLookupResult`'s success branch calls
  `_maybeAskForRating(askNow: result.unknownCarbs.isEmpty)` without awaiting
  it. It calls `recordLookup`, and when that says to ask and `askNow` is true,
  waits `RatingPrompt.askDelay`, checks that the screen is mounted and the app
  is in the foreground, and calls `ask`. Any error is swallowed.
- `lib/screens/settings_page.dart`: the link.
- `lib/config/storage_keys.dart`: the two keys.

## Out of scope

- A custom "Enjoying CarpeCarb?" pre-prompt (Apple discourages these).
- Prompting from Siri, widgets or other devices.
- Tracking whether the user actually rated.

## Testing

Unit tests (`test/rating_prompt_test.dart`):
- `shouldAsk`:
  - false at count 4 and true at 5 when the app has never asked.
  - At count 5, false at 119 days after the last ask and true at 120.
  - False at count 4 even long after the last ask.
- `recordLookup`:
  - Returns false for the first four calls and true on the 5th.
  - Keeps returning true on a 6th call when `ask` wasn't called (the skipped
    ask case), and saves the count without touching `lastAskedAt`.
- `ask`:
  - Resets the count to 0, saves the time in UTC (even when given a local
    time), and calls `requestReview` once.
  - Five more lookups on the same day return false.
  - After 120 days and 5 more lookups, the 5th returns true.
  - Lookups made during the 120-day wait still count: 5 lookups and an ask,
    then 7 lookups on day 10, then the first lookup on day 120 returns true.
- `requestReview` and `openStoreReview`: ask StoreKit when available, skip when
  unavailable, open the review URL, and swallow failures.

Widget tests (`test/rating_prompt_home_test.dart`). These use a
`_RecordingPrompt` subclass of `RatingPrompt` that counts `requestReview` calls
instead of calling StoreKit. A failed lookup never reaches
`_applyLookupResult`, so it has no widget test.
- Five lookups that log food lead to exactly one request; four lead to none.
- A lookup that logged nothing (every food went to Manual entry) doesn't count.
- A 5th lookup that logs food but also sends a food to Manual entry counts but
  makes no request; the next clean lookup makes one.
- A 5th lookup whose delay runs out while the app is in the background makes
  no request; after the app resumes, the next clean lookup makes one.
- The request comes 1 second after the food appears: none at 999 ms, one at
  1000 ms.

Widget tests (`test/rating_link_test.dart`):
- The "Rate CarpeCarb" link launches the review URL (through
  `RatingPrompt.launcher`), and its semantics are a button with a tap action.
- Both footer links are at least 44 pt tall.

Device check before release: in an Xcode debug build, Apple's popup appears
on the 5th counted lookup (development builds always show it; TestFlight builds
never do, so check with Xcode).
