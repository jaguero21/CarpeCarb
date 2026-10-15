# Labelled Settings Tabs, "Saved" Naming, Clear Today with Undo — Design

**Date:** 2026-10-15
**Release:** 1.0.5
**Status:** Approved; implemented on feat/tabs-and-clear
**Branch:** `feat/tabs-and-clear`, stacked on `feat/entry-and-edit` (PR #64)

This is round D, the last round of the UX roadmap (items 8 and 9). Rounds A to C are PRs #62 to #64.

## Problems

1. **Unlabelled Settings tabs.** Only the selected tab shows its name; the other three are bare
   icons, so History and Saved foods are easy to miss. VoiceOver gets no clear button label. The
   selected pill's white text on sage is about 2.7:1, below the 4.5:1 that small text needs.
2. **Two names for one thing.** The tab says "Favorites", while the actions say "Save to Food list".
   A bare "Save" would be no better: in the edit dialog it sits next to "Update", and "Banana
   saved" reads like "your edit was saved".
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
- **Details dialog action:** "Save to Food list" becomes **"Add to Saved"**.
- **Food row's VoiceOver custom action:** "Save to Food list" becomes **"Add to Saved"**.
- **Snackbar after saving:** "<name> saved to Food list" becomes **"<name> added to Saved"**.
- **Already-saved snackbar:** "<name> is already saved" becomes **"<name> is already in Saved"**.
- **Unchanged, because they already match:** "Reset Saved Foods", "No saved foods yet", and
  "Swipe right on food items to save them here".

Not in code: the App Store screenshots and listing may still say "Favorites". Update them the next
time the listing is refreshed.

## 9. Clear today's log, with Undo

- **TODAY header:** the "Reset" text button is replaced by a **⋯** `PopupMenuButton`
  (`Icons.more_horiz`).
  - It has a 44 pt tap target, uses `onSurfaceVariant`, and has the tooltip and VoiceOver label
    **"Today options"**.
  - `PopupMenuButton` gives VoiceOver only a tooltip, not a label. So the button is wrapped in a
    `Semantics(button: true, label: 'Today options', excludeSemantics: true)` whose `onTap` opens
    the menu through a `GlobalKey<PopupMenuButtonState<void>>` (`showButtonMenu()`), the same
    pattern as the serving stepper's buttons. VoiceOver reads the name once, as a label; the
    long-press tooltip stays.
  - The menu has one item: **"Clear today's log…"**.
- **Confirm dialog:**
  - Title: **"Clear today's log?"**
  - Body: **"All N foods will be removed from today and from Apple Health."** With one food it
    reads **"This food will be removed from today and from Apple Health."**
  - Buttons: Cancel, and **Clear**, styled in terracotta as today.
- **Clear** runs the existing `_resetTotal`:
  - It clears the list, sets delete markers for iCloud, updates the widget, and removes the foods
    from Apple Health.
  - Saved and recent foods are untouched.
  - Each Health delete reports whether it worked. `_resetTotal` returns
    `({List<FoodItem> cleared, Future<Set<String>> healthDeleted})`: what it cleared, and the ids
    whose Health delete succeeded, once every delete has finished. Each clear keeps its own
    record, so a second clear can't change what the first clear's Undo waits on.
  - It then shows a snackbar, **"Today's log cleared"**, with **Undo** (6 s).
- **Action snackbars, app-wide:** in this Flutter version a snackbar with an action persists until
  it is swiped away by default, and the snackbars queued behind it never show. Every snackbar with
  an action (five in `main.dart`, one in `settings_page.dart`) sets
  `persist: snackBarPersists(context)` (`lib/utils/snack_bars.dart`). That is
  `MediaQuery.accessibleNavigationOf(context)`: under VoiceOver the snackbar stays so its Undo can
  still be reached, and for everyone else it times out after its duration.
- **Undo:**
  - Ignored if the app's day (`_todayString()`) has changed since the clear.
  - Otherwise it puts back every cleared food whose id isn't already in `foodItems`. Foods logged
    since the clear stay, and nothing is duplicated.
  - It puts back **fresh copies** (`FoodItem.withNewId()`): a new id, and every other field the
    same, including `loggedAt`, `category`, `serving`, `details`, `citations` and the manual flag.
    The old ids' delete markers **stay**. Markers merge across devices as a union, so if the other
    device had already merged the clear, lifting a marker on this device only would let the next
    sync delete the restored foods again on both devices. The copies sync as new foods.
  - Restored rows animate in.
  - It saves once, then updates the widget.
  - **Apple Health:** it waits for that clear's own deletes (`healthDeleted`), then writes a copy
    back only if its original's delete succeeded **and** the copy is still listed. A failed delete
    left the original sample in Health, so a write would double it. A copy deleted again (or
    cleared again) meanwhile must not reappear in Health. Waiting matters because a restored
    sample uses the same millisecond window as the deleted one, so a delete that finished after
    the write would remove it again.
- **Swipe-delete's Undo follows the same rules:** it puts back `removedItem.withNewId()` at the same
  index, the old id's delete marker stays, and it saves and then updates the widget. It skips the
  Undo if the old id is already listed again. `removeItemById` keeps its Health delete's
  `Future<bool>`; Undo waits for it and writes the copy only if the delete succeeded and the copy
  is still listed.
- **Code:**
  - `restoreCleared(List<FoodItem> current, List<FoodItem> cleared) → List<FoodItem>` is a pure
    function in `lib/models/clear_today.dart`. It returns the foods to add back: those in
    `cleared` whose id isn't in `current`, in their original order.
  - `FoodItem.withNewId()` in `lib/models/food_item.dart`: the same food under a newly generated id.
  - `_resetTotal` returns `({List<FoodItem> cleared, Future<Set<String>> healthDeleted})`.
  - New methods `_confirmClearToday` and `_undoClearToday(cleared, healthDeleted, dayKey)`.
  - `_deleteFromHealthKit` returns the delete's `Future<bool>`, for swipe-delete's Undo.
  - `snackBarPersists(BuildContext)` in `lib/utils/snack_bars.dart`.
  - The test hooks `resetTotalForTest` and `undoClearTodayForTest` keep working.

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
- `FoodItem.withNewId()` changes the id and nothing else.
- `mergeSyncState`: foods an Undo put back (as fresh copies) survive a cloud copy whose delete
  markers hold the old ids, in both merge directions. It fails if the copies keep the old ids.

Widget tests:
- **Settings tab bar:**
  - shows all four names;
  - a tap selects that tab and calls `onSelected`;
  - each segment is a button, and the selected one has the selected state;
  - each segment is at least 44 pt tall;
  - no overflow at 2× text on a 320 pt wide screen.
- **Settings page:** opens on Saved ("No saved foods yet"), and History, Goals and Features are
  reachable by their names; after each tap only that tab's own text shows.
- **Renamed strings:**
  - the details dialog shows "Add to Saved", and hides it while a serving change is pending;
  - the row's VoiceOver action is "Add to Saved", and it saves the food;
  - the saving snackbar reads "<name> added to Saved";
  - saving a food already in Saved says "<name> is already in Saved".
  - Update existing tests that used the old strings.
- **Clear today:**
  - The ⋯ button has the VoiceOver label "Today options" as a button with a tap action, and an
    empty tooltip in semantics (so the name isn't spoken twice). VoiceOver's tap opens the menu.
    The long-press tooltip is still there.
  - The menu leads to the dialog with the food count.
  - **Cancel** changes nothing.
  - **Clear** empties Today and shows the snackbar.
  - **Undo** restores the foods, with Health writes recorded by a fake Health service.
  - A food logged between Clear and Undo stays, and isn't duplicated.
  - Undo after a day change does nothing. This is tested on the pure `undoApplies` check, since there is no clock seam.
  - Undo writes to Health only after the clear's deletes finish (a fake Health service that
    holds its deletes).
  - Undo puts back fresh copies: same names, carbs, `loggedAt` and meal, new ids. The old ids are
    still in the stored delete markers, and the stored list holds the new ids.
  - If one food's Health delete fails, Undo writes only the other food.
  - A restored food deleted before the deletes finish is not written.
  - A second Clear: the first Undo writes nothing (its foods were cleared again), and the second
    Clear's Undo waits on the second Clear's own deletes.
  - The cleared snackbar is gone after 7 s; under VoiceOver (accessible navigation) it is still
    there after 7 s.
- **Swipe-delete:**
  - Undo puts back a fresh copy at the same place (new id, every other field the same), and the
    old id stays in the delete markers.
  - Undo writes the copy to Health only once its delete has finished, not at all if the delete
    failed, and not if the copy was deleted again meanwhile.
  - The "<name> removed" snackbar is gone after 5 s.

Device check before release:
- Tabs at the largest text size and in dark mode.
- Clear with Health sync on, then Undo, and the foods are back in Apple Health.
- A second device receives both the clear and the undo.
- On two devices where the other device has already synced a Clear, Undo the Clear. The foods stay
  on both devices after the next sync.
- Snackbars disappear after a few seconds with VoiceOver off, and stay with it on.
