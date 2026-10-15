# Labelled Settings Tabs, "Saved" Naming, Clear Today with Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** This plan makes three changes:
- Give every Settings tab a visible name.
- Call saved foods "Saved" everywhere.
- Replace the one-tap Reset with a ⋯ menu that clears today's log, with Undo.

**Architecture:**
- **Settings tabs:** a `SettingsTabBar` widget, with testable colour helpers, replaces the inline tab row in `settings_page.dart`.
- **Renaming:** three strings in `main.dart` and one tab label change.
- **Clear and Undo:**
  - A pure `restoreCleared` decides what Undo puts back.
  - `_resetTotal` returns what it cleared and keeps its Apple Health deletes, so Undo can wait for them before writing the foods back. Otherwise a late delete could remove a restored sample, because both use the same millisecond window.

**Tech Stack:** Flutter/Dart and `flutter_test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-15-tabs-and-clear-design.md`

## Global Constraints

**Settings tabs**
- **Labels:** `Saved`, `History`, `Goals`, `Features`. The icons are unchanged.
- **Layout:**
  - Four equal-width segments, each with its icon (20 pt) above its name.
  - The name is 12 pt, weight 500, on one line, cut off with an ellipsis if needed.
  - Each segment is at least 44 pt tall, with corner radius 12.
- **Selected segment:** fill `settingsTabSelectedFill()` = `Color.lerp(AppColors.sage, Colors.black, 0.35)`, with a white icon and text.
- **Unselected segment:** transparent, with the icon and text in `settingsTabUnselected(dark:)` = `lookupStatusColor(dark:)`.
- **Contrast:** at least 4.5:1, white on the fill and unselected on the page background (`AppColors.cream` in light mode, `AppColors.darkBackground` in dark mode).
- **VoiceOver:** each segment is a button labelled with its name, with the `selected` state.
- **Tapping a segment** dismisses the keyboard, gives a light haptic and selects the tab, as today.

**"Saved" naming**
- The details dialog action and the food row's VoiceOver custom action are `Save`.
- The snackbar after saving reads `<name> saved`.

**Today ⋯ menu**
- A `PopupMenuButton` with `Icons.more_horiz` and tooltip `Today options`, coloured `onSurfaceVariant`, with a 44 pt or larger target.
- It holds one item: `Clear today's log…`.

**Confirm dialog**
- Title `Clear today's log?`.
- Body `All N foods will be removed from today and from Apple Health.`, or `This food will be removed from today and from Apple Health.` when there is one food.
- Actions `Cancel` and `Clear`, with Clear in terracotta.

**After Clear**
- Snackbar `Today's log cleared`, with `Undo`, shown for 6 s.

**What Undo does**
- If `_todayString()` has changed since the Clear, it does nothing.
- Otherwise it puts back the foods `restoreCleared(foodItems, cleared)` returns, and their rows animate in.
- For each restored food it calls `recordItemRestored(id)`, then saves once and updates the widget.
- It waits for the Clear's Health deletes to finish, then writes each restored food to Health.
- It never touches saved or recent foods.

**Commits**
- Use `git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit ...`.
- NO `Co-Authored-By` trailer and no Claude/Claude Code attribution of any kind.
- Use explicit `git add` paths only. Never commit `iap_review_screenshot.png`.

**Checks**
- Before each commit: `flutter analyze lib test` reports no issues, and the task's tests pass.
- At the end of every task: the full `flutter test` passes. It was at 469 before this plan.

---

### Task 1: Labelled Settings tabs

**Files:**
- Create: `lib/widgets/settings_tab_bar.dart`
- Modify: `lib/screens/settings_page.dart` (the tab row in `build`, and `_tabLabels`)
- Modify: `test/a11y_totals_test.dart` (`'Favorites'` becomes `'Saved'`)
- Test: `test/settings_tab_bar_test.dart`

**Interfaces:**
- Produces:
  - `typedef SettingsTab = ({IconData icon, String label})`
  - `Color settingsTabSelectedFill()`
  - `Color settingsTabUnselected({required bool dark})`
  - `SettingsTabBar({required List<SettingsTab> tabs, required int selected, required ValueChanged<int> onSelected})`

