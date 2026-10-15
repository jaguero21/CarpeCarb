# One Food Field, Time and Meal Editing, First-Run Examples Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three changes to the home screen and the food details dialog:
- Replace the Auto/Manual switch with an "Enter carbs yourself" link.
- Let a logged food's time and meal be changed from its details dialog.
- Show example foods to new users on an empty day.

**Architecture:**
- **Pure helpers:**
  - `dayStart` and `resolvePickedTime` handle today's time window.
  - `FoodItem.edited` is the single copy-with-changes for serving, time and meal.
  - Three new VoiceOver label functions.
- **Small widgets:** `EntryModeLink`, `TimeMealRow` and `ExamplePrompts`.
- **`main.dart`:**
  - Swaps the switch for the link.
  - Extends the details dialog's draft to cover time and meal, saving through the existing
    `_updateFoodItem` (Health, iCloud, chips).
  - Shows `ExamplePrompts` in the empty state.

**Tech Stack:** Flutter/Dart, `flutter_test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-14-entry-edit-examples-design.md`

## Global Constraints

### Link
- **Text:**
  - `Enter carbs yourself` while the carbs field is hidden.
  - `Look it up instead` while it is shown. This also clears the carbs field.
- **Button text:** `Add Food` normally, `Add` while the carbs field is shown.
- **Food field hint:**
  - `What did you eat?` normally.
  - `Food name` while the carbs field is shown.
- **Style:**
  - `TextButton`, centred, 14 pt, weight 500, `minimumSize: Size(0, 44)`.
  - Text colour `entryLinkColor(dark:)`:
    - Light mode: `Color.lerp(AppColors.sage, Colors.black, 0.45)`.
    - Dark mode: `Color.lerp(AppColors.sage, Colors.white, 0.35)`.
  - Contrast at least 4.5:1 on the input card (`Colors.white` in light mode, `AppColors.darkSurface` in dark).
- **Focus after showing the carbs field:**
  - The carbs field, if the food field has text.
  - Otherwise the food field.
- **Order inside the input card:**
  1. Food field
  2. Carbs field (when shown)
  3. Link
  4. Quick-add chips
  5. Add button
  6. Progress line

### Time and meal row
- **Placement:** in the details dialog, above the serving picker, for every food.
- **Time button:**
  - Reads `Time · <formatTime>`.
  - VoiceOver label `Time, <formatTime>`, with hint `Double tap to change`.
- **Meal dropdown:**
  - Options `FoodCategory.values` (Breakfast, Lunch, Dinner, Snack, Drink), each with its icon.
  - VoiceOver label `Meal, <label>`.

### Editing rules
- **Meal follows time:** picking a time sets the meal to `FoodCategory.fromTime(time)`, unless a meal was picked earlier in the same edit.
- **Allowed times:** today, up to now.
  - `resolvePickedTime` returns null outside that window.
  - On null, show `Pick a time from today, up to now` inside the dialog, in `colorScheme.error` at 12 pt, and leave the draft unchanged.
  - Picking the same minute as the draft changes nothing.
- **Update button:** shown when the serving, time or meal differs from the logged food. It saves them all at once through `_updateFoodItem` with `updatedAt = DateTime.now().toUtc()`.
- **Confirmation snackbar:**
  - `Updated to <carbs.toStringAsFixed(1)> g` when the carbs changed.
  - Otherwise `Moved to <meal label>, <formatTime(new time)>`.
- **Announcement on change:** `<meal label>, <formatTime(time)>`.

### Examples
- **When shown:** Today is empty, quick-add has finished loading, and there are no quick-add chips.
- **Content:**
  - A `Try something like:` heading.
  - Chips: `2 slices pepperoni pizza`, `Chipotle chicken burrito bowl`, `1 cup cooked white rice`, `Grande oat milk latte`.
  - Then the line `Include how much you had — it makes the carbs more accurate.`
- **Tapping a chip:**
  - Fills the food field and puts the cursor at the end.
  - Switches back to lookup mode, hiding and clearing the carbs field.
  - Focuses the food field.
  - Never looks anything up.
- **VoiceOver:** chip label `Use example, <text>`.
- **Size:** chips at least 44 pt tall.

### Commits
- `git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit ...`.
- NO `Co-Authored-By` trailer and no Claude/Claude Code attribution of any kind.
- Explicit `git add` paths only. Never commit `iap_review_screenshot.png`.

### Checks
- Before each commit: `flutter analyze lib test` (no issues) and the task's tests.
- At the end of every task: the full `flutter test` (414 passed before this plan).

---

### Task 1: Helpers, edits, wording and link colour

**Files:**
- Modify: `lib/utils/day_key.dart` (add `dayStart`)
- Create: `lib/utils/picked_time.dart`
- Modify: `lib/models/food_item.dart` (add `edited`, and make `withServing` delegate to it)
- Modify: `lib/utils/a11y_labels.dart` (three functions)
- Create: `lib/widgets/entry_mode_link.dart` (`entryLinkColor` plus the widget)
- Test:
  - `test/day_key_test.dart` (append)
  - `test/picked_time_test.dart`
  - `test/food_item_edit_test.dart`
  - `test/a11y_labels_test.dart` (append)
  - `test/entry_mode_link_test.dart`

