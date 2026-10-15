# Labelled Settings Tabs, "Saved" Naming, Clear Today with Undo — Design

**Date:** 2026-10-15
**Release:** 1.0.5
**Status:** Approved in conversation; awaiting spec review
**Branch:** `feat/tabs-and-clear`, stacked on `feat/entry-and-edit` (PR #64)

This is round D, the last round of the UX roadmap (items 8 and 9). Rounds A to C are PRs #62 to #64.

## Problems

1. **Unlabelled Settings tabs.** Only the selected tab shows its name; the other three are bare
   icons, so History and Saved foods are easy to miss. VoiceOver gets no clear button label. The
   selected pill's white text on sage is about 2.7:1, below the 4.5:1 that small text needs.
2. **Two names for one thing.** The tab says "Favorites", while the actions say "Save to Food list".
3. **Reset is easy to hit by accident.** A one-tap "Reset" that clears the whole day, including
   Apple Health, sits right in the TODAY header next to the list people use most. A confirm
   dialog guards it, but once confirmed there's no way back.

## 8. Settings tabs

- **Layout:** four equal-width segments in one row. Each segment has its icon (20 pt) above its
  name (12 pt, weight 500, one line, ellipsis): **Saved · History · Goals · Features**. The icons
  are unchanged.
- **Selected tab:**
  - Filled with `Color.lerp(AppColors.sage, Colors.black, 0.35)`, with white icon and text.
  - Rounded corners (radius 12).
  - The white text must reach at least 4.5:1 against the fill. A test checks this.
- **Unselected tabs:**
  - Transparent, with icon and text in `lookupStatusColor(dark:)`.
  - Must reach at least 4.5:1 against the page background (`AppColors.cream` in light mode,
    `AppColors.darkBackground` in dark mode). Check `lib/config/app_theme.dart` for the actual
    scaffold background, and test against it.
- **Size and large text:** each segment is at least 44 pt tall and grows with large text. A name
  that doesn't fit is cut off with an ellipsis, and the row never scrolls or overflows.
- **Behaviour:** the tap behaviour stays the same: dismiss the keyboard, a light haptic, select
  the tab.
- **VoiceOver:** each segment is a button with its name as the label and the `selected` state,
  e.g. "Saved, selected, button".
- **Code:**
  - `lib/widgets/settings_tab_bar.dart`:
    `SettingsTabBar({required List<SettingsTab> tabs, required int selected, required ValueChanged<int> onSelected})`.
    `SettingsTab` is `({IconData icon, String label})`.
  - Colour helpers: `Color settingsTabSelectedFill()` and `Color settingsTabUnselected({required bool dark})`.
  - `settings_page.dart` uses the widget in place of its inline row.

## "Saved" everywhere

User-visible strings change as follows; behaviour is unchanged:
- **Settings tab:** "Favorites" becomes **"Saved"**.
- **Details dialog action:** "Save to Food list" becomes **"Save"**.
- **Food row's VoiceOver custom action:** "Save to Food list" becomes **"Save"**.
- **Snackbar after saving:** "<name> saved to Food list" becomes **"<name> saved"**.
- **Unchanged, because they already match:** "<name> is already saved", "Reset Saved Foods",
  "No saved foods yet", and "Swipe right on food items to save them here".

Not in code: the App Store screenshots and listing may still say "Favorites". Update them the next
time the listing is refreshed.

## 9. Clear today's log, with Undo

- **TODAY header:** the "Reset" text button is replaced by a **⋯** `PopupMenuButton`
  (`Icons.more_horiz`).
  - It has a 44 pt tap target, uses `onSurfaceVariant`, and has the tooltip and VoiceOver label
    **"Today options"**.
  - The menu has one item: **"Clear today's log…"**.
- **Confirm dialog:**
  - Title: **"Clear today's log?"**
  - Body: **"All N foods will be removed from today and from Apple Health."** With one food it
    reads "The 1 food will be removed…".
  - Buttons: Cancel, and **Clear**, styled in terracotta as today.
- **Clear** runs the existing `_resetTotal`:
  - It clears the list, sets delete markers for iCloud, updates the widget, and removes the foods
    from Apple Health.
  - Saved and recent foods are untouched.
  - It then shows a snackbar, **"Today's log cleared"**, with **Undo** (6 s).
- **Undo:**
  - Ignored if the app's day (`_todayString()`) has changed since the clear.
  - Otherwise it puts back every cleared food whose id isn't already in `foodItems`. Foods logged
    since the clear stay, and nothing is duplicated.
  - Restored rows animate in.
  - For each restored id it calls `_syncStore.recordItemRestored(id)` (so iCloud brings them back
    on the other device), then saves once.
  - It updates the widget and writes each restored food back to Apple Health.
- **Code:**
  - `restoreCleared(List<FoodItem> current, List<FoodItem> cleared) → List<FoodItem>` is a pure
    function in `lib/models/clear_today.dart`. It returns the foods to add back: those in
    `cleared` whose id isn't in `current`, in their original order.
  - `_resetTotal` returns the snapshot it cleared.
  - New methods `_confirmClearToday` and `_undoClearToday(snapshot, dayKey)`.
  - The test hook `resetTotalForTest` keeps working.

## Out of scope

- Undo for clearing saved foods in Settings.
- Moving the daily reset time setting.
- Any change to what History shows.

## Testing

Unit tests:
- Tab colours meet 4.5:1:
  - selected: white on the fill;
  - unselected: on the page background, in light and dark mode.
- `restoreCleared`:
  - nothing already present → all foods come back, in order;
  - some already present → only the missing ones;
  - empty → empty.

Widget tests:
- **Settings tab bar:**
  - shows all four names;
  - a tap selects that tab and calls `onSelected`;
  - each segment is a button, and the selected one has the selected state;
  - each segment is at least 44 pt tall;
  - no overflow at 2× text on a 320 pt wide screen.
- **Settings page:** opens on Saved, and History, Goals and Features are reachable by their names.
- **Renamed strings:**
  - the details dialog shows "Save";
  - the row's VoiceOver action is "Save";
  - the saving snackbar reads "<name> saved".
  - Update existing tests that used the old strings.
- **Clear today:**
  - The ⋯ button is labelled "Today options".
  - The menu leads to the dialog with the food count.
  - **Cancel** changes nothing.
  - **Clear** empties Today and shows the snackbar.
  - **Undo** restores the foods, with Health writes recorded by a fake Health service.
  - A food logged between Clear and Undo stays, and isn't duplicated.
  - Undo after a day change does nothing.

Device check before release:
- Tabs at the largest text size and in dark mode.
- Clear with Health sync on, then Undo, and the foods are back in Apple Health.
- A second device receives both the clear and the undo.
