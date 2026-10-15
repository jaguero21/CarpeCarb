# Source Tags and Lookup Progress — Design

**Date:** 2026-10-14
**Release:** 1.0.5
**Status:** Approved in conversation; awaiting spec review
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
3. `item.details` starts with `USDA FoodData Central` → `usda`. Server lookups write this
   prefix (see `functions/src/lookup.js` `usdaItem`).
4. `item.details` starts with `Web source, not USDA.` → `web`. The server's `WEB_PREFIX` writes this.
5. Otherwise → `null`, and the row shows no tag. This covers foods looked up before the USDA
   chain existed and Siri foods from before 1.0.4.

A food re-logged from a chip or the saved list keeps its manual flag, serving and details, so it
keeps its original source.

### On the row

- **The pill** sits at the start of the row's subtitle, before the time:
  **[USDA]** 7:45 AM · 1 cup (245 g). It is inline with the text (a `WidgetSpan` in a `Text.rich`),
  so it wraps with the line at large text sizes.
- **Label text:** `USDA`, `Web` or `Manual`, at 10 pt, weight 600, with letter spacing 0.3 and
  rounded corners (radius 4).
- **Colors:** the background is the color at 15% opacity, and the text is the color itself. The
  same pairs are used in dark mode.
  - USDA: `AppColors.sage`.
  - Web: `AppColors.honey`.
  - Manual: `colorScheme.onSurfaceVariant`.
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
  - A status line appears under the button, in 13 pt `onSurfaceVariant`, centered. Its text
    comes from `lookupProgressMessage(elapsed)`:

    | elapsed | message |
    |---|---|
    | < 5 s | Checking nutrition sources… |
    | 5–12 s | Still checking — some foods need a second source |
    | 12–20 s | Almost there… |
    | ≥ 20 s | Taking longer than usual… |
- **Timing:** the elapsed time is measured from when the lookup starts. A 1-second
  `Timer.periodic` rebuilds the line. It is cancelled when the lookup ends (success, not-found
  hand-off, daily-limit, or error) and in `dispose()`.
- **When the lookup ends,** the status line disappears.
- **Accessibility:** the status line is `Semantics(liveRegion: true)`, so VoiceOver reads each new
  message. That is four at most.
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
- `lib/utils/lookup_progress.dart`: `String lookupProgressMessage(Duration elapsed)`.
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
  - Each details prefix decides when there is no serving.
  - Unknown details or no details give `null`.
- `lookupProgressMessage`: each threshold, both sides of 5, 12 and 20 s.
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

Device check before release:
- Pills in light and dark mode and at large text sizes.
- Progress text during a real lookup.
- VoiceOver reads the source and the progress changes.
