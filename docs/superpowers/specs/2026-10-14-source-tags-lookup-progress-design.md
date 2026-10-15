# Source Tags and Lookup Progress — Design

**Date:** 2026-10-14
**Release:** 1.0.5
**Status:** Approved; implemented on `feat/source-tags`
**Branch:** `feat/source-tags`, stacked on `feat/meal-sections` (PR #62)

This is round B of the UX roadmap (items 3 and 4).
- Round A (meal sections and one-tap re-log) is PR #62.
- Round C will cover: dropping the Auto/Manual switch, editing a food's time and meal, and
  first-run examples.
- Round D will cover: Settings tab labels and moving Reset.

## Problems

1. Someone deciding an insulin dose can't see from the row how much to trust a number. The
   details dialog says where it came from, but only after a tap.
2. A lookup takes about 3.5–9.5 seconds, up to the server's 25-second budget. During that
   time the only feedback is a small spinner on the Add Food button.

## Decisions

1. **Tag every food whose source is known:** USDA, Web, or Manual. A food whose source can't be
   told gets no tag; nothing is guessed.
2. **Progress uses honest, time-based messages.** The app makes one request and gets one
   answer, so it can't see the server's steps, and the messages never name one.

## Source tags

### Deciding a food's source

`FoodSource? foodSourceOf(FoodItem item)` returns the first of these that applies:
1. `item.isManualEntry` → `FoodSource.manual`.
2. `item.serving?.source == 'usda'` → `usda`, and `== 'web'` → `web`. This covers foods
   logged since 1.0.4 from the app or Siri.
3. `item.details` matches the server's exact USDA format → `usda`. `usdaItem` in
   `functions/src/lookup.js` writes `USDA FoodData Central (<dataType>): …`, with dataType from the
   closed list `DATA_TYPES` in `functions/src/usda.js` (`Survey (FNDDS)`, `SR Legacy`, `Foundation`,
   `Branded`). The app matches
   `^USDA FoodData Central \((?:Survey \(FNDDS\)|SR Legacy|Foundation|Branded)\): `. A looser
   prefix would tag a number that didn't come from the USDA calculation, because an AI answer, an
   older saved food or a result from the server's web-only kill-switch path can also begin
   `USDA FoodData Central`. Those get no tag. Rules 1 and 2 still come first, so a web serving or a
   manual entry keeps its own tag even when its details are in the USDA format.
4. `item.details` starts with `Web source, not USDA.` → `web`. The server's `WEB_PREFIX` writes this.
5. Otherwise → `null`, and the row shows no tag. This covers foods looked up before the USDA
   chain existed and Siri foods from before 1.0.4.

A food re-logged from a chip or the saved list keeps its manual flag, serving and details, so it
keeps its original source.

### On the row

- **The pill** sits at the start of the row's subtitle, before the time:
  **[USDA]** 7:45 AM · 1 cup (245 g). It is inline with the text (a `WidgetSpan` in a `Text.rich`),
  so it wraps with the line at large text sizes. The pill is wrapped in
  `MediaQuery.withNoTextScaling` inside the `WidgetSpan`, because the span already scales its child
  with the text and the pill would otherwise scale twice.
- **Label text:** `USDA`, `Web` or `Manual`, at 10 pt, weight 600, with letter spacing 0.3 and
  rounded corners (radius 4).
- **Colors:** each pill is tinted from one base color.
  - **Base colors:**
    - USDA: `AppColors.sage`.
    - Web: `AppColors.honey`.
    - Manual: `colorScheme.onSurfaceVariant`.
  - **Background:** the base color at 15% opacity.
  - **Text:** the base color darkened in light mode (`Color.lerp(base, Colors.black, 0.45)`) and
    lightened in dark mode (`Color.lerp(base, Colors.white, 0.35)`). Sage and honey as they are
    fall below a 4.5:1 contrast ratio at 10 pt.
  - **Contrast requirement:** at least 4.5:1 against the pill's background over the card. A unit
    test checks this using the relative-luminance formula.
- **Accessibility:** the row's VoiceOver label gains the source after the carbs. The pill itself
  has no separate VoiceOver node, because the row already excludes its children. For example:
  - "Pho, 41.2 grams of carbs, from USDA, 1 cup, logged 12:05 PM"
  - "Latte, 14 grams of carbs, from the web, logged 8:10 AM"
  - "Toast, 15 grams of carbs, entered manually, logged 7:45 AM"
  - With no source, the label is unchanged.

### Not tagged

The saved-foods list in Settings, the quick-add chips, the details dialog (its text already
names the source) and History.

## Lookup progress

- **While `isLoading`:**
  - The Add Food button shows the spinner followed by the text **"Looking up…"** in the
    button's white label style.
  - A status line appears under the button, in 13 pt, centered. Its colour is
    `lookupStatusColor(dark:)` (see Status line colour). Its text comes from
    `lookupProgressMessage(elapsed)`:

    | elapsed | message |
    |---|---|
    | < 5 s | Checking nutrition sources… |
    | 5–12 s | Still checking — some foods take longer |
    | 12–20 s | Still working on it… |
    | ≥ 20 s | Taking longer than usual… |
- **One lookup at a time:** `_addFood` starts with `if (isLoading) return;`. Return in the food
  field and the keyboard toolbar's Add reach `_addFood` without the Add button, which was the only
  thing that checked, so a second lookup could start and both results were logged. A duplicate
  lookup would log the same carbs twice.
- **Timing:** the elapsed time is measured from when the lookup starts. A 1-second
  `Timer.periodic` rebuilds the line, setting the seconds to `timer.tick` rather than counting
  callbacks. A periodic timer skips the ticks it missed after backgrounding or jank without calling
  back, but `tick` still counts the real seconds that passed.
- **Stopping the ticker:**
  - The result path (`_applyLookupResult`) and the error and daily-limit paths stop the ticker as
    soon as they know the lookup is over, so the status line stops changing before the result is
    saved.
  - `_addFood` keeps its own ticker in a local variable (`final ticker = _lookupTicker;`), and its
    `finally` stops the ticker only if `identical(_lookupTicker, ticker)`. The button is free again
    while the result is still being saved, so the user can start another lookup before the first
    one's `finally` runs. Without the check, the late `finally` would stop the newer lookup's
    ticker.
  - `dispose()` cancels it too.
- **Test hook:** `@visibleForTesting bool get lookupTickerActive` reports whether the ticker is
  running. The status line is hidden once a lookup ends, so time passing can't show that the ticker
  stopped.
- **When the lookup ends,** the status line disappears.
- **Accessibility:** the status line is `Semantics(liveRegion: true)`, so VoiceOver reads each new
  message. That is four at most.
- **Status line colour:** `Color lookupStatusColor({required bool dark})` in
  `lib/utils/lookup_progress.dart`. The input card is white in light mode and `AppColors.darkSurface`
  in dark mode.
  - **Light:** `Color.lerp(AppColors.muted, Colors.black, 0.25)`, about 6.3:1 on white. The theme's
    `onSurfaceVariant` (`AppColors.muted`, #8A7D74) is only 3.99:1 on white, below the 4.5:1 that
    13 pt text needs.
  - **Dark:** `AppColors.darkMuted`, which already passes at 5.02:1 on the dark card.
- **Siri and the server are unchanged.**

## Code

- `lib/models/food_source.dart`:
  - `enum FoodSource { usda, web, manual }`, with `label` (`USDA`/`Web`/`Manual`) and `spoken`
    (`from USDA` / `from the web` / `entered manually`).
  - `FoodSource? foodSourceOf(FoodItem item)`.
- `lib/widgets/source_tag.dart`: `SourceTag(FoodSource source)`, which draws the pill.
- `lib/widgets/food_item_card.dart`: an optional `FoodSource? source`. When it is set, the subtitle
  becomes `Text.rich([WidgetSpan(SourceTag), TextSpan(' '), TextSpan(subtitle)])`.
- `lib/utils/a11y_labels.dart`: `foodRowLabel` gains an optional `String? source` (the spoken form),
  placed after the carbs.
- `lib/utils/lookup_progress.dart`: `String lookupProgressMessage(Duration elapsed)` and
  `Color lookupStatusColor({required bool dark})`.
- `lib/main.dart`:
  - `_buildFoodTile` passes the source to the card and to the label.
  - The lookup gets a start time, a ticker timer, and the button and status line UI.
  - A `@visibleForTesting` setter swaps the lookup service for a fake (`_perplexityService`
    becomes non-final).

## Testing

Unit tests:
- `foodSourceOf`:
  - The manual flag wins, even over a USDA serving.
  - A serving with `usda` or `web` decides.
  - Details decide when there is no serving, but only in the server's exact format: each of the four
    data types gives `usda`, and `USDA FoodData Central: …` (no data type), an unknown data type,
    `USDA, 1 medium apple` and `USDA slice` give `null`. The `Web source, not USDA.` prefix gives
    `web`.
  - Precedence: a web serving stays `web`, and a manual entry stays `manual`, even with details in
    the USDA format.
  - Unknown details or no details give `null`.
- `lookupProgressMessage`: each threshold, both sides of 5, 12 and 20 s.
- The tag text colors meet 4.5:1 against the tinted pill background on the card color, in light and
  dark mode.
- The status line colour meets 4.5:1 against the input card (white, and `AppColors.darkSurface`),
  in light and dark mode. The luminance and contrast helpers are shared in
  `test/helpers/contrast.dart`.
- `foodRowLabel`: with and without a source.

Widget tests:
- Rows show the right pill (USDA, Web, Manual) and none for an unknown source, and the VoiceOver
  label includes the spoken source.
- A fake slow lookup:
  - shows "Looking up…" and "Checking nutrition sources…";
  - after pumping 5, 12 and 20 s, shows each later message;
  - when the result arrives, the status line is gone and no timer is pending.
- A lookup that fails clears the status line too.
- The status line is a live region.
- A second lookup is ignored while one is running: with the slow fake in flight, Return in the food
  field starts nothing, and after the first result there is one logged food and one call to
  `getMultipleCarbCounts`.
- A lookup that ends late doesn't stop the next lookup's ticker: the first lookup is held in its
  widget update (after the button is free), a second is started, and the first is released. The
  second's ticker must still be running.
- `timer.tick` counting has no test of its own. Fake async fires every periodic tick, so a single
  large `pump` shows the same message with or without it; the threshold tests above cover the
  messages.

Device check before release:
- Pills in light and dark mode and at large text sizes.
- The Today header at 200% text size, with and without a lookup running.
- Progress text during a real lookup, and that the status line disappearing when the lookup ends
  doesn't make the page jump badly.
- VoiceOver reads the source and the progress changes.