- [ ] **Step 1: Write the failing tests**

Create `test/settings_tab_bar_test.dart`:

```dart
import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/widgets/settings_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/contrast.dart';

const List<SettingsTab> _tabs = [
  (icon: Icons.bookmark_border, label: 'Saved'),
  (icon: Icons.history, label: 'History'),
  (icon: Icons.adjust, label: 'Goals'),
  (icon: Icons.workspace_premium, label: 'Features'),
];

void main() {
  test('tab colours are readable', () {
    expect(contrastRatio(Colors.white, settingsTabSelectedFill()),
        greaterThanOrEqualTo(4.5));
    expect(contrastRatio(settingsTabUnselected(dark: false), AppColors.cream),
        greaterThanOrEqualTo(4.5));
    expect(contrastRatio(settingsTabUnselected(dark: true), AppColors.darkBackground),
        greaterThanOrEqualTo(4.5));
  });

  Future<List<int>> pump(WidgetTester tester,
      {int selected = 0, double width = 400, double textScale = 1}) async {
    final taps = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            size: Size(width, 800), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: width - 48,
              child: SettingsTabBar(tabs: _tabs, selected: selected, onSelected: taps.add),
            ),
          ),
        ),
      ),
    ));
    return taps;
  }

  testWidgets('every tab shows its name; a tap selects it', (tester) async {
    final taps = await pump(tester);
    for (final t in _tabs) {
      expect(find.text(t.label), findsOneWidget);
    }
    await tester.tap(find.text('History'));
    expect(taps, [1]);
    expect(tester.getSize(find.ancestor(
            of: find.text('Goals'), matching: find.byType(ConstrainedBox)).first).height,
        greaterThanOrEqualTo(44));
  });

  testWidgets('VoiceOver: buttons with names and the selected state', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await pump(tester, selected: 2);
      expect(find.semantics.byLabel('Goals').evaluate().single,
          isSemantics(isButton: true, isSelected: true, hasTapAction: true));
      expect(find.semantics.byLabel('Saved').evaluate().single,
          isSemantics(isButton: true, isSelected: false, hasTapAction: true));
    } finally {
      handle.dispose();
    }
  });

  testWidgets('no overflow at double text on a small phone', (tester) async {
    await pump(tester, width: 320, textScale: 2);
    expect(tester.takeException(), isNull);
  });
}
```

In `test/a11y_totals_test.dart`, change the two `find.text('Favorites')` to `find.text('Saved')`. Then update the comment above the second one. It currently says only the selected tab renders its label, which is no longer true. The check now confirms that the Settings page is showing: its tab names are only on screen when the page is.

If either assertion no longer holds because the tab names are always visible, keep the test's intent and say what you changed in the report. The intent is that Settings isn't on screen before the action and is after it.

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/settings_tab_bar_test.dart`
Expected: FAIL. `settings_tab_bar.dart` doesn't exist yet.

- [ ] **Step 3: Implement the widget**

Create `lib/widgets/settings_tab_bar.dart`:

```dart
import 'package:flutter/material.dart';

import '../config/app_colors.dart';
import '../utils/lookup_progress.dart';

typedef SettingsTab = ({IconData icon, String label});

/// The selected tab's fill: sage darkened so white text on it reads at 4.5:1
/// (plain sage is about 2.7:1).
Color settingsTabSelectedFill() =>
    Color.lerp(AppColors.sage, Colors.black, 0.35)!;

/// Unselected tabs' icon and name: the same readable grey as other small
/// secondary text.
Color settingsTabUnselected({required bool dark}) => lookupStatusColor(dark: dark);

