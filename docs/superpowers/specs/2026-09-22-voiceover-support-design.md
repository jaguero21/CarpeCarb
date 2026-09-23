# VoiceOver support (review #14) — design

Date: 2026-09-22 · Status: approved design, pending implementation plan

## Problem

From the 2026-09-18 code review, re-checked against the code at `1cc4cc8`:

- **There is no accessibility markup at all.** `grep -rn "Semantics(\|semanticLabel" lib/`
  returns nothing.
- **A VoiceOver user cannot delete a logged food or save one as a favourite.**
  Both actions exist only as swipes on a `Dismissible` (`lib/main.dart:2019-2060`):
  start-to-end saves to the Food list, end-to-start deletes. Flutter's
  `Dismissible` does not expose either as an accessibility action, and VoiceOver's
  own swipe gestures are bound to navigation, so there is no way to reach them.
  The only other route to a food is a long press, which opens a details dialog
  whose one action is "Close" (`lib/main.dart:936`).
- **Custom controls announce as plain text.** The Auto/Manual toggle pills
  (`lib/main.dart:855`), the "Reset" link (`:1963`) and Settings' "Clear All"
  (`lib/screens/settings_page.dart:713`) are bare `GestureDetector`s: VoiceOver
  does not call them buttons, and the toggle never says which mode is selected.
- **The app's central number is noisy, not silent.** Measured rather than
  assumed: the badge, the big number, the goal line and the bar merge into one
  node that reads *"Apple 25.0g of 100g daily goal, 25"* — the raw "25.0g", and
  a bare "25" that the `LinearProgressIndicator` (`lib/main.dart:1763`)
  contributes as its value. It needs one deliberate label and value, not a
  label on the bar.
- **Icon-only status is unlabelled.** The cloud sync indicator (`:1470-1490`) is
  an icon, or a bare spinner while syncing.
- **The widget's goal ring is undescribed** — two decorative `Circle`s
  (`ios/CarbWiseWidget/CarbWiseWidget.swift:138-150`).

This matters more here than in most apps: the user base for a carb tracker skews
toward higher accessibility need, and the two unreachable actions are the two
that correct a mistake in logged health data.

## Facts the design relies on

- Flutter's guideline matchers, run against the home screen. An earlier probe of
  mine reported all of these as passing; it was wrong, because the disclaimer
  dialog covers the screen on a fresh launch and the home screen was never in
  the accessibility tree. Seeding the disclaimer as accepted gives the real
  picture:
  - `labeledTapTargetGuideline` **fails**: the keyboard-dismiss `GestureDetector`
    wrapping the whole page (`lib/main.dart`, `_buildHomePage`) is an unlabelled
    tappable the size of the screen. It is excluded from semantics here, which
    also makes the guideline pass and worth keeping as a guard.
  - `iOSTapTargetGuideline` **fails** in two places: the Home and Settings icons
    are 40pt (`_buildNavIcon`), and the Auto/Manual pills are 37pt. The icons'
    hit area is widened to 44. **Correction, measured after implementation:**
    this does move the header slightly — the 44pt box is a fixed-width child of
    a `Row` with a `Spacer`, so the Home circle lands 6pt left of where it was,
    Settings 2pt left, and the 4pt-taller row drops the title and the content
    below it by about 2pt. Reviewed and accepted rather than compensated, since
    restoring the old pixels would take three interdependent padding
    adjustments that would break the next time this row changes. The pills would
    need to get taller, which is a visual change this batch excludes, so they
    stay — and the guideline is therefore *not* asserted.
  - `textContrastGuideline` **fails** on the disclaimer dialog's body text, which
    belongs to the deferred contrast work (see Non-goals).
- A food row renders `FoodItemCard` (`lib/widgets/food_item_card.dart`), which
  already takes `onTap`/`onLongPress`; the row's time string comes from
  `formatTime` (`lib/utils/date_format.dart`).
- Deleting a food already offers undo through `removeItem`, from any caller.

## Scope

In: VoiceOver correctness — labels, roles and state for the controls above; a
reachable delete and save; the daily progress value; the sync status; the widget
ring.

Out: Dynamic Type layout, colour contrast, the Watch app, and any visual change
to the existing controls.

## Part 1 — the food list

**Each row is one element.** The card's name, time and carb number are merged
into a single VoiceOver stop reading `"<name>, <carbs> grams of carbs, logged
<time>"` — e.g. "Apple, 25 grams of carbs, logged 8:30 AM" — with the hint
"Double tap for details". Today those are three separate stops and the number is
announced without units.

**The swipes gain equivalents, and keep working.**