**Interfaces:**
- Produces:
  - `DateTime dayStart(DateTime now, int resetHour)`
  - `DateTime? resolvePickedTime(TimeOfDay picked, {required DateTime now, required int resetHour})`
  - `FoodItem edited({ServingInfo? serving, DateTime? loggedAt, FoodCategory? category, required DateTime now})`
  - `String timeRowLabel(String time)`
  - `String mealDropdownLabel(String meal)`
  - `String exampleChipLabel(String text)`
  - `Color entryLinkColor({required bool dark})`
  - `EntryModeLink({required bool manual, required VoidCallback onPressed})`

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `test/day_key_test.dart`. Check its imports first; it already imports `day_key.dart`.

```dart
  group('dayStart', () {
    test('with a midnight reset, the day starts at midnight', () {
      expect(dayStart(DateTime(2026, 10, 14, 13, 5), 0), DateTime(2026, 10, 14));
    });

    test('with a 4 AM reset, after 4 AM the day started at 4 AM today', () {
      expect(dayStart(DateTime(2026, 10, 14, 9), 4), DateTime(2026, 10, 14, 4));
    });

    test('with a 4 AM reset, at 2 AM the day started at 4 AM yesterday', () {
      expect(dayStart(DateTime(2026, 10, 14, 2), 4), DateTime(2026, 10, 13, 4));
    });

    test('agrees with dayKey', () {
      final now = DateTime(2026, 10, 14, 2);
      expect(dayKey(dayStart(now, 4), 4), dayKey(now, 4));
    });
  });
```

Create `test/picked_time_test.dart`:

```dart
import 'package:carb_tracker/utils/picked_time.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an earlier time today is that time today', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 8, minute: 30),
          now: DateTime(2026, 10, 14, 13, 5), resetHour: 0),
      DateTime(2026, 10, 14, 8, 30),
    );
  });

  test('a time later than now is refused', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 23, minute: 59),
          now: DateTime(2026, 10, 14, 13, 5), resetHour: 0),
      isNull,
    );
  });

  test('a time before the day started is refused', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 3, minute: 0),
          now: DateTime(2026, 10, 14, 9), resetHour: 4),
      isNull,
    );
  });

  test('with a 4 AM reset at 2 AM, 11 PM means last night', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 23, minute: 0),
          now: DateTime(2026, 10, 14, 2), resetHour: 4),
      DateTime(2026, 10, 13, 23),
    );
  });

  test('now itself is allowed', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 13, minute: 5),
          now: DateTime(2026, 10, 14, 13, 5, 40), resetHour: 0),
      DateTime(2026, 10, 14, 13, 5),
    );
  });
}
```

Create `test/food_item_edit_test.dart`:

```dart
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/serving_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 14, 18);
  final logged = FoodItem(
    name: 'Pho',
    carbs: 13.7,
    details: 'USDA FoodData Central (Survey (FNDDS)): Soup, pho, 1 cup (245 g).',
    citations: const ['https://fdc.nal.usda.gov/food-details/1/nutrients'],
    loggedAt: DateTime(2026, 10, 14, 15, 10),
    category: FoodCategory.snack,
  );

  test('a new time and meal keep everything else', () {
    final moved = logged.edited(
        loggedAt: DateTime(2026, 10, 14, 13, 30),
        category: FoodCategory.lunch,
        now: now);
    expect(moved.id, logged.id);
    expect(moved.name, 'Pho');
    expect(moved.carbs, 13.7);
    expect(moved.details, logged.details);
    expect(moved.citations, logged.citations);
    expect(moved.loggedAt, DateTime(2026, 10, 14, 13, 30));
    expect(moved.category, FoodCategory.lunch);
    expect(moved.updatedAt, now);
  });

  test('a manual entry stays manual', () {
    final manual = FoodItem(name: 'Toast', carbs: 15, isManualEntry: true);
    expect(manual.edited(category: FoodCategory.breakfast, now: now).isManualEntry, isTrue);
  });

  test('a serving still recalculates the carbs', () {
    final serving = ServingInfo.fromServerItem({
      'source': 'usda',
      'fdcId': 1,
      'serving': {'portionId': 'p1', 'label': '1 cup', 'grams': 245, 'count': 1},
      'portions': [
        {'id': 'p1', 'label': '1 cup', 'grams': 245},
      ],
      'per100g': {'carbs': 5.6},
    }, const Nutrients(carbs: 13.7))!;
    final doubled = logged.edited(serving: serving.copyWith(count: 2), now: now);
    expect(doubled.carbs, 27.4);
    expect(doubled.loggedAt, logged.loggedAt);
  });

  test('withServing is edited with a serving', () {
    final serving = ServingInfo.fromServerItem(
        {'source': 'web'}, const Nutrients(carbs: 10))!;
    expect(logged.withServing(serving, now: now).carbs,
        logged.edited(serving: serving, now: now).carbs);
  });
}
```

If `ServingInfo.copyWith`/`fromServerItem`/`Nutrients` differ from this, check `lib/models/serving_info.dart` and `test/serving_info_test.dart`, build an equivalent USDA serving at count 2, and keep the assertion that carbs are recalculated (5.6 × 245 × 2 / 100 = 27.4).

Append inside `main()` of `test/a11y_labels_test.dart`:

```dart
  group('time, meal and examples', () {
    test('labels', () {
      expect(timeRowLabel('12:05 PM'), 'Time, 12:05 PM');
      expect(mealDropdownLabel('Lunch'), 'Meal, Lunch');
      expect(exampleChipLabel('2 slices pepperoni pizza'),
          'Use example, 2 slices pepperoni pizza');
    });
  });
```

