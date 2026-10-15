# Meal Sections and One-Tap Re-log — Design

**Date:** 2026-10-14
**Release:** 1.0.5
**Status:** Approved; implemented on feat/meal-sections
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

1. **Group by eating occasion.** Sections use each food's saved `FoodCategory` (breakfast, lunch,
   dinner, snack, drink), set from the time it was logged by `FoodCategory.fromTime`, which this
   round doesn't change. A section ends whenever the meal changes from the previous food, because
   one category can cover two occasions (Snack is both 15:00–17:00 and 21:00–05:00). Fixing a wrong
   meal comes in round C (item 6).
2. **Chips show saved foods, then recent ones.**
3. **Tapping a chip logs the food immediately**, with Undo.
4. **Today is built as plain sections**, not an `AnimatedList`, so nothing has to be kept in step
   by index.

## Meal sections

- Today's foods are sorted newest first and split into sections. Each section renders as a header
  followed by its food rows.
- **A new section starts whenever the meal changes from the previous food.** Consecutive foods
  with the same meal stay in one section. So breakfast, lunch, then breakfast again gives three
  sections, and an afternoon snack and a bedtime snack, with lunch or dinner between them, give
  two separate Snack sections, each with its own total.
- **Header:** the meal's icon and color (`FoodCategory.icon`/`.color`) and its label on the left,
  and its carb total on the right (e.g. "Lunch … 52.0 g"). The total is the sum of the section's
  `carbs`, shown with one decimal like the rest of the app.
  - The header has the same 16 pt side padding as the food cards, so the total ends where the
    rows' carb numbers do.
  - The meal name takes all the free space on one line and is cut off with an ellipsis, so a long
    name or large text never pushes the total out of view.
- **Order:**
  - Sections are in time order, newest first, so dinner is on top in the evening.
  - Within a section, foods are ordered newest first.
  - Ties are broken by keeping the current order of `foodItems`.
- **Only occasions that have food appear.** A section with one food still has a header.
- **Accessibility:** the header is a heading, read as "Lunch, 52.0 grams of carbs, 2 foods"
  ("1 food" for one), using `spokenGrams`. Food rows keep their labels.
- **No change** to the daily total card, the macro strip, the widget, Apple Health, iCloud or
  the stored data.

### Rendering

`foodItems` stays the single source of truth. The sections are computed from it on every
build. The `AnimatedList` and its `_listKey` are removed, and every place that calls
`_listKey.currentState?.insertItem/removeItem` just updates `foodItems` inside `setState`.
- **Rows are keyed by food id, and headers by their section's oldest food** (`MealSection.id`),
  which stays the same as newer foods join the section. Swipe-to-delete (`Dismissible`) and
  swipe-to-save keep their current behavior. Deleting addresses the food by id, not by list
  index.
- **A newly added food's row fades and grows in (400 ms).** Rows already there when the
  screen first loads, or after a day rollover or iCloud merge, don't animate.
- **Removal:** a swiped row animates out as it does today. A row removed any other way
  (details → Delete, Reset, iCloud merge) disappears, and the rows below close up with a
  short size animation.
- Delete **Undo** puts the food back into `foodItems`. Its section and position follow from
  its `loggedAt`, so no index is needed. If an iCloud merge has already brought the food back,
  Undo does nothing, so there is never a second copy.

## One-tap re-log

### The chip row

- A single horizontally scrolling row of chips sits directly under the food field, in both Auto
  and Manual modes. It is hidden when there are no chips.
- **Order:** every saved food first, in the saved-foods list's order. Then up to 8 recent foods,
  newest first, skipping any whose name matches a saved food (case-insensitive, trimmed).
- **Label:** "Banana · 27.0 g", with one decimal like the rest of the app. The name and the
  carbs are separate texts in a row: only the name is cut off with an ellipsis, so the grams are
  always visible. A chip is at most 200 pt wide at the default text size, and that limit grows
  with the text size.
- **Tap:** logs the food now, the same way `_addSavedFood` does today:
  - It gets a new id and `loggedAt = now`, so its meal comes from the current time.
  - It keeps its carbs, macros, details, citations, manual flag and serving.
  - It uses no lookup and no daily quota.
  - It is saved, updates the widget, and writes to Apple Health when Health sync is on.
  - A snackbar reads "Logged Banana · 27.0 g" with **Undo** (4 s).
- **Double tap:** a second tap on the same food's chip within 1 second is ignored, so a
  double tap logs one serving, not two. The food is matched by name (case-insensitive, trimmed),
  and tapping a different chip is never blocked.
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
  food it came from), `lastLoggedAt`, and `quickAdd` (true when the food was logged from a chip
  or the Settings saved-foods list; an entry without the key reads as false).
- **One entry per name** (case-insensitive, trimmed): logging a food again replaces the entry
  with the newest copy, so a changed serving or carbs carries forward.
- **Expiry:** entries older than 30 days by `lastLoggedAt` are dropped when the list is read.
  At most 20 entries are kept, and the oldest are dropped first.
