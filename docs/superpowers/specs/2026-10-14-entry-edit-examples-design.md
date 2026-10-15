# One Food Field, Time and Meal Editing, First-Run Examples — Design

**Date:** 2026-10-14
**Release:** 1.0.5
**Status:** Approved; implemented on feat/entry-and-edit
**Branch:** `feat/entry-and-edit`, stacked on `feat/source-tags` (PR #63)

This is round C of the UX roadmap (items 5, 6 and 7).
- Round A, meal sections and quick-add chips, shipped in PR #62.
- Round B, source tags and lookup progress, is PR #63.
- Round D will label the Settings tabs and move Reset.

## Problems

1. **An extra decision on every entry.** The Auto/Manual switch makes people choose before
   every entry, even though a lookup already switches to Manual by itself when it finds no carbs.
2. **No way to fix a late entry.** A food logged late lands in the meal that matches when it was
   typed. Only its serving can be changed, so a lunch logged at 3:10 PM stays a Snack, and the new
   meal totals are wrong.
3. **New users don't learn to give amounts.** They see "Type a food name above…" and nothing more.
   The amount ("2 slices", "1 cup") is what makes a lookup accurate, but nothing says so.

## Decisions

1. Replace the switch with an **"Enter carbs yourself" link** under the food field.
2. **Edit time and meal in the food's details dialog.** The meal follows the time unless the
   meal was picked by hand, in that edit or an earlier one. Times are limited to today, up to
   now.
3. **Examples appear for new users on an empty day.** That means no foods today and no saved or
   recent foods. Tapping an example fills the field; it never looks anything up by itself.

## 5. One food field

- **The switch goes.** Remove the Auto/Manual switch (`_buildModeToggle` and its row).
  `_isManualEntryMode` stays as internal state.
- **Food field hint:** **"What did you eat?"**, or **"Food name"** while the carbs field is shown.
- **The link** is a `TextButton` under the fields, centered, 14 pt:
  - It reads **"Enter carbs yourself"** and shows the carbs field. The Add button then reads
    "Add", and focus moves to the carbs field if the food field has text, otherwise to the food field.
  - With the carbs field shown, it reads **"Look it up instead"**. That hides the carbs field
    and clears it, and the button goes back to "Add Food".
  - Its text color is `AppColors.sage` darkened with `Color.lerp(sage, Colors.black, 0.45)` in
    light mode and lightened 0.35 toward white in dark mode, the same treatment as the source
    tags. The text must reach at least 4.5:1 on the input card, and a test checks this.
  - Its tap target is at least 44 pt tall, and VoiceOver reads it as a button with its text as
    the label.
- **A lookup that finds no carbs** still opens the carbs field with the name filled in and the
  carbs field focused (`_handOffUnknownCarbs`).
  - Once that food is added, the next entry goes back to lookup: the link reads "Enter carbs
    yourself" and the hint "What did you eat?". `_carbsFieldFromHandoff` is set by the hand-off,
    cleared by the link in either direction, and on a successful manual add it switches back to
    lookup in the same `setState` that inserts the food.
  - A carbs field the user opened with the link stays open after an add.
- **Unchanged:**
  - The keyboard toolbar's Add/Done, `_focusNextHomeInput`, and the in-flight lookup guard.
  - The `isManualEntryEnabled` gate, which stays as it is.
- **Order inside the input card:**
  1. the food field
  2. the carbs field, when shown
  3. the link
  4. the quick-add chips
  5. the Add button
  6. the progress line

## 6. Change a logged food's time and meal

### In the details dialog

- **A new row sits above the serving picker**, and every food gets it, including manual and
  Siri foods.
  - **Time** shows as "Time · 12:05 PM". Tapping it opens Material's `showTimePicker`, starting
    at the draft time.
  - **Meal** is a dropdown with Breakfast, Lunch, Dinner, Snack and Drink, each with its icon.
- **Draft state** extends the existing serving draft to a draft time, a draft meal and a
  `mealPicked` flag:
  - `mealPicked` starts as `item.category != FoodCategory.fromTime(item.loggedAt)`. Every way
    a food is logged sets its meal from its time, so a meal that doesn't match was picked by
    hand already, in an earlier edit or as Drink, and a new time keeps it.
  - Picking a meal sets `mealPicked = true`.
  - Picking a time sets the draft time. Unless `mealPicked` is true, it also sets the draft
    meal to `FoodCategory.fromTime(newTime)`.
- **Allowed times:** today, up to now.
  - `resolvePickedTime(TimeOfDay picked, {required DateTime now, required int resetHour})`
    returns the `DateTime`, or null when the time is outside today:
    1. Build the time on `now`'s calendar date.
    2. If that is after `now`, use the previous calendar date instead.
    3. Valid only if the result is not before `dayStart(now, resetHour)`.
  - `dayStart(now, resetHour)` is the most recent `resetHour`:00 at or before `now`. It is
    built with calendar arithmetic, like `nextDayBoundary`.
  - When the picked time is null, show "Pick a time from today, up to now" inside the dialog,
    under the row, and leave the draft unchanged. A snackbar would sit behind the dialog.
    VoiceOver also hears it, through `SemanticsService.sendAnnouncement`.
  - The error text uses `timeErrorColor(dark:)`: terracotta darkened 25% toward black in light
    mode (5.4:1 on the surface; plain terracotta is 3.3:1 at 12 pt), and terracotta in dark
    mode (4.8:1).
  - A later valid pick clears the error.
  - The handler checks `context.mounted` straight after the picker returns, before any
    `setDialogState`, since the dialog may have closed meanwhile.
- **The Apple Health millisecond rule.** A Health delete takes every sample of this app that
  starts in the food's millisecond (`healthDeleteWindow`), so no two foods may share one.
  Lookups and Siri space their foods 1 ms apart; a moved food must keep that.
  - The picker resolves to a whole minute. When that minute and day (`dayKey`) are the food's
    own, the draft goes back to exactly `item.loggedAt`, so re-picking it shows no Update.
  - Otherwise the food keeps its own sub-minute parts: the resolved minute plus its seconds,
    milliseconds and microseconds, capped at now.
  - A result equal to the current draft changes nothing.
  - At Update, `uniqueMillisecond(time, taken)` (`lib/utils/picked_time.dart`) moves the time
    forward 1 ms at a time while any other food in `foodItems` starts in the same millisecond.
    This is the backstop for two foods whose sub-minute parts happen to match.
- **Changed and Update:** "changed" means the serving, time or meal differs from the logged
  food. **Update** appears only when something changed, and it saves all the changes together.
  - The copy the dialog shows is for display only. Update builds the copy it saves with
    `item.edited(..., now: DateTime.now().toUtc())`, so `updatedAt` is stamped when Update is
    tapped, not when the dialog last drew.
- **Large text:** above 1.3x (`MediaQuery.textScalerOf(context)`), the time button and the meal
  dropdown stack, time first, with the dropdown `isExpanded: true`; a meal name too long for
  the width ends in an ellipsis. Below that they share a row.
- **Live preview:** the dialog shows the draft time and meal.

### What an edit does

- **The edited copy:** `FoodItem.edited({ServingInfo? serving, DateTime? loggedAt, FoodCategory? category, required DateTime now})`
  returns a copy with the given fields replaced.
  - When `serving` is given, the nutrients are recalculated from it, as `withServing` does today.
  - `updatedAt` is set to `now`. Callers pass `DateTime.now().toUtc()`.
  - It keeps `id`, `name`, `details`, `citations` and `isManualEntry`.
  - `withServing` becomes `edited(serving: next, now: now)`.
- **Saving** goes through the existing `_updateFoodItem(old, updated)`, so these all follow
  without new code:
  - **Total, sections, widget and iCloud.** The newer `updatedAt` wins on iCloud.
  - **Apple Health.** `replaceFoodItem` deletes the sample at the old `loggedAt` and writes one
    at the new time.
  - **The quick-add chip.** `RecentFoods.updateSource` updates it.
  - The stale-copy and deleted-food guards.
- **Sections:** the food moves to the section for its new meal and time, because sections are
  computed from `loggedAt` and `category`.
- **Confirmation snackbar:**
  - "Updated to 57.2 g" when the carbs changed.
  - Otherwise, when the time or meal changed, "Moved to Lunch, 1:30 PM" (the meal label and
    the formatted time).
  - Otherwise "Updated", e.g. for a new serving with the same carbs.
  - Only one snackbar is shown.
- **Accessibility:**
  - The Time row is a button labelled "Time, 12:05 PM", with the hint "Double tap to change".
  - The Meal dropdown is labelled "Meal, Lunch", read once: the visible selection is built by
    `selectedItemBuilder` inside `ExcludeSemantics`. The open menu's items keep their own
    semantics.
  - Changing either announces the new value, e.g. "Lunch, 1:30 PM".
  - A refused time is announced: "Pick a time from today, up to now".

## 7. Examples for new users

- **When:** `foodItems` is empty, the quick-add row has finished loading, **and** `_quickChips`
  is empty, so there are no saved and no recent foods. Waiting for the load means someone with
  saved foods never sees the examples flash at launch. Otherwise the empty Today keeps its
  current line.
- **What:** in the empty Today area, show:
  - **"Try something like:"**
  - four example chips, in a wrap:
    - "2 slices pepperoni pizza"
    - "Chipotle chicken burrito bowl"
    - "1 cup cooked white rice"
    - "Grande oat milk latte"
  - a 13 pt line underneath: **"Include how much you had — it makes the carbs more accurate."**
- **Tapping an example:**
  - fills the food field with it
  - switches back to lookup mode if the carbs field was shown
  - focuses the field with the cursor at the end
  - does **not** look anything up and uses no quota
  - does nothing while a lookup is running, since the lookup's result clears the field anyway
- **Accessibility:**
  - Each chip is a button labelled "Use example, 2 slices pepperoni pizza".
  - "Try something like:" is a heading.
- **Chip size:** each chip is at least 44 pt tall, and its colors meet 4.5:1.

## Code

- `lib/utils/day_key.dart`:
  - `DateTime dayStart(DateTime now, int resetHour)`
- `lib/utils/picked_time.dart`:
  - `DateTime? resolvePickedTime(TimeOfDay picked, {required DateTime now, required int resetHour})`.
    It is kept out of `day_key.dart` so that file stays free of Flutter imports.
  - `DateTime uniqueMillisecond(DateTime time, Iterable<DateTime> taken)`.
- `lib/models/food_item.dart`: `FoodItem.edited(...)`, with `withServing` delegating to it.
- `lib/widgets/time_meal_row.dart`:
  - `TimeMealRow({required DateTime time, required FoodCategory meal, required VoidCallback onPickTime, required ValueChanged<FoodCategory> onMealChanged, String? error})`.
    It is a controlled widget. The caller opens the time picker and resolves the time.
  - `Color timeErrorColor({required bool dark})`.
- `lib/widgets/example_prompts.dart`: `ExamplePrompts({required ValueChanged<String> onPick})`, with the
  `const List<String> examplePrompts`.
- `lib/utils/a11y_labels.dart`: `timeRowLabel(String time)`, `mealDropdownLabel(String meal)` and
  `exampleChipLabel(String text)`.
- `lib/main.dart`:
  - the input card, with the link in place of the switch
  - the dialog draft and Update
  - a `@visibleForTesting pickTime` hook, so tests can pick a time without the Material picker
  - the confirmation text
  - the empty state
  - `_carbsFieldFromHandoff`, for the return to lookup after a hand-off add

## Out of scope

- Moving a food to another day, and editing past days (History reads from Apple Health).
- Editing a food's name or carbs directly. Manual foods are deleted and re-added, as today.
- Changing the meal time windows in `FoodCategory.fromTime`.

## Testing

Unit tests:
- `dayStart`: at midnight reset; with `resetHour` 4 before and after 4 AM; agrees with `dayKey`.
- `resolvePickedTime`:
  - an earlier time today
  - a future time (gives null)
  - a time before the day started (gives null)
  - with `resetHour` 4 at 2 AM, picking 11 PM gives yesterday's calendar date
- `uniqueMillisecond`: no clash, one clash, two consecutive clashes.
- `FoodItem.edited`:
  - keeps `id`, `details` and the manual flag
  - sets `updatedAt`
  - changing the time doesn't change carbs
  - a time and meal edit keeps the carbs, all four macros, the serving and the id
  - a serving still recalculates
- The link's contrast, light and dark.
- The time error's contrast on the dialog surface, light and dark, and that the row draws it
  in that colour.
- The VoiceOver labels, with the meal dropdown read exactly "Meal, Lunch" and the open menu
  still reading each meal.
- The time and meal row at 2x text in a 320 pt dialog, for every meal: no overflow.

Widget tests:
- No switch on screen.
- The link shows and hides the carbs field, and both labels and the button text change.
- A not-found lookup still opens the carbs field; after that food is added through the UI, the
  link reads "Enter carbs yourself" and the hint "What did you eat?".
- A carbs field opened with the link stays open after an add.
- In the dialog:
  - Changing the time moves the food to the new section: a Snack header and no Lunch header.
  - The meal follows the time unless it was picked, in this edit or an earlier one (a food
    whose meal doesn't match its time).
  - A future time is refused, with the message shown inside the dialog and announced; a later
    valid pick clears it.
  - Picking the food's own minute shows no Update, also after picking another minute first.
  - A time picked after the dialog closed is dropped without an error.
  - Update saves, with `updatedAt` stamped when Update is tapped.
  - With Health sync on, the fake Health service sees delete(old time) then write(new time).
  - Two foods from one lookup (1 ms apart) moved to one minute keep different milliseconds,
    and deleting one deletes only its own millisecond.
  - Two foods with the same seconds moved to one minute: Update moves the second on by 1 ms.
  - The confirmation text is "Moved to …", "Updated to …" when the carbs changed, or "Updated"
    for a new serving with the same carbs.
  - The tests take `now` per test, and skip the one minute where a picked midnight or 23:59
    would not be refused or would be the food's own minute.
- The examples:
  - shown only when Today is empty and there are no chips
  - hidden when a saved food exists, and when a recent food exists
  - a tap fills the field without a lookup (the fake lookup service sees no call)
  - a tap during a lookup leaves the field as it was
- VoiceOver: the link, the time row, the meal dropdown and the example chips.

Device check before release:
- The link and the carbs field on a real keyboard.
- The time picker within today, including with a reset hour.
- An edited time shows in Apple Health at the new time.
- Move two foods from one lookup to the same minute, delete one, and confirm the other is
  still in Apple Health at its new time.
- Examples on a fresh install.
- Large text sizes.
