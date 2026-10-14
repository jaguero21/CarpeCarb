# Meal Sections and One-Tap Re-log — Design

**Date:** 2026-10-14
**Release:** 1.0.5
**Status:** Approved in conversation; awaiting spec review
**Branch:** `feat/meal-sections`, stacked on `feat/rating-prompt` (PR #61)

This is round A of the UX roadmap. Later rounds:
- B: a source tag on rows, and progress text during a lookup.
- C: drop the Auto/Manual toggle, edit a logged food's time and meal, and show first-run examples.
- D: label the Settings tabs, and move Reset.

## Problems

1. Insulin is dosed per meal, but Today is one flat list under a daily total. To dose for
   lunch, people add up lunch's foods in their head.
2. People eat the same foods again and again. Re-logging one means typing it and waiting for a
   lookup, or opening Settings → Saved foods.

## Decisions

1. **Group by meal label.** Sections use each food's saved `FoodCategory` (breakfast, lunch,
   dinner, snack, drink). This is set from the time it was logged by `FoodCategory.fromTime`,
   which this round doesn't change. Fixing a wrong meal comes in round C (item 6).
2. **Chips show saved foods, then recent ones.**
3. **Tapping a chip logs the food immediately**, with Undo.
4. **Today is built as plain sections**, not an `AnimatedList`, so nothing has to be kept in step
   by index.

## Meal sections

- Today's foods are grouped by `category`. Each group renders as a header followed by its food
  rows.
- **Header:** the meal's icon and color (`FoodCategory.icon`/`.color`) and its label on the left,
  and its carb total on the right, in line with the rows' carbs (e.g. "Lunch … 52.0 g"). The
  total is the sum of the group's `carbs`, shown with one decimal like the rest of the app.
- **Order:**
  - Sections are ordered by their newest food's `loggedAt`, newest first, so dinner is on top
    in the evening.
  - Within a section, foods are ordered newest first.
  - Ties are broken by keeping the current order of `foodItems`.
- **Only meals that have food appear.** A section with one food still has a header.
- **Accessibility:** the header is a heading, read as "Lunch, 52.0 grams of carbs, 2 foods"
  ("1 food" for one), using `spokenGrams`. Food rows keep their labels.
- **No change** to the daily total card, the macro strip, the widget, Apple Health, iCloud or
  the stored data.

### Rendering

`foodItems` stays the single source of truth. The sections are computed from it on every
build. The `AnimatedList` and its `_listKey` are removed, and every place that calls
`_listKey.currentState?.insertItem/removeItem` just updates `foodItems` inside `setState`.
- **Rows are keyed by food id.** Swipe-to-delete (`Dismissible`) and swipe-to-save keep their
  current behavior. Deleting addresses the food by id, not by list index.
- **A newly added food's row fades and grows in (400 ms).** Rows already there when the
  screen first loads, or after a day rollover or iCloud merge, don't animate.
- **Removal:** a swiped row animates out as it does today. A row removed any other way
  (details → Delete, Reset, iCloud merge) disappears, and the rows below close up with a
  short size animation.
- Delete **Undo** puts the food back into `foodItems`. Its section and position follow from
  its `loggedAt`, so no index is needed.

## One-tap re-log

### The chip row

- A single horizontally scrolling row of chips sits directly under the food field, in both Auto
  and Manual modes. It is hidden when there are no chips.
- **Order:** every saved food first, in the saved-foods list's order. Then up to 8 recent foods,
  newest first, skipping any whose name matches a saved food (case-insensitive, trimmed).
- **Label:** "Banana · 27.0 g", with one decimal like the rest of the app. Long names are cut
  off with an ellipsis, and a chip is at most 200 pt wide.
- **Tap:** logs the food now, the same way `_addSavedFood` does today:
  - It gets a new id and `loggedAt = now`, so its meal comes from the current time.
  - It keeps its carbs, macros, details, citations, manual flag and serving.
  - It uses no lookup and no daily quota.
  - It is saved, updates the widget, and writes to Apple Health when Health sync is on.
  - A snackbar reads "Logged Banana · 27.0 g" with **Undo** (4 s).
- **Undo** deletes that food through the normal delete path: a delete marker for iCloud, and
  removal from Apple Health. It shows no second "removed" snackbar.
- **Long-press a recent chip:** a menu with "Remove from recents". Long-pressing a saved chip
  does nothing new: saved foods are managed in Settings as today.