- Two custom accessibility actions on the row, "Delete" and "Save to Food list",
  which is where an iOS user looks for per-row actions (the Actions rotor).
- The same two as buttons in the long-press details dialog, which currently only
  offers "Close". That gives a route to anyone who cannot swipe, whether or not
  they use VoiceOver, and makes the actions discoverable rather than hidden
  behind a gesture.
- Swipe behaviour, the confirmation haptics and the existing undo are unchanged,
  and undo is available from every route.

## Part 2 — controls, numbers and status

- **Auto/Manual toggle** (`lib/main.dart:855`): announced as a mutually exclusive
  pair of buttons, so VoiceOver reports which is selected. The visible text stays
  the label, so the two cannot drift apart.
- **"Reset"** (`:1963`) and **"Clear All"** (`settings_page.dart:713`): announced
  as buttons. Both already confirm before acting.
- **Daily progress** (`:1763`): labelled "Today's total" with the value
  `"<total> of <goal> grams"`, or `"<total> grams, no goal set"` when no goal is
  set. **Corrections, from the whole-branch review:**
  - The card has two states, and the one it is in after every add is the *last
    food* state (`showingDailyTotal` starts `false` and every add path resets
    it). That state still draws the goal line and the bar, so it must speak them
    too: it reads `"<food>"` with the value
    `"<carbs> grams, <total> of <goal> grams today"`. Speaking only the food's
    own carbs — the first implementation — left today-against-goal unspoken in
    the app's default state, which was worse than before the batch.
  - Over the goal, the value gains `", <n> grams over goal"`, matching the
    terracotta "20g over goal" the card draws. The widget deliberately does
    *not* do this, because it already announces "+20g over" as its own element.
  - The card is a control, not a caption: it announces as a button with a hint
    for the tap, and its long press — which VoiceOver has no gesture for — is
    offered as a custom action named "Open settings". Not "View history": the
    long press opens Settings on its Favorites tab.
- **Cloud sync indicator** (`:1470`): "Synced", "Syncing", "Sync failed". The
  idle state stays silent, as it renders nothing.
- **Widget goal ring** (`CarbWiseWidget.swift:138`): the ring becomes one element
  labelled "Carbs today" with the value `"<total> of <goal> grams"`, and the
  decorative circles are hidden so VoiceOver does not stop on them. **Correction:
  this applies to both shipped families.** The first implementation covered only
  `.systemSmall`, leaving `.systemMedium` — which is also in `supportedFamilies`
  — announcing an undescribed ring and a raw "point zero". The last-food capsule
  in both families speaks through `CarbAccessibility.grams` for the same reason.

## Part 3 — testing

**In `test/`:**

- The row's announced sentence, its hint, and both custom actions, via
  `containsSemantics`.
- The custom actions are **performed** through the semantics owner, not merely
  asserted to exist: "Delete" must remove the food and "Save to Food list" must
  save it. An advertised action that does nothing is worse than none.
- The toggle's selected state moves between the pills; the progress value with a
  goal and without one; the three sync states.
- The details dialog's new Delete and Save buttons.
- `iOSTapTargetGuideline` and `labeledTapTargetGuideline` as regression guards.
  Both pass today; the point is that they keep passing.

Two things cannot be covered by widget tests and go to the device checklist
instead: the cloud sync indicator, which only renders behind `Platform.isIOS`
and so never appears in host tests; and opening a food's details by long press,
which the row's swipe recogniser swallows in the test harness — that is
pre-existing and reproduces on the unmodified code, but it does mean the
sighted path to the new dialog buttons is unverified in CI.

**By hand, on a device, with VoiceOver on** — the parts CI cannot judge:

- Swipe through the home screen: every stop says something useful, in a sensible
  order, and nothing is announced twice.
- Delete a food from the Actions rotor; undo from the snackbar.
- Save a food to the Food list from the rotor.
- The toggle announces the selected mode; the progress bar announces the total.
- The Home Screen widget's ring is reachable and reads its value.

The widget's ring cannot be covered by `swift test` — SwiftUI accessibility isn't
reachable from the test target — so it is verified only on the device.

## Non-goals, recorded

- **Dynamic Type**: layouts are not audited at accessibility text sizes here.
- **Contrast**: the probe's `textContrastGuideline` failure on the disclaimer
  dialog's body text is real and is left for that batch, rather than being fixed
  quietly under a VoiceOver heading.
- **The Watch app** is untouched, as in every batch since it was found broken.

## Risk

Nothing here changes data, storage or sync; it is labels, roles and two new
buttons. The one real risk is over-merging a row's semantics and hiding content
that used to be reachable, which the announced-sentence tests pin down.