/// Settings' tabs, each named under its icon so none is a bare icon.
class SettingsTabBar extends StatelessWidget {
  const SettingsTabBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final List<SettingsTab> tabs;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        for (var i = 0; i < tabs.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Semantics(
                button: true,
                selected: i == selected,
                label: tabs[i].label,
                onTap: () => onSelected(i),
                excludeSemantics: true,
                child: Material(
                  color: i == selected
                      ? settingsTabSelectedFill()
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onSelected(i),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              tabs[i].icon,
                              size: 20,
                              color: i == selected
                                  ? Colors.white
                                  : settingsTabUnselected(dark: dark),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              tabs[i].label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: i == selected
                                    ? Colors.white
                                    : settingsTabUnselected(dark: dark),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 4: Use it in Settings**

In `lib/screens/settings_page.dart`:
- Import `../widgets/settings_tab_bar.dart`.
- Change `_tabLabels` to `['Saved', 'History', 'Goals', 'Features']`.
- In `build`, replace the whole `// Tab bar with icons` `Padding(... Row(... List.generate(...)))` with:

```dart
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: SettingsTabBar(
            tabs: [
              for (var i = 0; i < _tabLabels.length; i++)
                (icon: _tabIcons[i], label: _tabLabels[i]),
            ],
            selected: _selectedTab,
            onSelected: (index) {
              _dismissKeyboard();
              HapticFeedback.lightImpact();
              setState(() => _selectedTab = index);
            },
          ),
        ),
```

Keep the `const SizedBox(height: 16)` and the `IndexedStack` below it unchanged.

- [ ] **Step 5: Run the tests**

Run: `flutter test test/settings_tab_bar_test.dart test/a11y_totals_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

Other tests may tap Settings tabs by their old icon, or expect only the selected label to be visible. Update only those finders, and list each change in the report.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/settings_tab_bar.dart lib/screens/settings_page.dart test/settings_tab_bar_test.dart test/a11y_totals_test.dart
# plus any other test files whose finders changed in Step 5
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(settings): name every tab, and read them as tabs to VoiceOver"
```

---

### Task 2: "Saved" naming in the home screen

**Files:**
- Modify: `lib/main.dart`
  - the `'Save to Food list'` action in `_showFoodDetails`
  - the `CustomSemanticsAction(label: 'Save to Food list')` in `_buildFoodTile`
  - the `'${item.name} saved to Food list'` snackbar in `_saveToSavedFoods`
- Modify tests that use the old strings:
  - `test/a11y_food_row_test.dart`
  - `test/serving_edit_test.dart`

**Interfaces:** none new.

- [ ] **Step 1: Update the tests first (they become the failing tests)**

Make these replacements:
- In `test/a11y_food_row_test.dart`, replace every `'Save to Food list'` with `'Save'`. That covers the custom action label, the dialog `find.text` and the tap.
- In `test/serving_edit_test.dart`, replace `find.text('Save to Food list')` with `find.text('Save')`. Rename the test `'Save to Food list is hidden while a serving change is pending'` to `'Save is hidden while a serving change is pending'`.
- Add this assertion to one existing test that saves a food (for example in `a11y_food_row_test.dart`, after the tap on Save):
  `expect(find.text('<that food's name> saved'), findsOneWidget);`
  Use the food name that test logs.

If `find.text('Save')` also matches another widget on screen in one of these tests, scope it to the dialog with `find.descendant(of: find.byType(AlertDialog), matching: find.text('Save'))`.

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/a11y_food_row_test.dart test/serving_edit_test.dart`
Expected: FAIL, because the app still says "Save to Food list".

- [ ] **Step 3: Implement**

In `lib/main.dart`:
- Change the details dialog's `child: const Text('Save to Food list')` to `child: const Text('Save')`. Update the comment above it that says "Saves the logged copy, so not while a different serving is pending." only if it names the old label.
- Change `const CustomSemanticsAction(label: 'Save to Food list')` to `const CustomSemanticsAction(label: 'Save')`.
- Change `content: Text('${item.name} saved to Food list')` to `content: Text('${item.name} saved')`.

- [ ] **Step 4: Run the tests**

Run: `flutter test test/a11y_food_row_test.dart test/serving_edit_test.dart`
Expected: PASS. Then run `grep -rn "Food list" lib test` and confirm it prints no user-visible strings (comments are fine). Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/a11y_food_row_test.dart test/serving_edit_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): call saved foods Saved everywhere"
```

---

### Task 3: Clear today's log, with Undo

**Files:**
- Create: `lib/models/clear_today.dart`
- Modify: `lib/main.dart`: the TODAY header, `_confirmReset` (renamed `_confirmClearToday`), `_resetTotal`, the new `_undoClearToday`, and the Health-delete tracking
- Modify: `test/widget_test.dart` and `test/a11y_controls_test.dart` (the old Reset button)
- Test: `test/clear_today_test.dart`, `test/clear_today_home_test.dart`

**Interfaces:**
- Produces:
  - `List<FoodItem> restoreCleared(List<FoodItem> current, List<FoodItem> cleared)`
  - On `CarbTrackerHomeState`:
    - `List<FoodItem> _resetTotal()`, which returns the cleared snapshot
    - `Future<void>? _clearHealthDeletes`
    - `void _confirmClearToday()`
    - `Future<void> _undoClearToday(List<FoodItem> cleared, String day)`

- [ ] **Step 1: Write the failing tests**

Create `test/clear_today_test.dart`:

```dart
import 'package:carb_tracker/models/clear_today.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = FoodItem(id: 'a', name: 'A', carbs: 1);
  final b = FoodItem(id: 'b', name: 'B', carbs: 2);
  final c = FoodItem(id: 'c', name: 'C', carbs: 3);

  test('nothing back yet: all of them, in order', () {
    expect(restoreCleared([], [a, b, c]).map((f) => f.id), ['a', 'b', 'c']);
  });

  test('foods already on the list are not put back twice', () {
    final logged = FoodItem(id: 'new', name: 'New', carbs: 9);
    expect(restoreCleared([logged, b], [a, b, c]).map((f) => f.id), ['a', 'c']);
  });

  test('nothing cleared, nothing back', () {
    expect(restoreCleared([a], []), isEmpty);
  });
}
```

Create `test/clear_today_home_test.dart`:

```dart
import 'dart:async';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

/// Records Health calls in order. Deletes finish only when [releaseDeletes]
/// is called, to prove Undo waits for them before writing.
class _SlowHealth extends HealthKitService {
  final calls = <String>[];
  final _deletes = Completer<void>();

  void releaseDeletes() => _deletes.complete();

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    await _deletes.future;
    calls.add('delete ${item.name}');
    return true;
  }

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.name}');
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> food(String id, String name, double carbs, int minutesAgo) => {
        'id': id,
        'name': name,
        'carbs': carbs,
        'category': 'lunch',
        'loggedAt':
            DateTime.now().subtract(Duration(minutes: minutesAgo)).toIso8601String(),
      };

  Future<CarbTrackerHomeState> start(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs([
      food('s', 'Soup', 20, 3),
      food('r', 'Roll', 32, 2),
    ]));
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  Future<void> openClear(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Today options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Clear today's log…"));
    await tester.pumpAndSettle();
  }

  testWidgets('the menu asks first, with the number of foods; Cancel keeps them',
      (tester) async {
    final state = await start(tester);
    await openClear(tester);
    expect(find.text("Clear today's log?"), findsOneWidget);
    expect(find.text('All 2 foods will be removed from today and from Apple Health.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.foodItems.length, 2);
  });

  testWidgets('Clear empties today; Undo puts the foods back, in Health too, after the deletes',
      (tester) async {
    final state = await start(tester);
    final health = _SlowHealth();
    state.healthKitService = health;

    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(state.foodItems, isEmpty);
    expect(find.text("Today's log cleared"), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(health.calls.where((c) => c.startsWith('write')), isEmpty,
        reason: 'Undo must not write before the Clear deletes finish');
    health.releaseDeletes();
    await tester.pumpAndSettle();

    expect(state.foodItems.map((f) => f.id).toSet(), {'s', 'r'});
    final firstWrite = health.calls.indexWhere((c) => c.startsWith('write'));
    final lastDelete = health.calls.lastIndexWhere((c) => c.startsWith('delete'));
    expect(firstWrite, greaterThan(lastDelete));
    expect(health.calls.where((c) => c.startsWith('write')).length, 2);
  });

  testWidgets('a food logged between Clear and Undo stays, and nothing doubles',
      (tester) async {
    final state = await start(tester);
    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Apple', carbs: 25)]));
    await tester.pumpAndSettle();
    final cleared = state.foodItems.length; // just the apple
    expect(cleared, 1);

    // The lookup's own snackbar may have replaced the cleared one; Undo is
    // driven directly here so the test is about what Undo restores.
    await state.undoClearTodayForTest();
    await tester.pumpAndSettle();
    expect(state.foodItems.map((f) => f.name).toSet(), {'Soup', 'Roll', 'Apple'});
    expect(state.foodItems.length, 3);
  });

  testWidgets('VoiceOver: the menu button is "Today options"', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester);
      expect(find.semantics.byLabel('Today options').evaluate().single,
          isSemantics(isButton: true, hasTapAction: true));
    } finally {
      handle.dispose();
    }
  });
}
```

That test uses a hook, `undoClearTodayForTest()`. It undoes the most recent clear and returns its Future. A test of "Undo after a day change does nothing" isn't feasible without a clock seam. Cover it in `test/clear_today_test.dart` instead, by making the day check a pure function:

```dart
  test('Undo only applies on the day it cleared', () {
    expect(undoApplies(clearedOn: '2026-10-15', today: '2026-10-15'), isTrue);
    expect(undoApplies(clearedOn: '2026-10-15', today: '2026-10-16'), isFalse);
  });
```

Add `bool undoApplies({required String clearedOn, required String today}) => clearedOn == today;`
to `lib/models/clear_today.dart`, and use it in `_undoClearToday`.

In `test/widget_test.dart`, change `expect(find.text('Reset'), findsOneWidget);` to
`expect(find.byTooltip('Today options'), findsOneWidget);`, and update the comment below it about the Reset button.

In `test/a11y_controls_test.dart`, change `find.semantics.byLabel('Reset')` to `find.semantics.byLabel('Today options')`.

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/clear_today_test.dart test/clear_today_home_test.dart test/widget_test.dart test/a11y_controls_test.dart`
Expected: FAIL, because `clear_today.dart` doesn't exist and there is no menu.

- [ ] **Step 3: Implement the pure helpers**

Create `lib/models/clear_today.dart`:

```dart
import 'food_item.dart';

/// The foods an Undo of "Clear today's log" puts back: those it cleared that
/// aren't on the list now, in their original order. A food logged since the
/// clear stays, and one a merge already brought back isn't added twice.
List<FoodItem> restoreCleared(List<FoodItem> current, List<FoodItem> cleared) {
  final present = {for (final food in current) food.id};
  return [
    for (final food in cleared)
      if (!present.contains(food.id)) food,
  ];
}

/// Undo applies only on the app day it cleared; after the day rolls over,
/// those foods belong to yesterday.
bool undoApplies({required String clearedOn, required String today}) =>
    clearedOn == today;
```

- [ ] **Step 4: Implement clear and Undo in `lib/main.dart`**

1. Import `models/clear_today.dart`.
2. Add these next to the other lookup and reset state:

```dart
  /// The Health deletes of the last "Clear today's log". Undo waits for them:
  /// a restored sample shares its millisecond window with the deleted one, so
  /// a delete that finished after the write would remove it again.
  Future<void>? _clearHealthDeletes;

  /// The last clear, for the test hook below.
  ({List<FoodItem> cleared, String day})? _lastClear;
```

3. Replace `_resetTotal` with:

```dart
  /// Empties today: list, widget, iCloud (delete markers) and Apple Health.
  /// Returns what it cleared, for Undo.
  List<FoodItem> _resetTotal() {
    final snapshot = List<FoodItem>.from(foodItems);
    setState(() {
      foodItems.clear();
    });
    if (_premiumService.isHealthSyncEnabled) {
      _clearHealthDeletes = Future.wait([
        for (final item in snapshot) _healthKitService.deleteFoodItem(item),
      ]).then((results) => _reportHealthResult(results.every((ok) => ok)));
    }
    _saveAfterDeleting(snapshot.map((item) => item.id).toList());
    _updateWidget();
    return snapshot;
  }
```

4. Replace `_confirmReset` with `_confirmClearToday`:

```dart
  /// From the TODAY header's ⋯ menu. Asks first; after Clear, offers Undo.
  void _confirmClearToday() {
    if (foodItems.isEmpty) return;
    final count = foodItems.length;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Clear today's log?"),
        content: Text(count == 1
            ? 'This food will be removed from today and from Apple Health.'
            : 'All $count foods will be removed from today and from Apple Health.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              final cleared = _resetTotal();
              final day = _todayString();
              _lastClear = (cleared: cleared, day: day);
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text("Today's log cleared"),
                  duration: const Duration(seconds: 6),
                  action: SnackBarAction(
                    label: 'Undo',
                    textColor: Colors.white,
                    onPressed: () => _undoClearToday(cleared, day),
                  ),
                ),
              );
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.terracotta),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  /// Puts back what a clear removed, on the same day only: list, iCloud
  /// (delete markers lifted), widget, and Apple Health once the clear's
  /// deletes have finished.
  Future<void> _undoClearToday(List<FoodItem> cleared, String day) async {
    if (!mounted || !undoApplies(clearedOn: day, today: _todayString())) return;
    final back = restoreCleared(foodItems, cleared);
    if (back.isEmpty) return;
    setState(() {
      foodItems.addAll(back);
      _markArriving(back);
    });
    for (final item in back) {
      await _syncStore.recordItemRestored(item.id);
    }
    await _saveData();
    await _updateWidget();
    if (_premiumService.isHealthSyncEnabled) {
      await _clearHealthDeletes;
      for (final item in back) {
        _writeToHealthKit(item);
      }
    }
  }
```

5. Add a test hook next to `resetTotalForTest`:

```dart
  @visibleForTesting
  Future<void> undoClearTodayForTest() async {
    final last = _lastClear;
    if (last != null) await _undoClearToday(last.cleared, last.day);
  }
```

   `resetTotalForTest` stays `void resetTotalForTest() => _resetTotal();`, which still compiles with the new return type.
6. In the TODAY header, replace the whole `Semantics(button: true, child: GestureDetector(onTap: _confirmReset, child: Row([Icon(Icons.refresh...), Text('Reset')])))` and its comment with:

```dart
                        // Clearing the whole day is one item in a menu, not a
                        // button next to the list, and it can be undone.
                        PopupMenuButton<void>(
                          tooltip: 'Today options',
                          icon: Icon(
                            Icons.more_horiz,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          itemBuilder: (context) => [
                            PopupMenuItem<void>(
                              onTap: _confirmClearToday,
                              child: const Text("Clear today's log…"),
                            ),
                          ],
                        ),
```

   `PopupMenuItem.onTap` runs as the menu closes. If the confirm dialog doesn't appear because the menu's route is still popping, defer it:
   `onTap: () => WidgetsBinding.instance.addPostFrameCallback((_) => _confirmClearToday())`.

- [ ] **Step 5: Run the tests**

Run: `flutter test test/clear_today_test.dart test/clear_today_home_test.dart test/widget_test.dart test/a11y_controls_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass, with no pending-timer failures).

- [ ] **Step 6: Commit**

```bash
git add lib/models/clear_today.dart lib/main.dart test/clear_today_test.dart test/clear_today_home_test.dart test/widget_test.dart test/a11y_controls_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): clear today's log from a menu, with Undo"
```

---

## After the tasks (controller)

- Run `flutter build ios --simulator --debug` in the main repo.
- Device check, with an Xcode debug build:
  - Tabs at the largest text size and in dark mode.
  - With Health sync on, Clear, then Undo, and the foods are back in Apple Health.
  - A second device receives both the clear and the undo.
