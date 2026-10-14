# Rating Prompt — Design

**Date:** 2026-10-14
**Release:** 1.0.4
**Status:** Approved in conversation; awaiting spec review

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

Apple also limits the popup to 3 times in 365 days per person, and may choose
not to show it. The app can't tell whether it was shown, so "asked" means "the
app requested it".

Timing: the request is made about 1 second after the new food is inserted into
the list, so the popup doesn't cover the result. It is skipped if the screen is
no longer mounted. A request failure is ignored: it never shows an error and
never affects logging.

## Storage

These are device-local `SharedPreferences` keys, added to `StorageKeys`, and
not synced through iCloud:
- `ratingLookupCount` (int): counted lookups since the last ask (or since
  install, before the first ask). Reset to 0 when the app asks.
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

## Code

- `lib/services/rating_prompt.dart`:
  - `bool shouldAsk({required int count, DateTime? lastAskedAt, required DateTime now})`
    is pure, with the constants `askAfterLookups = 5` and
    `minDaysBetweenAsks = 120`.
  - The `RatingPrompt` class reads `SharedPreferences` (mocked in tests with
    `setMockInitialValues`) and holds an `InAppReview`, injectable for tests. Its method
    `Future<bool> recordLookupAndMaybeAsk(DateTime now)` increments the count,
    and when `shouldAsk` is true, records the ask (resets the count and saves
    `lastAskedAt`) and returns true. The caller then waits the delay and calls
    `requestReview()` on the `RatingPrompt` class.
  - The Settings link lives on the `RatingPrompt` class too: the method
    `Future<void> openStoreReview()` and a constant holding the review URL.
- `lib/main.dart`: one call in `_applyLookupResult`'s success branch.
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
- `recordLookupAndMaybeAsk`:
  - Increments the count, and returns true on the 5th call.
  - After asking, the count is 0 and `lastAskedAt` is saved in UTC.
  - Five more calls on the same day return false.

Widget tests:
- Five successful lookups lead to exactly one review request (stubbed
  `in_app_review` channel); four lead to none.
- A failed lookup and an all-unknown lookup don't count.
- Settings: the "Rate CarpeCarb" link launches the review URL (stubbed
  `url_launcher`).

Device check before release: in an Xcode debug build, Apple's popup appears
on the 5th counted lookup (development builds always show it; TestFlight builds
never do, so check with Xcode).