Create `test/entry_mode_link_test.dart`. It reuses the contrast helpers in `test/helpers/contrast.dart` if that file exists; otherwise copy `_luminance`/`_contrast` from `test/source_tag_test.dart`.

```dart
import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/widgets/entry_mode_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/contrast.dart';

void main() {
  test('the link is readable on the input card in both modes', () {
    expect(contrastRatio(entryLinkColor(dark: false), Colors.white),
        greaterThanOrEqualTo(4.5));
    expect(contrastRatio(entryLinkColor(dark: true), AppColors.darkSurface),
        greaterThanOrEqualTo(4.5));
  });

  testWidgets('the link names what it does and is a 44 pt button', (tester) async {
    var taps = 0;
    Future<void> pump(bool manual) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EntryModeLink(manual: manual, onPressed: () => taps++))));

    await pump(false);
    expect(find.text('Enter carbs yourself'), findsOneWidget);
    expect(tester.getSize(find.byType(TextButton)).height, greaterThanOrEqualTo(44));
    await tester.tap(find.text('Enter carbs yourself'));
    expect(taps, 1);

    await pump(true);
    expect(find.text('Look it up instead'), findsOneWidget);
  });
}
```

If `test/helpers/contrast.dart` exists but names its function differently, use its name.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/day_key_test.dart test/picked_time_test.dart test/food_item_edit_test.dart test/a11y_labels_test.dart test/entry_mode_link_test.dart`
Expected: FAIL. None of the new functions exist yet.

- [ ] **Step 3: Implement**

Append to `lib/utils/day_key.dart`:

```dart
/// When the app's current day began: the most recent [resetHour]:00 at or
/// before [now]. Agrees with [dayKey]; built with calendar arithmetic, like
/// [nextDayBoundary].
DateTime dayStart(DateTime now, int resetHour) {
  final today = DateTime(now.year, now.month, now.day, resetHour);
  return today.isAfter(now)
      ? DateTime(now.year, now.month, now.day - 1, resetHour)
      : today;
}
```

Create `lib/utils/picked_time.dart`:

```dart
import 'package:flutter/material.dart';

import 'day_key.dart';

/// The moment a time picked for a logged food means: today (the app's day,
/// which starts at [resetHour]), at or before [now]. Null when the time
/// would fall outside today, i.e. in the future or before the day began.
DateTime? resolvePickedTime(TimeOfDay picked,
    {required DateTime now, required int resetHour}) {
  var candidate =
      DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
  // A time later than now on today's date means the evening before, which
  // is still today when the day starts after midnight.
  if (candidate.isAfter(now)) {
    candidate = DateTime(
        now.year, now.month, now.day - 1, picked.hour, picked.minute);
  }
  return candidate.isBefore(dayStart(now, resetHour)) ? null : candidate;
}
```

In `lib/models/food_item.dart`, replace `withServing` with:

```dart
  /// This food with any of [serving], [loggedAt] and [category] changed.
  /// A new serving recalculates the nutrients. Identity, name, details,
  /// citations and the manual flag stay; [updatedAt] becomes [now].
  FoodItem edited({
    ServingInfo? serving,
    DateTime? loggedAt,
    FoodCategory? category,
    required DateTime now,
  }) {
    final n = serving?.nutrients();
    return FoodItem(
      id: id,
      name: name,
      carbs: n?.carbs ?? carbs,
      protein: n == null ? protein : n.protein,
      fat: n == null ? fat : n.fat,
      fiber: n == null ? fiber : n.fiber,
      calories: n == null ? calories : n.calories,
      details: details,
      citations: citations,
      isManualEntry: isManualEntry,
      loggedAt: loggedAt ?? this.loggedAt,
      category: category ?? this.category,
      serving: serving ?? this.serving,
      updatedAt: now,
    );
  }

  /// This food at [next], with its nutrients recalculated.
  FoodItem withServing(ServingInfo next, {required DateTime now}) =>
      edited(serving: next, now: now);
```

Keep whatever doc comment `withServing` had if it says more.

Append to `lib/utils/a11y_labels.dart`:

```dart
/// The details dialog's time button: "Time, 12:05 PM".
String timeRowLabel(String time) => 'Time, $time';

/// The details dialog's meal dropdown: "Meal, Lunch".
String mealDropdownLabel(String meal) => 'Meal, $meal';

/// A first-run example chip: "Use example, 2 slices pepperoni pizza".
String exampleChipLabel(String text) => 'Use example, $text';
```

Create `lib/widgets/entry_mode_link.dart`:

```dart
import 'package:flutter/material.dart';

import '../config/app_colors.dart';

/// The link's text colour on the input card: sage darkened in light mode and
/// lightened in dark mode, since sage itself is too pale for 14 pt text.
Color entryLinkColor({required bool dark}) => dark
    ? Color.lerp(AppColors.sage, Colors.white, 0.35)!
    : Color.lerp(AppColors.sage, Colors.black, 0.45)!;

/// Under the food field: switches between looking a food up and typing its
/// carbs. Replaces the old Auto/Manual switch, so there's no mode to choose
/// before every entry.
class EntryModeLink extends StatelessWidget {
  const EntryModeLink({super.key, required this.manual, required this.onPressed});