- **Accessibility:**
  - Each chip is a button labelled "Log Banana, 27 grams of carbs" (via `spokenGrams`).
  - A recent chip also has a custom action, "Remove from recents".
  - The row has the label "Quick add".
  - Logging announces "Logged Banana, 27 grams of carbs".

### Recent foods

- **Recorded:** every food that joins Today is recorded, whether from a lookup, Manual entry,
  a Siri import (today's foods only) or a chip tap. A food already logged before this
  version is not recorded until it is logged again.
- **Entry:** the food's data, the same JSON as `FoodItem`, plus `sourceId` (the id of the logged
  food it came from) and `lastLoggedAt`.
- **One entry per name** (case-insensitive, trimmed): logging a food again replaces the entry
  with the newest copy, so a changed serving or carbs carries forward.
- **Expiry:** entries older than 30 days by `lastLoggedAt` are dropped when the list is read.
  At most 20 entries are kept, and the oldest are dropped first.
- **Removal:**
  - "Remove from recents" removes the entry.
  - Deleting a food from Today, by swipe or from its details, removes the entry whose
    `sourceId` is that food's id, because a food deleted the same day was probably a wrong
    lookup.
  - Undoing that delete doesn't restore the entry. The food is re-recorded only the next time
    it is logged.
  - Reset and day rollover don't touch recents.
- **Storage:** device-local `SharedPreferences` key `recent_foods` (`StorageKeys.recentFoods`). It is
  not synced through iCloud, which keeps the sync payload small. Saved foods keep syncing as
  today.

## Code

- `lib/models/meal_sections.dart`: `List<MealSection> mealSections(List<FoodItem> items)`, a pure
  function. `MealSection` has `category`, `items` (newest first) and `totalCarbs`.
- `lib/services/recent_foods.dart`: `RecentFoods`, with these methods:
  - `Future<List<FoodItem>> load(DateTime now)` (expired entries dropped, newest first)
  - `Future<void> record(Iterable<FoodItem> items, DateTime now)`
  - `Future<void> remove(String name)`
  - `Future<void> removeSource(String foodId)`
- `lib/models/quick_log.dart`: `List<QuickLogChip> quickLogChips({required List<FoodItem> saved, required List<FoodItem> recent})`
  is a pure function for ordering, dedupe and the cap of 8. `QuickLogChip` holds the food
  and whether it is a recent (removable) one.
- `lib/widgets/meal_section_header.dart` and `lib/widgets/quick_log_chips.dart`: the header and the
  chip row.
- `lib/utils/a11y_labels.dart`: the header and chip labels.
- `lib/main.dart`:
  - sectioned rendering, and removal of `AnimatedList`/`_listKey`
  - id-based delete
  - recording recents at the four places foods join Today
  - the chip row and its tap, Undo and remove handlers
  - reloading the chips when saved foods or recents change

## Out of scope

- Changing a food's meal, or the time windows (round C, item 6).
- Syncing recents across devices.
- Reordering or pinning chips.
- Re-log from History.

## Testing

Unit tests:
- `mealSections`:
  - grouping, totals (including decimals)
  - section order by newest food
  - food order within a section
  - empty input → no sections
  - ties keep input order
- `quickLogChips`:
  - saved first, then recents
  - recents that match a saved name (case and space differences) are skipped
  - at most 8 recents
  - empty input → empty
- `RecentFoods`:
  - recording replaces an entry with the same name
  - 30-day expiry
  - the 20-entry cap
  - `remove` and `removeSource`
  - order is newest first
  - corrupt JSON loads as empty

Widget tests:
- Sections appear with the right headers and totals.
- Adding a food updates its section's total, and deleting one does too.
- Deleting a section's last food removes the section.
- Undo of a delete restores the food to the right section.
- Swipe-to-delete and swipe-to-save still work with id-based rows. Existing tests that relied on
  list indexes are updated.
- Chips:
  - Hidden when empty.
  - Saved foods come before recents.
  - A tap logs the food with no lookup, shows "Logged …" and Undo, and Undo removes it.
  - Long-press "Remove from recents" removes the chip.
  - Deleting a looked-up food removes its recent chip.
- VoiceOver:
  - header heading and label
  - chip label, button role and custom action
  - logging announcement

Device check before release:
- Sections and totals look right through a day.
- A chip tap logs the food, and it reaches the widget and Apple Health.
- Undo removes it from Health.
- VoiceOver reads headers and chips.