- **Serving edits:** editing a logged food (a serving change keeps its id) updates the entry
  whose `sourceId` is that food's id, so the chip shows the new carbs and macros. It keeps
  `lastLoggedAt`. If there is no such entry (the user removed it, say) nothing is added, so a
  removed recent never comes back.
- **Removal:**
  - "Remove from recents" removes the entry.
  - Deleting a food from Today, by swipe or from its details, removes the entry whose
    `sourceId` is that food's id, because a food deleted the same day was probably a wrong
    lookup. This applies to lookups, manual entries and Siri imports only. A food logged from a
    chip or the saved-foods list is one the user chose on purpose, so deleting it keeps its chip.
  - Undoing that delete doesn't restore the entry. The food is re-recorded only the next time
    it is logged.
  - Reset and day rollover don't touch recents.
- **Recording and saving:** Siri-imported foods are recorded after they have been saved, so
  recording never delays the save.
- **Storage:** device-local `SharedPreferences` key `recent_foods` (`StorageKeys.recentFoods`). It is
  not synced through iCloud, which keeps the sync payload small. Saved foods keep syncing as
  today.

## Code

- `lib/models/meal_sections.dart`: `List<MealSection> mealSections(List<FoodItem> items)`, a pure
  function. `MealSection` has `category`, `items` (newest first), `totalCarbs` and `id` (the id of
  its oldest food).
- `lib/services/recent_foods.dart`: `RecentFoods`, with these methods:
  - `Future<List<FoodItem>> load(DateTime now)` (expired entries dropped, newest first)
  - `Future<void> record(Iterable<FoodItem> items, DateTime now, {bool quickAdd = false})`
  - `Future<void> remove(String name)`
  - `Future<void> removeSource(String foodId)` (skips `quickAdd` entries)
  - `Future<void> updateSource(FoodItem updated)` (a serving edit; never adds an entry)
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
  - the chip row and its tap (with the 1-second per-food cooldown), Undo and remove handlers
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
  - ties keep input order (40 same-time foods, so a missing tiebreak fails)
  - breakfast, lunch, breakfast gives three sections
  - an afternoon and a bedtime snack, with lunch between, give two Snack sections, each with
    its own total
  - consecutive foods of one meal stay in one section
  - `id` is the oldest food's id and stays put as newer foods join
- `quickLogChips`:
  - saved first, then recents
  - recents that match a saved name (case and space differences) are skipped
  - at most 8 recents
  - empty input → empty
- `RecentFoods`:
  - recording replaces an entry with the same name
  - 30-day expiry, at record time and when loading later
  - the 20-entry cap
  - `remove` and `removeSource`
  - `removeSource` keeps a `quickAdd` entry and removes a normal one; the flag comes from the
    newest `record` call; an entry stored without the flag reads as false
  - `updateSource` replaces the food and keeps the entry's place, does nothing without a
    matching entry, and never brings back a removed recent
  - citations and serving survive a record/load round trip
  - order is newest first
  - corrupt JSON loads as empty

Widget tests:
- Sections appear with the right headers and totals.
- An afternoon and a bedtime snack get a header each.
- The meal total lines up with the rows' carb numbers.
- The meal name gets all the free space, and at large text it is cut off with the total in view.
- `AppearOnce` reuses one animation across rebuilds.
- Adding a food updates its section's total, and deleting one does too.
- Deleting a section's last food removes the section.
- Undo of a delete restores the food to the right section, and adds no second copy when a merge
  brought the food back.
- Deleting an id that isn't there changes nothing and shows no snackbar.
- Swipe-to-delete and swipe-to-save still work with id-based rows. Existing tests that relied on
  list indexes are updated.
- Chips:
  - Hidden when empty (checked with `find.byType(QuickLogChips)`).
  - Shown in Manual mode too.
  - Saved foods come before recents.
  - A long name is cut off but never the grams, including at large text.
  - A tap logs the food with no lookup, shows "Logged …" and Undo, and Undo removes it.
  - Undo shows no second "removed" snackbar and takes the food out of Health.
  - A second tap within 1 second is ignored; after 1 second it logs again; a different chip is
    not blocked.
  - Long-press "Remove from recents" removes the chip.
  - Deleting a looked-up food removes its recent chip; deleting a chip-logged food keeps it.
  - Editing a logged food's serving updates its chip.
  - A corrupt saved-foods list doesn't hide the recent chips.
- Recents:
  - A manual entry is remembered.
  - Siri foods are saved before recents are written.
- VoiceOver:
  - header heading and label
  - chip label, button role and custom action
  - logging announcement ("Logged Pho, 41.2 grams of carbs")

Device check before release:
- Sections and totals look right through a day.
- A chip tap logs the food, and it reaches the widget and Apple Health.
- Undo removes it from Health.
- A chip tap followed at once by Undo leaves no Health sample.
- A recent chip with a long name still shows its grams.
- An afternoon snack and a bedtime snack show as two sections.
- Headers look right at large text sizes: the total stays in view and lines up with the rows.
- VoiceOver reads headers and chips.