  /// Whether the carbs field is showing.
  final bool manual;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: entryLinkColor(dark: dark),
        ),
        onPressed: onPressed,
        child: Text(
          manual ? 'Look it up instead' : 'Enter carbs yourself',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
```

If `test/helpers/contrast.dart` doesn't exist, create it with `double contrastRatio(Color a, Color b)` (WCAG relative luminance), moved from `test/source_tag_test.dart`. Make `source_tag_test.dart` use it too, and say so in the report.

- [ ] **Step 4: Run the tests to verify they pass**

Run the same command as Step 2. Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass; existing `withServing` callers are unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/utils/day_key.dart lib/utils/picked_time.dart lib/models/food_item.dart lib/utils/a11y_labels.dart lib/widgets/entry_mode_link.dart test/day_key_test.dart test/picked_time_test.dart test/food_item_edit_test.dart test/a11y_labels_test.dart test/entry_mode_link_test.dart
# plus test/helpers/contrast.dart and test/source_tag_test.dart if created or changed
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): today's time window, one way to edit a food, and the entry link"
```

---

### Task 2: One food field

**Files:**
- Modify: `lib/main.dart`
- Modify tests that used the switch:
  - `test/a11y_controls_test.dart`
  - `test/recent_foods_home_test.dart`
  - `test/quick_log_home_test.dart`
  - `test/lookup_progress_home_test.dart`
- Test: `test/entry_mode_home_test.dart`

**Interfaces:**
- Consumes: from Task 1, `EntryModeLink(manual:, onPressed:)`.
- Produces on `CarbTrackerHomeState`: `void _toggleEntryMode()`.

- [ ] **Step 1: Write the failing tests**

Create `test/entry_mode_home_test.dart`:

```dart
import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const []));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  Finder hint(String text) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == text);

  testWidgets('there is no Auto/Manual switch', (tester) async {
    await start(tester);
    expect(find.text('Auto'), findsNothing);
    expect(hint('What did you eat?'), findsOneWidget);
    expect(find.text('Add Food'), findsOneWidget);
  });

  testWidgets('the link shows the carbs field, and back again', (tester) async {
    await start(tester);
    await tester.tap(find.text('Enter carbs yourself'));
    await tester.pumpAndSettle();
    expect(hint('Food name'), findsOneWidget);
    expect(hint('Carbs (g)'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Look it up instead'), findsOneWidget);

    await tester.enterText(hint('Carbs (g)'), '45');
    await tester.tap(find.text('Look it up instead'));
    await tester.pumpAndSettle();
    expect(hint('Carbs (g)'), findsNothing);
    expect(hint('What did you eat?'), findsOneWidget);
    expect(find.text('Add Food'), findsOneWidget);

    // Showing it again starts empty.
    await tester.tap(find.text('Enter carbs yourself'));
    await tester.pumpAndSettle();
    final carbs = tester.widget<TextField>(hint('Carbs (g)'));
    expect(carbs.controller!.text, isEmpty);
  });

  testWidgets('a lookup with no carbs still opens the carbs field', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(
        const LookupResult(items: [], unknownCarbs: ['mystery stew']));
    await tester.pumpAndSettle();
    expect(hint('Carbs (g)'), findsOneWidget);
    expect(find.text('Look it up instead'), findsOneWidget);
  });

  testWidgets('VoiceOver reads the link as a button', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester);
      expect(find.semantics.byLabel('Enter carbs yourself').evaluate().single,
          isSemantics(isButton: true, hasTapAction: true));
    } finally {
      handle.dispose();
    }
  });
}
```

If the carbs field's hint isn't exactly `Carbs (g)`, check `main.dart` and use the real one.

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/entry_mode_home_test.dart`
Expected: FAIL. The switch is still there, and the hint and link don't exist yet.

- [ ] **Step 3: Implement in `lib/main.dart`**

1. Import `widgets/entry_mode_link.dart`.
2. Delete the whole `Widget _buildModeToggle() { ... }` method, and the block in the input card that calls it (from the `// Mode toggle (Auto / Manual)` comment through the `Padding(... child: _buildModeToggle() ...)` and its `if (_premiumService.isManualEntryEnabled)` guard).
3. Change the food field's hint to `_isManualEntryMode ? 'Food name' : 'What did you eat?'`.
4. Add `_toggleEntryMode` next to `_focusNextHomeInput`:

```dart
  /// The link under the food field: show the carbs field to log a food
  /// yourself, or hide (and clear) it to look one up.
  void _toggleEntryMode() {
    setState(() {
      _isManualEntryMode = !_isManualEntryMode;
      if (!_isManualEntryMode) _carbController.clear();
    });
    if (_isManualEntryMode && _foodController.text.trim().isNotEmpty) {
      _carbFocusNode.requestFocus();
    } else {
      _foodFocusNode.requestFocus();
    }
  }
```

5. In the input card, directly after the manual carbs-field block (`if (_isManualEntryMode && _premiumService.isManualEntryEnabled) ...[ ... ],`) and before the quick-add chips block, add:

```dart
                      if (_premiumService.isManualEntryEnabled) ...[
                        const SizedBox(height: 4),
                        EntryModeLink(
                          manual: _isManualEntryMode,
                          onPressed: _toggleEntryMode,
                        ),
                      ],
```

   If the chips block has its own leading `SizedBox(height: 12)`, reduce the spacing so the gaps look even: link, then chips, then button. Report what you chose.
6. Leave `_handOffUnknownCarbs`, `_focusNextHomeInput`, the keyboard toolbar, `_addManualFood` and the Add button's label logic (`_isManualEntryMode ? 'Add' : 'Add Food'`) unchanged. They already key off `_isManualEntryMode`.

- [ ] **Step 4: Update the tests that used the switch**

- `test/a11y_controls_test.dart`: replace the switch's semantics test (the one that finds `'Auto'`/`'Manual'` and taps `'Manual'`) with a test that the link `Enter carbs yourself` is a button, and that after a tap `Look it up instead` is a button. Keep the rest of the file.
- `test/recent_foods_home_test.dart` and `test/quick_log_home_test.dart`: replace `tap(find.text('Manual'))` with `tap(find.text('Enter carbs yourself'))`, and the hint `'Food name...'` with `'Food name'`.
- `test/lookup_progress_home_test.dart`: change its hint finder from `'Enter food item...'` to `'What did you eat?'`.

List every changed test in the report.

- [ ] **Step 5: Run the tests**

Run: `flutter test test/entry_mode_home_test.dart test/a11y_controls_test.dart test/recent_foods_home_test.dart test/quick_log_home_test.dart test/lookup_progress_home_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart test/entry_mode_home_test.dart test/a11y_controls_test.dart test/recent_foods_home_test.dart test/quick_log_home_test.dart test/lookup_progress_home_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): one food field, with a link to enter carbs yourself"
```

---

### Task 3: Change a food's time and meal

**Files:**
- Create: `lib/widgets/time_meal_row.dart`
- Modify: `lib/main.dart` (`_showFoodDetails`, `_updateFoodItem`'s snackbar, and a test hook for the time picker)
- Test: `test/time_meal_row_test.dart`, `test/time_meal_edit_test.dart`

**Interfaces:**
- Consumes from Task 1:
  - `resolvePickedTime`
  - `FoodItem.edited`
  - `timeRowLabel`
  - `mealDropdownLabel`
  - `formatTime` (from `lib/utils/date_format.dart`, existing)
- Produces:
  - `TimeMealRow({required DateTime time, required FoodCategory meal, required VoidCallback onPickTime, required ValueChanged<FoodCategory> onMealChanged, String? error})`.
  - On `CarbTrackerHomeState`, `@visibleForTesting Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial) pickTime`, defaulting to `showTimePicker`.

- [ ] **Step 1: Write the failing tests**

Create `test/time_meal_row_test.dart`:

```dart
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/widgets/time_meal_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(List<String>, List<FoodCategory>)> pump(WidgetTester tester,
      {String? error}) async {
    final picks = <String>[];
    final meals = <FoodCategory>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TimeMealRow(
          time: DateTime(2026, 10, 14, 12, 5),
          meal: FoodCategory.lunch,
          onPickTime: () => picks.add('pick'),
          onMealChanged: meals.add,
          error: error,
        ),
      ),
    ));
    return (picks, meals);
  }

  testWidgets('shows the time and meal; the time is a button', (tester) async {
    final (picks, _) = await pump(tester);
    expect(find.text('Time · 12:05 PM'), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
    await tester.tap(find.text('Time · 12:05 PM'));
    expect(picks, ['pick']);
  });

  testWidgets('picking a meal reports it', (tester) async {
    final (_, meals) = await pump(tester);
    await tester.tap(find.text('Lunch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dinner').last);
    await tester.pumpAndSettle();
    expect(meals, [FoodCategory.dinner]);
  });

  testWidgets('an error shows under the row', (tester) async {
    await pump(tester, error: 'Pick a time from today, up to now');
    expect(find.text('Pick a time from today, up to now'), findsOneWidget);
  });

  testWidgets('VoiceOver labels', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await pump(tester);
      final time = find.semantics.byLabel('Time, 12:05 PM').evaluate().single;
      expect(time, isSemantics(isButton: true, hasTapAction: true));
      expect(time.getSemanticsData().hint, 'Double tap to change');
      expect(find.semantics.byLabel(RegExp(r'^Meal, Lunch')), findsWidgets);
    } finally {
      handle.dispose();
    }
  });
}
```

Create `test/time_meal_edit_test.dart`. Copy `_RecordingHealth` and the Health-sync setup from `test/serving_edit_test.dart` (it subclasses `HealthKitService` and records `delete <carbs>` and `write <carbs>`). Extend it to record the times too: `'delete ${item.loggedAt.hour}:${item.loggedAt.minute}'` and the same for write.

```dart
import 'package:carb_tracker/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.now();
  final lunch = {
    'id': 'l1',
    'name': 'Soup',
    'carbs': 20.0,
    'category': 'lunch',
    'loggedAt': now.toIso8601String(),
  };

  Future<CarbTrackerHomeState> openSoup(WidgetTester tester,
      {List<TimeOfDay?> picks = const []}) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs([lunch]));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final queue = [...picks];
    state.pickTime = (_, __) async => queue.isEmpty ? null : queue.removeAt(0);
    final handle = tester.ensureSemantics();
    tester.semantics.performAction(
        find.semantics.byLabel(RegExp(r'^Soup,')), SemanticsAction.tap);
    await tester.pumpAndSettle();
    handle.dispose();
    return state;
  }

  // Midnight is always today and never later than now (reset hour 0).
  const midnight = TimeOfDay(hour: 0, minute: 0);

  testWidgets('a new time moves the food to the meal for that time', (tester) async {
    final state = await openSoup(tester, picks: [midnight]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(find.text('Time · 12:00 AM'), findsOneWidget);
    expect(find.text('Snack'), findsWidgets); // the meal dropdown followed the time

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    final soup = state.foodItems.single;
    expect(soup.loggedAt.hour, 0);
    expect(soup.loggedAt.minute, 0);
    expect(soup.category.name, 'snack');
    expect(soup.updatedAt, isNotNull);
    expect(find.text('Moved to Snack, 12:00 AM'), findsOneWidget);
  });

  testWidgets('a meal picked by hand stays when the time changes', (tester) async {
    final state = await openSoup(tester, picks: [midnight]);
    await tester.tap(find.text('Lunch').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dinner').last);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(state.foodItems.single.category.name, 'dinner');
  });

  testWidgets('a time outside today is refused inside the dialog', (tester) async {
    final state = await openSoup(tester, picks: [const TimeOfDay(hour: 23, minute: 59)]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    // At 23:59 itself this pick is valid; skip in that one minute.
    if (now.hour == 23 && now.minute == 59) return;
    expect(find.text('Pick a time from today, up to now'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
    expect(state.foodItems.single.loggedAt, now);
  });

  testWidgets('Health moves the entry: delete at the old time, then write at the new',
      (tester) async {
    final state = await openSoup(tester, picks: [midnight]);
    final health = _RecordingHealth();
    state.healthKitService = health;
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(health.calls, ['delete ${now.hour}:${now.minute}', 'write 0:0']);
  });

  testWidgets('VoiceOver hears the new meal and time', (tester) async {
    final announcements = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility, (message) async {
      final map = message as Map;
      if (map['type'] == 'announce') {
        announcements.add((map['data'] as Map)['message'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, null));
    await openSoup(tester, picks: [midnight]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(announcements, contains('Snack, 12:00 AM'));
  });
}
```

Add at the top of this test file (after the imports, which also need
`import 'package:carb_tracker/models/food_item.dart';`,
`import 'package:carb_tracker/services/health_kit_service.dart';` and
`import 'package:flutter/services.dart';`):

```dart
/// Stands in for HealthKit (Health sync is always on), recording the time of
/// each sample it deletes or writes. Same idea as test/serving_edit_test.dart.
class _RecordingHealth extends HealthKitService {
  final calls = <String>[];

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    calls.add('delete ${item.loggedAt.hour}:${item.loggedAt.minute}');
    return true;
  }

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.loggedAt.hour}:${item.loggedAt.minute}');
    return true;
  }
}
```

If the dropdown's selected item and its menu both show "Lunch", use `.last`/`.first` as needed. If the details dialog opens differently than this (for example with a long-press), follow `test/serving_edit_test.dart`'s `openRow`.

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/time_meal_row_test.dart test/time_meal_edit_test.dart`
Expected: FAIL. `TimeMealRow` and `pickTime` don't exist yet.

- [ ] **Step 3: Implement the row**

Create `lib/widgets/time_meal_row.dart`:

```dart
import 'package:flutter/material.dart';

import '../models/food_item.dart';
import '../utils/a11y_labels.dart';
import '../utils/date_format.dart';

/// In a food's details: when it was eaten and which meal it counts toward.
/// Controlled — the caller opens the time picker (so it can refuse times
/// outside today) and owns the draft.
class TimeMealRow extends StatelessWidget {
  const TimeMealRow({
    super.key,
    required this.time,
    required this.meal,
    required this.onPickTime,
    required this.onMealChanged,
    this.error,
  });

  final DateTime time;
  final FoodCategory meal;
  final VoidCallback onPickTime;
  final ValueChanged<FoodCategory> onMealChanged;

  /// Shown under the row, e.g. when a picked time was outside today.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: timeRowLabel(formatTime(time)),
                hint: 'Double tap to change',
                onTap: onPickTime,
                excludeSemantics: true,
                child: InkWell(
                  onTap: onPickTime,
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Row(
                      children: [
                        Icon(Icons.schedule, size: 18, color: colorScheme.onSurface),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Time · ${formatTime(time)}',
                            style: TextStyle(fontSize: 15, color: colorScheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: mealDropdownLabel(meal.label),
              child: DropdownButton<FoodCategory>(
                value: meal,
                underline: const SizedBox.shrink(),
                items: [
                  for (final category in FoodCategory.values)
                    DropdownMenuItem(
                      value: category,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(category.icon, size: 18, color: category.color),
                          const SizedBox(width: 6),
                          Text(category.label),
                        ],
                      ),
                    ),
                ],
                onChanged: (category) {
                  if (category != null) onMealChanged(category);
                },
              ),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error!,
              style: TextStyle(fontSize: 12, color: colorScheme.error),
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 4: Wire it into the details dialog (`lib/main.dart`)**

1. Import `widgets/time_meal_row.dart`, `utils/picked_time.dart` and `utils/date_format.dart` (if it isn't imported yet).
2. Add the test hook near the other test hooks:

```dart
  /// Opens the time picker for the details dialog. A test replaces it to
  /// pick a time without driving the Material picker.
  @visibleForTesting
  Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial) pickTime =
      (context, initial) => showTimePicker(context: context, initialTime: initial);
```

3. In `_showFoodDetails`, next to `ServingInfo? draft = item.serving;`, add:

```dart
    DateTime draftTime = item.loggedAt;
    FoodCategory draftMeal = item.category;
    // Set once the meal is picked by hand in this edit; until then the meal
    // follows the time.
    var mealPicked = false;
    String? timeError;
```

4. In the builder, replace the `changed` and `shown` lines with:

```dart
          final servingChanged = draft != null && draft != item.serving;
          final changed = servingChanged ||
              draftTime != item.loggedAt ||
              draftMeal != item.category;
          final shown = changed
              ? item.edited(
                  serving: servingChanged ? draft : null,
                  loggedAt: draftTime,
                  category: draftMeal,
                  now: DateTime.now().toUtc(),
                )
              : item;
```

   Change the "was X g" line's guard from `if (changed)` to `if (servingChanged)`. Leave the other uses of `changed` as they are: the Update action and hiding "Save to Food list".
5. Make the `TimeMealRow` the first child of the dialog content's `Column`, followed by `const SizedBox(height: 8)`:

```dart
                  TimeMealRow(
                    time: draftTime,
                    meal: draftMeal,
                    error: timeError,
                    onPickTime: () async {
                      final picked = await pickTime(
                          context, TimeOfDay.fromDateTime(draftTime));
                      if (picked == null) return;
                      final resolved = resolvePickedTime(picked,
                          now: DateTime.now(), resetHour: resetHour);
                      if (resolved == null) {
                        setDialogState(
                            () => timeError = 'Pick a time from today, up to now');
                        return;
                      }
                      // The same minute as now shown changes nothing (the
                      // logged time also has seconds).
                      if (formatTime(resolved) == formatTime(draftTime) &&
                          dayKey(resolved, resetHour) == dayKey(draftTime, resetHour)) {
                        setDialogState(() => timeError = null);
                        return;
                      }
                      setDialogState(() {
                        timeError = null;
                        draftTime = resolved;
                        if (!mealPicked) draftMeal = FoodCategory.fromTime(resolved);
                      });
                      if (!context.mounted) return;
                      SemanticsService.sendAnnouncement(View.of(context),
                          '${draftMeal.label}, ${formatTime(draftTime)}', TextDirection.ltr);
                    },
                    onMealChanged: (meal) {
                      setDialogState(() {
                        mealPicked = true;
                        draftMeal = meal;
                      });
                      SemanticsService.sendAnnouncement(View.of(context),
                          '${meal.label}, ${formatTime(draftTime)}', TextDirection.ltr);
                    },
                  ),
                  const SizedBox(height: 8),
```

   `resetHour` is the state's existing field, and `dayKey` comes from `utils/day_key.dart`, which is already imported for `_todayString`.
6. In `_updateFoodItem`, replace the confirmation's text with:

```dart
          content: Text(updated.carbs != old.carbs
              ? 'Updated to ${updated.carbs.toStringAsFixed(1)} g'
              : 'Moved to ${updated.category.label}, ${formatTime(updated.loggedAt)}'),
```

- [ ] **Step 5: Run the tests**

Run: `flutter test test/time_meal_row_test.dart test/time_meal_edit_test.dart test/serving_edit_test.dart`
Expected: PASS. Serving edits must keep saying "Updated to …". Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/time_meal_row.dart lib/main.dart test/time_meal_row_test.dart test/time_meal_edit_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): change a logged food's time and meal from its details"
```

---

### Task 4: Examples for new users

**Files:**
- Create: `lib/widgets/example_prompts.dart`
- Modify: `lib/main.dart` (the empty state, `_useExample`, and a `_quickLogLoaded` flag)
- Test: `test/example_prompts_test.dart`, `test/example_prompts_home_test.dart`

**Interfaces:**
- Consumes:
  - `exampleChipLabel` (Task 1)
  - `lookupStatusColor({required bool dark})` (existing, `lib/utils/lookup_progress.dart`)
  - `_quickChips` and `_reloadQuickLog` (existing)
- Produces:
  - `const List<String> examplePrompts`
  - `ExamplePrompts({required ValueChanged<String> onPick})`

- [ ] **Step 1: Write the failing tests**

Create `test/example_prompts_test.dart`:

```dart
import 'package:carb_tracker/widgets/example_prompts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the examples and the tip; a tap reports the example',
      (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ExamplePrompts(onPick: picked.add))));
    expect(find.text('Try something like:'), findsOneWidget);
    for (final e in examplePrompts) {
      expect(find.text(e), findsOneWidget);
    }
    expect(find.text('Include how much you had — it makes the carbs more accurate.'),
        findsOneWidget);
    await tester.tap(find.text('2 slices pepperoni pizza'));
    expect(picked, ['2 slices pepperoni pizza']);
    expect(tester.getSize(find.ancestor(
            of: find.text('2 slices pepperoni pizza'),
            matching: find.byType(ConstrainedBox)).first).height,
        greaterThanOrEqualTo(44));
  });

  testWidgets('VoiceOver: a heading and example buttons', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ExamplePrompts(onPick: (_) {}))));
      expect(find.semantics.byLabel('Try something like:').evaluate().single,
          isSemantics(isHeader: true));
      expect(
          find.semantics.byLabel('Use example, 2 slices pepperoni pizza').evaluate().single,
          isSemantics(isButton: true, hasTapAction: true));
    } finally {
      handle.dispose();
    }
  });
}
```

Create `test/example_prompts_home_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/perplexity_firebase_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

class _CountingLookup extends PerplexityFirebaseService {
  int calls = 0;
  @override
  Future<LookupResult> getMultipleCarbCounts(String input) {
    calls++;
    return Completer<LookupResult>().future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester,
      {List<FoodItem> saved = const []}) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const [], extra: {
      'saved_foods': jsonEncode([for (final f in saved) f.toJson()]),
    }));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  testWidgets('a new user with an empty day sees the examples', (tester) async {
    await start(tester);
    expect(find.text('Try something like:'), findsOneWidget);
    expect(find.text('Type a food name above to look up its carbs.'), findsNothing);
  });

  testWidgets('someone with saved foods sees the usual empty line instead',
      (tester) async {
    await start(tester, saved: [FoodItem(name: 'Oatmeal', carbs: 27)]);
    expect(find.text('Try something like:'), findsNothing);
    expect(find.text('Type a food name above to look up its carbs.'), findsOneWidget);
  });

  testWidgets('an example fills the food field and looks nothing up', (tester) async {
    final state = await start(tester);
    final lookup = _CountingLookup();
    state.perplexityService = lookup;

    await tester.tap(find.text('Enter carbs yourself'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 cup cooked white rice'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'What did you eat?'));
    expect(field.controller!.text, '1 cup cooked white rice');
    expect(field.controller!.selection.baseOffset, '1 cup cooked white rice'.length);
    expect(find.text('Look it up instead'), findsNothing); // back in lookup mode
    expect(lookup.calls, 0);
  });
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/example_prompts_test.dart test/example_prompts_home_test.dart`
Expected: FAIL, because `example_prompts.dart` doesn't exist yet.

- [ ] **Step 3: Implement the widget**

Create `lib/widgets/example_prompts.dart`:

```dart
import 'package:flutter/material.dart';

import '../utils/a11y_labels.dart';
import '../utils/lookup_progress.dart';

/// Foods with amounts, to show a new user what to type.
const List<String> examplePrompts = [
  '2 slices pepperoni pizza',
  'Chipotle chicken burrito bowl',
  '1 cup cooked white rice',
  'Grande oat milk latte',
];

/// The empty Today list for someone with nothing logged or saved yet. Teaches
/// that the amount is what makes a lookup accurate. A tap only fills the food
/// field, so nothing is looked up (or counted against the free quota) until
/// the user taps Add.
class ExamplePrompts extends StatelessWidget {
  const ExamplePrompts({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Semantics(
            header: true,
            child: Text(
              'Try something like:',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final example in examplePrompts)
                Semantics(
                  button: true,
                  label: exampleChipLabel(example),
                  onTap: () => onPick(example),
                  excludeSemantics: true,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Material(
                      color: colorScheme.surfaceContainerHighest,
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => onPick(example),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Text(
                            example,
                            style: TextStyle(
                                fontSize: 14, color: colorScheme.onSurface),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Include how much you had — it makes the carbs more accurate.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: lookupStatusColor(dark: dark)),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Wire it into `lib/main.dart`**

1. Import `widgets/example_prompts.dart`.
2. Add the flag next to `_quickChips`:

```dart
  /// Whether the quick-add row has loaded at least once. The examples wait
  /// for it, so someone with saved foods never sees them flash at launch.
  bool _quickLogLoaded = false;
```

   In `_reloadQuickLog`, set it in the same `setState` that assigns `_quickChips`:
   `setState(() { _quickChips = ...; _quickLogLoaded = true; });`
   In its `catch`, also set it when mounted: `if (mounted) setState(() => _quickLogLoaded = true);`.
3. Add next to `_toggleEntryMode`:

```dart
  /// A first-run example: fill the food field with it and leave the lookup
  /// to the user.
  void _useExample(String text) {
    setState(() {
      _isManualEntryMode = false;
      _carbController.clear();
      _foodController.text = text;
      _foodController.selection = TextSelection.collapsed(offset: text.length);
    });
    _foodFocusNode.requestFocus();
  }
```

4. In `_buildHomePage`, change the empty branch of `foodItems.isEmpty ? Center(...) : ...` to:

```dart
                foodItems.isEmpty
                    ? (_quickLogLoaded && _quickChips.isEmpty
                        ? ExamplePrompts(onPick: _useExample)
                        : Center(/* the existing empty-state Padding/Text, unchanged */))
                    : ...
```

- [ ] **Step 5: Run the tests**

Run: `flutter test test/example_prompts_test.dart test/example_prompts_home_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

Existing tests that start with no foods and no saved or recent foods, and look for `'Type a food name above to look up its carbs.'`, will now see the examples. Update only those assertions, to expect `'Try something like:'`, and list each one in the report.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/example_prompts.dart lib/main.dart test/example_prompts_test.dart test/example_prompts_home_test.dart
# plus any existing tests whose empty-state assertion changed
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): example foods for new users on an empty day"
```

---

## After the tasks (controller)

- Run `flutter build ios --simulator --debug` in the main repo.
- Device check (Xcode debug build):
  - the link and the carbs field with the real keyboard;
  - the time picker within today, including with a reset hour;
  - an edited time showing up at the new time in Apple Health;
  - examples on a fresh install;
  - large text sizes.
