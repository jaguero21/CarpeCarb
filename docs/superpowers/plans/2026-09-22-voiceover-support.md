# VoiceOver Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app usable with VoiceOver — above all, let someone delete a logged food or save one as a favourite, which today are swipe-only and therefore unreachable.

**Architecture:** Spoken wording lives in one pure module per platform (`lib/utils/a11y_labels.dart`, `CarbAccessibility` in `CarbShared`) so it is tested in one place and can't drift between the app and the widget. Each food row becomes a single VoiceOver element carrying two custom actions, which is where iOS users look for per-row actions; the same two actions also appear as buttons in the existing details dialog, for anyone who can't swipe at all. The rest is labels, roles and state on controls that are currently bare `GestureDetector`s.

**Tech Stack:** Flutter 3.41 / Dart 3.11, `flutter_test` (`isSemantics`, `find.semantics`, `SemanticsController.performAction`); Swift 6.4 toolchain, Swift Testing, SwiftUI accessibility modifiers.

**Spec:** `docs/superpowers/specs/2026-09-22-voiceover-support-design.md`

## Global Constraints

- Commits carry NO `Co-Authored-By` or other attribution trailer, and no "Generated with Claude Code" line. Use explicit `git add` paths only. Never stage `build/`, `ios/Pods/`, `lib/firebase_options.dart`, `ios/Runner/GoogleService-Info.plist`, or untracked files.
- Branch: `feature/voiceover-support` (the spec is already committed there).
- **No visual change.** Nothing in this batch may move, resize or recolour anything on screen. The one exception is a hit area: the Home/Settings icons keep their 40pt circle and gain a 44pt touch target around it.
- Spoken wording, exact: a food row reads `"<name>, <carbs> grams of carbs, logged <time>"`; the day's total reads `"<total> of <goal> grams"`, or `"<total> grams, no goal set"`; a value is spoken without a trailing `.0`, and `1` is `"1 gram"`, not `"1 grams"`.
- The two row actions are named exactly `Delete` and `Save to Food list`, in that order.
- **Every widget test that touches the home screen must seed `'disclaimer_accepted': true`.** Otherwise the disclaimer dialog covers the screen and nothing beneath it is in the accessibility tree — tests then pass or fail for the wrong reason.
- Tests that log or delete a food must stub the `com.carpecarb/cloudsync` channel; an unstubbed platform channel never answers in a widget test and the test hangs rather than failing.
- Don't run `dart format` over a whole pre-existing file; it reformats unrelated code and buries the change.
- Checks: `flutter analyze && flutter test` from the repo root; `cd ios/CarbShared && swift test`; and the iOS build **with its own DerivedData**, so it cannot leave ad-hoc-signed frameworks in the cache Xcode uses:
  `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/voiceover-dd CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.

## How to apply the edits in this plan

Every code block is the exact text that was built and tested. Copy it byte-for-byte.

- **New file:** `python3 .superpowers/sdd/extract_block.py TASK_BRIEF --list`, then `extract_block.py TASK_BRIEF N path/to/file`.
- **Edit to an existing file:** each edit is a "replace / with" pair of consecutive blocks.

```bash
python3 .superpowers/sdd/extract_block.py TASK_BRIEF N /tmp/old.txt
python3 .superpowers/sdd/extract_block.py TASK_BRIEF N+1 /tmp/new.txt
python3 .superpowers/sdd/replace_block.py path/to/file /tmp/old.txt /tmp/new.txt
```

If `replace_block.py` reports 0 or 2+ occurrences, stop and report NEEDS_CONTEXT rather than hand-editing.

## File Map

| File | Task | Responsibility |
|---|---|---|
| `lib/utils/a11y_labels.dart` | 1 | the spoken wording, as pure functions |
| `test/a11y_labels_test.dart` | 1 | its tests |
| `lib/main.dart` | 1–4, 6 | row element + actions, dialog buttons, control roles, the day total, sync labels, hit area, tap-catcher |
| `test/a11y_food_row_test.dart` | 1–2 | row and dialog tests |
| `lib/screens/settings_page.dart` | 3 | "Clear All" announces as a button |
| `test/a11y_controls_test.dart` | 3 | toggle, Reset, Clear All |
| `test/a11y_totals_test.dart` | 4 | the day total's label and value |
| `ios/CarbShared/Sources/CarbShared/CarbAccessibility.swift` | 5 | the widget's spoken wording |
| `ios/CarbShared/Tests/CarbSharedTests/CarbAccessibilityTests.swift` | 5 | its tests |
| `ios/CarbWiseWidget/CarbWiseWidget.swift` | 5 | the ring reads as one element |
| `test/a11y_guidelines_test.dart` | 6 | the one guideline the app meets, as a guard |

---

### Task 1: A food row is one element, with its two actions

**Files:**
- Create: `lib/utils/a11y_labels.dart`, `test/a11y_labels_test.dart`, `test/a11y_food_row_test.dart`
- Modify: `lib/main.dart`

**Interfaces:**
- Produces: `spokenGrams(double)`, `spokenNumber(double)`, `foodRowLabel({name, carbs, time})`, `carbProgressValue({total, goal})` — Task 4 uses the last one.
- `_buildFoodTile(FoodItem item, {int? index})` — `index` is null while a row animates out, where Delete would have nothing to act on.

- [ ] **Step 1: Write the wording and its tests**

Create `lib/utils/a11y_labels.dart`:

```dart
/// What VoiceOver reads for the parts of the app that are numbers, icons or
/// custom controls rather than plain text.
///
/// Pure functions, so the wording is tested in one place and can't drift from
/// screen to screen. They spell values out the way they should be spoken:
/// "25 grams", not the "25.0g" the card draws.
library;

/// A gram value as it should be spoken: "25 grams", "1 gram", "25.5 grams".
String spokenGrams(double value) => '${spokenNumber(value)} '
    '${spokenNumber(value) == '1' ? 'gram' : 'grams'}';

/// A number without a trailing ".0", which VoiceOver reads aloud as
/// "point zero".
String spokenNumber(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// One food in today's list, as a sentence rather than three separate stops:
/// "Apple, 25 grams of carbs, logged 8:30 AM".
String foodRowLabel({
  required String name,
  required double carbs,
  required String time,
}) =>
    '$name, ${spokenGrams(carbs)} of carbs, logged $time';

/// The day's progress bar, which otherwise announces nothing:
/// "45 of 100 grams", or "45 grams, no goal set" when no goal is set.
String carbProgressValue({required double total, double? goal}) =>
    goal == null || goal <= 0
        ? '${spokenGrams(total)}, no goal set'
        : '${spokenNumber(total)} of ${spokenGrams(goal)}';
```

Create `test/a11y_labels_test.dart`:

```dart
import 'package:carb_tracker/utils/a11y_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('spokenGrams', () {
    test('drops the trailing .0 VoiceOver would read as "point zero"', () {
      expect(spokenGrams(25), '25 grams');
    });

    test('keeps a real fraction', () {
      expect(spokenGrams(25.5), '25.5 grams');
    });

    test('says gram, singular, for one', () {
      expect(spokenGrams(1), '1 gram');
    });

    test('says zero grams rather than nothing', () {
      expect(spokenGrams(0), '0 grams');
    });
  });

  group('foodRowLabel', () {
    test('reads as one sentence, with units', () {
      expect(
        foodRowLabel(name: 'Apple', carbs: 25, time: '8:30 AM'),
        'Apple, 25 grams of carbs, logged 8:30 AM',
      );
    });
  });

  group('carbProgressValue', () {
    test('reads the total against the goal', () {
      expect(carbProgressValue(total: 45, goal: 100), '45 of 100 grams');
    });

    test('says so when no goal is set', () {
      expect(carbProgressValue(total: 45, goal: null), '45 grams, no goal set');
    });

    test('treats a zero goal as no goal, the way the app does elsewhere', () {
      expect(carbProgressValue(total: 45, goal: 0), '45 grams, no goal set');
    });
  });
}
```

Run: `flutter test test/a11y_labels_test.dart` → `+8: All tests passed!`

- [ ] **Step 2: Write the failing row tests**

Create `test/a11y_food_row_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  void stubChannels() {
    final appGroup = <String, Object?>{};
    messenger().setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      final args = (call.arguments as Map?) ?? const {};
      if (call.method == 'saveWidgetData') {
        appGroup[args['id'] as String] = args['data'];
        return true;
      }
      if (call.method == 'getWidgetData') return appGroup[args['id'] as String];
      return null;
    });
    // Logging or deleting saves and pushes; an unstubbed channel never answers.
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/siribuffer'), (call) async => null);
    addTearDown(() {
      for (final name in const [
        'home_widget',
        'com.carpecarb/cloudsync',
        'com.carpecarb/siribuffer',
      ]) {
        messenger().setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
  }

  void seedTwoFoods() {
    SharedPreferences.setMockInitialValues({
      'food_items': jsonEncode([
        {
          'id': 'a',
          'name': 'Apple',
          'carbs': 25.0,
          'loggedAt': '2026-09-22T08:30:00.000',
          'category': 'snack'
        },
        {
          'id': 'b',
          'name': 'Bagel',
          'carbs': 48.0,
          'loggedAt': '2026-09-22T08:00:00.000',
          'category': 'breakfast'
        },
      ]),
      'last_save_date': todayKey(),
      // Otherwise the disclaimer dialog covers the screen and the rows are not
      // in the accessibility tree at all.
      'disclaimer_accepted': true,
    });
  }

  /// Performs a named rotor action on the row whose label is [label].
  void performRotorAction(WidgetTester tester, String label, String action) {
    final finder = find.semantics.byLabel(label);
    final node = finder.evaluate().single;
    final id = node
        .getSemanticsData()
        .customSemanticsActionIds!
        .firstWhere((i) => CustomSemanticsAction.getAction(i)!.label == action);
    tester.semantics
        .performAction(finder, SemanticsAction.customAction, args: id);
  }

  testWidgets('a food row reads as one sentence with both actions',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(
      find.semantics
          .byLabel('Apple, 25 grams of carbs, logged 8:30 AM')
          .evaluate()
          .single,
      isSemantics(
        hint: 'Double tap for details',
        customActions: const [
          CustomSemanticsAction(label: 'Delete'),
          CustomSemanticsAction(label: 'Save to Food list'),
        ],
      ),
    );

    handle.dispose();
  });

  testWidgets('the Delete rotor action actually removes the food',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state =
        tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.foodItems.map((f) => f.name), ['Apple', 'Bagel']);

    // An advertised action that does nothing is worse than none.
    performRotorAction(
        tester, 'Apple, 25 grams of carbs, logged 8:30 AM', 'Delete');
    await tester.pump(const Duration(milliseconds: 400));

    expect(state.foodItems.map((f) => f.name), ['Bagel']);
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the Save rotor action saves the food to the Food list',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    performRotorAction(tester, 'Apple, 25 grams of carbs, logged 8:30 AM',
        'Save to Food list');
    await tester.pump(const Duration(milliseconds: 400));

    final saved =
        (await SharedPreferences.getInstance()).getString('saved_foods');
    expect(saved, contains('Apple'));
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });
}
```

- [ ] **Step 3: Run them and watch them fail**

Run: `flutter test test/a11y_food_row_test.dart`
Expected: all three fail. The row has no label to find, so the finders come up empty (`Bad state: No element`).

- [ ] **Step 4: Make the row one element with two actions**

In `lib/main.dart`:

**Edit 1 of 4 — replace:**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:keyboard_actions/keyboard_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:home_widget/home_widget.dart';
```

**with:**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:keyboard_actions/keyboard_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:home_widget/home_widget.dart';
```

**Edit 2 of 4 — replace:**

```dart
import 'models/food_item.dart';
import 'models/server_quota.dart';
import 'screens/settings_page.dart';
import 'config/app_colors.dart';
import 'config/app_theme.dart';
import 'config/storage_keys.dart';
import 'utils/date_format.dart';
import 'utils/day_key.dart';
import 'utils/input_validation.dart';
import 'utils/user_facing_exception.dart';
import 'widgets/food_item_card.dart';
```

**with:**

```dart
import 'models/food_item.dart';
import 'models/server_quota.dart';
import 'screens/settings_page.dart';
import 'config/app_colors.dart';
import 'config/app_theme.dart';
import 'config/storage_keys.dart';
import 'utils/a11y_labels.dart';
import 'utils/date_format.dart';
import 'utils/day_key.dart';
import 'utils/input_validation.dart';
import 'utils/user_facing_exception.dart';
import 'widgets/food_item_card.dart';
```

**Edit 3 of 4 — replace:**

```dart
  }

  /// Called by SettingsPage after it has written the favourites and recorded
  /// the change, so the new list reaches the other device.
  Future<void> _onFavoritesChanged() => _pushLocalState();

  Widget _buildFoodTile(FoodItem item) {
    return FoodItemCard(
      name: item.name,
      subtitle: formatTime(item.loggedAt),
      carbs: item.carbs,
      category: item.category,
      onLongPress: () => _showFoodDetails(item),
    );
  }

  Widget _buildMacroStrip(bool isDark) {
    var protein = 0.0, fat = 0.0, fiber = 0.0, calories = 0.0;
    for (final i in foodItems) {
```

**with:**

```dart
  }

  /// Called by SettingsPage after it has written the favourites and recorded
  /// the change, so the new list reaches the other device.
  Future<void> _onFavoritesChanged() => _pushLocalState();

  /// [index] is the row's place in today's list, which the Delete action
  /// needs. It is null while a row animates out, where the actions would have
  /// nothing to act on.
  Widget _buildFoodTile(FoodItem item, {int? index}) {
    return Semantics(
      // One stop that reads like a sentence. Without this the name, the time
      // and the number are three separate stops, and the number has no unit.
      label: foodRowLabel(
        name: item.name,
        carbs: item.carbs,
        time: formatTime(item.loggedAt),
      ),
      hint: 'Double tap for details',
      onTap: () => _showFoodDetails(item),
      // Deleting and saving are swipes, which VoiceOver can't reach: its own
      // swipes move between elements. These put both in the Actions rotor.
      customSemanticsActions: {
        if (index != null)
          const CustomSemanticsAction(label: 'Delete'): () =>
              removeItem(index),
        const CustomSemanticsAction(label: 'Save to Food list'): () =>
            _saveToSavedFoods(item),
      },
      excludeSemantics: true,
      child: FoodItemCard(
        name: item.name,
        subtitle: formatTime(item.loggedAt),
        carbs: item.carbs,
        category: item.category,
        onLongPress: () => _showFoodDetails(item),
      ),
    );
  }

  Widget _buildMacroStrip(bool isDark) {
    var protein = 0.0, fat = 0.0, fiber = 0.0, calories = 0.0;
    for (final i in foodItems) {
```

**Edit 4 of 4 — replace:**

```dart
                                  child: Icon(
                                    Icons.delete,
                                    size: 28,
                                    color: Colors.white,
                                  ),
                                ),
                                child: _buildFoodTile(item),
                              ),
                            ),
                          );
                        },
                      ),
              ],
```

**with:**

```dart
                                  child: Icon(
                                    Icons.delete,
                                    size: 28,
                                    color: Colors.white,
                                  ),
                                ),
                                child: _buildFoodTile(item, index: index),
                              ),
                            ),
                          );
                        },
                      ),
              ],
```


- [ ] **Step 5: Run the tests**

Run: `flutter test test/a11y_food_row_test.dart` → `+3: All tests passed!`
Then `flutter analyze && flutter test` → `No issues found!` and the suite green.

The two action tests matter more than the label one: they perform the action through the semantics owner and assert the food is actually deleted or saved. An advertised action that does nothing is worse than none.

- [ ] **Step 6: Commit**

```bash
git add lib/utils/a11y_labels.dart lib/main.dart test/a11y_labels_test.dart test/a11y_food_row_test.dart
git commit -m "feat(a11y): read a food row as one element, with delete and save actions"
```

---

### Task 2: The details dialog offers the same two actions

For anyone who cannot swipe, with or without VoiceOver. The dialog currently offers only "Close".

**Files:**
- Modify: `lib/main.dart`
- Test: `test/a11y_food_row_test.dart`

- [ ] **Step 1: Add the buttons**

In `lib/main.dart`:

**Edit 1 of 1 — replace:**

```dart
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
```

**with:**

```dart
                ),
              ),
            ],
          ),
        ),
        actions: [
          // The same two actions the row offers by swipe, for anyone who can't
          // swipe — with or without VoiceOver.
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _saveToSavedFoods(item);
            },
            child: const Text('Save to Food list'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final index = foodItems.indexWhere((f) => f.id == item.id);
              // Gone already if the list changed while the dialog was open.
              if (index != -1) removeItem(index);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.terracotta),
            child: const Text('Delete'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
```


- [ ] **Step 2: Add the tests**

In `test/a11y_food_row_test.dart`:

**Edit 1 of 3 — replace:**

```dart
        .customSemanticsActionIds!
        .firstWhere((i) => CustomSemanticsAction.getAction(i)!.label == action);
    tester.semantics
        .performAction(finder, SemanticsAction.customAction, args: id);
  }

  testWidgets('a food row reads as one sentence with both actions',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();
```

**with:**

```dart
        .customSemanticsActionIds!
        .firstWhere((i) => CustomSemanticsAction.getAction(i)!.label == action);
    tester.semantics
        .performAction(finder, SemanticsAction.customAction, args: id);
  }

  /// Activates the row the way VoiceOver does, opening its details dialog.
  void openDetails(WidgetTester tester, String label) {
    tester.semantics
        .performAction(find.semantics.byLabel(label), SemanticsAction.tap);
  }

  testWidgets('a food row reads as one sentence with both actions',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();
```

**Edit 2 of 3 — replace:**

```dart

    expect(
      find.semantics
          .byLabel('Apple, 25 grams of carbs, logged 8:30 AM')
          .evaluate()
          .single,
      isSemantics(
        hint: 'Double tap for details',
        customActions: const [
          CustomSemanticsAction(label: 'Delete'),
          CustomSemanticsAction(label: 'Save to Food list'),
        ],
      ),
```

**with:**

```dart

    expect(
      find.semantics
          .byLabel('Apple, 25 grams of carbs, logged 8:30 AM')
          .evaluate()
          .single,
      isSemantics(
        hint: 'Double tap for details',
        customActions: const [
          CustomSemanticsAction(label: 'Delete'),
          CustomSemanticsAction(label: 'Save to Food list'),
        ],
      ),
```

**Edit 3 of 3 — replace:**

```dart
    final saved =
        (await SharedPreferences.getInstance()).getString('saved_foods');
    expect(saved, contains('Apple'));
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });
}
```

**with:**

```dart
    final saved =
        (await SharedPreferences.getInstance()).getString('saved_foods');
    expect(saved, contains('Apple'));
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the details dialog offers Delete and Save without a swipe',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state =
        tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));

    // VoiceOver's double tap. A long press opens the same dialog for a
    // sighted user, but the row's swipe recogniser swallows it in tests, so
    // that path is on the device checklist instead.
    openDetails(tester, 'Apple, 25 grams of carbs, logged 8:30 AM');
    await tester.pumpAndSettle();
    expect(find.text('Save to Food list'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(state.foodItems.map((f) => f.name), ['Bagel']);
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the details dialog can save a food to the Food list',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    // VoiceOver's double tap. A long press opens the same dialog for a
    // sighted user, but the row's swipe recogniser swallows it in tests, so
    // that path is on the device checklist instead.
    openDetails(tester, 'Apple, 25 grams of carbs, logged 8:30 AM');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to Food list'));
    await tester.pumpAndSettle();

    final saved =
        (await SharedPreferences.getInstance()).getString('saved_foods');
    expect(saved, contains('Apple'));
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });
}
```


These open the dialog through the semantics tap — VoiceOver's double tap — rather than a long press. A long press opens the same dialog for a sighted user, but the row's swipe recogniser swallows it in the test harness; that is pre-existing and reproduces on unmodified code, so it is on the device checklist instead.

- [ ] **Step 3: Run the tests**

Run: `flutter test test/a11y_food_row_test.dart` → `+5: All tests passed!`
Then `flutter analyze && flutter test`.

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart test/a11y_food_row_test.dart
git commit -m "feat(a11y): offer delete and save in the food details dialog"
```

---

### Task 3: Controls announce as buttons, and the toggle says which is selected

**Files:**
- Modify: `lib/main.dart`, `lib/screens/settings_page.dart`
- Create: `test/a11y_controls_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/a11y_controls_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void stubChannels() {
    final appGroup = <String, Object?>{};
    messenger().setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      final args = (call.arguments as Map?) ?? const {};
      if (call.method == 'saveWidgetData') {
        appGroup[args['id'] as String] = args['data'];
        return true;
      }
      if (call.method == 'getWidgetData') return appGroup[args['id'] as String];
      return null;
    });
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
    addTearDown(() {
      messenger()
          .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
      messenger().setMockMethodCallHandler(
          const MethodChannel('com.carpecarb/cloudsync'), null);
    });
  }

  setUp(() {
    // Otherwise the disclaimer dialog covers the screen and nothing below it
    // is in the accessibility tree.
    SharedPreferences.setMockInitialValues({'disclaimer_accepted': true});
  });

  testWidgets('the entry-mode toggle says which mode is selected',
      (WidgetTester tester) async {
    stubChannels();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(
      find.semantics.byLabel('Auto').evaluate().single,
      isSemantics(
        isButton: true,
        isSelected: true,
        isInMutuallyExclusiveGroup: true,
      ),
    );
    expect(
      find.semantics.byLabel('Manual').evaluate().single,
      isSemantics(isButton: true, isSelected: false),
    );

    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();

    // The selection has to move, or VoiceOver keeps announcing the old mode.
    expect(find.semantics.byLabel('Manual').evaluate().single,
        isSemantics(isSelected: true));
    expect(find.semantics.byLabel('Auto').evaluate().single,
        isSemantics(isSelected: false));

    handle.dispose();
  });

  testWidgets('Reset announces as a button', (WidgetTester tester) async {
    stubChannels();
    // Reset only appears once something has been logged.
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'disclaimer_accepted': true,
      'food_items': jsonEncode([
        {
          'id': 'a',
          'name': 'Apple',
          'carbs': 25.0,
          'loggedAt': '2026-09-22T08:30:00.000',
          'category': 'snack'
        },
      ]),
      'last_save_date': '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}',
    });
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(find.semantics.byLabel('Reset').evaluate().single,
        isSemantics(isButton: true));

    handle.dispose();
  });

  testWidgets('Clear All in Settings announces as a button',
      (WidgetTester tester) async {
    stubChannels();
    // Clear All only appears once a food has been saved.
    SharedPreferences.setMockInitialValues({
      'disclaimer_accepted': true,
      'saved_foods': jsonEncode([
        {
          'id': 'f1',
          'name': 'Bagel',
          'carbs': 48.0,
          'loggedAt': '2026-09-22T08:00:00.000',
          'category': 'breakfast'
        },
      ]),
    });
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    tester
        .state<CarbTrackerHomeState>(find.byType(CarbTrackerHome))
        .switchToSettingsForTest();
    await tester.pumpAndSettle();

    expect(find.semantics.byLabel('Clear All').evaluate().single,
        isSemantics(isButton: true));

    handle.dispose();
  });
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/a11y_controls_test.dart`
Expected: all three fail — the controls carry no button role, so `isSemantics(isButton: true)` does not match.

- [ ] **Step 3: Give the toggle a role and a selected state**

In `lib/main.dart`:

**Edit 1 of 1 — replace:**

```dart
  Widget _buildModeToggle() {
    Widget pill(
        {required String label,
        required bool selected,
        required VoidCallback onTap}) {
      return Expanded(
        child: GestureDetector(
          onTap: () {
            _dismissKeyboard();
            onTap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.sage
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? AppColors.sage
                    : Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.2),
              ),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );
```

**with:**

```dart
  Widget _buildModeToggle() {
    Widget pill(
        {required String label,
        required bool selected,
        required VoidCallback onTap}) {
      return Expanded(
        // A pair of buttons, one of them selected — otherwise VoiceOver reads
        // two bare words and never says which mode is on. The visible Text is
        // the label, so the two can't drift apart.
        child: Semantics(
          button: true,
          selected: selected,
          inMutuallyExclusiveGroup: true,
          child: GestureDetector(
            onTap: () {
              _dismissKeyboard();
              onTap();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.sage
                    : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected
                      ? AppColors.sage
                      : Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant
                          .withValues(alpha: 0.2),
                ),
              ),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
```


- [ ] **Step 4: Announce Reset as a button**

In `lib/main.dart`:

**Edit 1 of 1 — replace:**

```dart
                            letterSpacing: 1.5,
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: _confirmReset,
                          child: Row(
                            children: [
                              Icon(
                                Icons.refresh,
                                size: 16,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Reset',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
```

**with:**

```dart
                            letterSpacing: 1.5,
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        // Announced as a button; the icon and the word
                        // "Reset" alone told VoiceOver nothing about what it
                        // was. It already asks for confirmation.
                        Semantics(
                          button: true,
                          child: GestureDetector(
                            onTap: _confirmReset,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.refresh,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Reset',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
```


- [ ] **Step 5: Announce Clear All as a button**

In `lib/screens/settings_page.dart`:

**Edit 1 of 1 — replace:**

```dart
        if (_savedFoods.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: _resetSavedFoods,
                  child: Text(
                    'Clear All',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.terracotta,
                    ),
                  ),
                ),
              ],
            ),
          ),
```

**with:**

```dart
        if (_savedFoods.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Announced as a button rather than as stray text. It
                // already asks for confirmation.
                Semantics(
                  button: true,
                  child: GestureDetector(
                    onTap: _resetSavedFoods,
                    child: Text(
                      'Clear All',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.terracotta,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
```


- [ ] **Step 6: Run the tests**

Run: `flutter test test/a11y_controls_test.dart` → `+3: All tests passed!`
Then `flutter analyze && flutter test`.

- [ ] **Step 7: Commit**

```bash
git add lib/main.dart lib/screens/settings_page.dart test/a11y_controls_test.dart
git commit -m "feat(a11y): announce the entry toggle, Reset and Clear All as buttons"
```

---

### Task 4: The day's total reads as one deliberate stop

Measured before writing: today the badge, the number, the goal line and the bar merge into *"Apple 25.0g of 100g daily goal, 25"* — that trailing 25 being a bare percentage the progress bar contributes as its value.

**Files:**
- Modify: `lib/main.dart`
- Create: `test/a11y_totals_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/a11y_totals_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void stubChannels() {
    final appGroup = <String, Object?>{};
    messenger().setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      final args = (call.arguments as Map?) ?? const {};
      if (call.method == 'saveWidgetData') {
        appGroup[args['id'] as String] = args['data'];
        return true;
      }
      if (call.method == 'getWidgetData') return appGroup[args['id'] as String];
      return null;
    });
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'),
        (call) async => call.method == 'pushToCloud' ? false : null);
    addTearDown(() {
      messenger()
          .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
      messenger().setMockMethodCallHandler(
          const MethodChannel('com.carpecarb/cloudsync'), null);
    });
  }

  String todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Map<String, Object> basePrefs({double? goal, List<Object>? foods}) => {
        'disclaimer_accepted': true,
        if (goal != null) 'daily_carb_goal': goal,
        if (foods != null) ...{
          'food_items': jsonEncode(foods),
          'last_save_date': todayKey(),
        },
      };

  testWidgets('the day total says what it is and how it compares to the goal',
      (WidgetTester tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues(basePrefs(goal: 100));
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    // Without this it merges into "0.0g of 100g daily goal" plus a bare
    // percentage from the progress bar.
    expect(find.semantics.byLabel("Today's total").evaluate().single,
        isSemantics(value: '0 of 100 grams'));

    handle.dispose();
  });

  testWidgets('the day total says when no goal is set',
      (WidgetTester tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues(basePrefs());
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(find.semantics.byLabel("Today's total").evaluate().single,
        isSemantics(value: '0 grams, no goal set'));

    handle.dispose();
  });

  testWidgets('showing a single food announces that food, not the day',
      (WidgetTester tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues(basePrefs(goal: 100, foods: [
      {
        'id': 'a',
        'name': 'Apple',
        'carbs': 25.0,
        'loggedAt': '2026-09-22T08:30:00.000',
        'category': 'snack'
      },
    ]));
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(find.semantics.byLabel('Apple').evaluate().single,
        isSemantics(value: '25 grams'));

    handle.dispose();
  });

  // The cloud sync indicator only renders behind `Platform.isIOS`, which is
  // false in host tests, so its "Synced" / "Syncing" / "Sync failed" labels
  // are on the device checklist rather than here.
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/a11y_totals_test.dart`
Expected: all three fail — there is no node labelled "Today's total" to find.

- [ ] **Step 3: Give the group a label and a value, and name the sync states**

In `lib/main.dart`:

**Edit 1 of 2 — replace:**

```dart
      }
    }
  }

  Widget _buildCloudSyncIndicator() {
    switch (_cloudSyncState) {
      case _CloudSyncState.syncing:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: AppColors.sage,
          ),
        );
      case _CloudSyncState.synced:
        return Icon(Icons.cloud_done, size: 16, color: AppColors.sage);
      case _CloudSyncState.error:
        return Tooltip(
          message: 'Cloud sync failed',
          child: Icon(Icons.cloud_off, size: 16, color: AppColors.terracotta),
        );
      case _CloudSyncState.idle:
        return const SizedBox.shrink();
    }
  }
```

**with:**

```dart
      }
    }
  }

  Widget _buildCloudSyncIndicator() {
    switch (_cloudSyncState) {
      // Icon-only status: without a label VoiceOver announces nothing, or
      // stops on an unnamed image.
      case _CloudSyncState.syncing:
        return Semantics(
          label: 'Syncing',
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.sage,
            ),
          ),
        );
      case _CloudSyncState.synced:
        return Semantics(
          label: 'Synced',
          child: Icon(Icons.cloud_done, size: 16, color: AppColors.sage),
        );
      case _CloudSyncState.error:
        return Semantics(
          label: 'Sync failed',
          child: Tooltip(
            message: 'Cloud sync failed',
            child: Icon(Icons.cloud_off, size: 16, color: AppColors.terracotta),
          ),
        );
      case _CloudSyncState.idle:
        return const SizedBox.shrink();
    }
  }
```

**Edit 2 of 2 — replace:**

```dart
                              .withValues(alpha: isDark ? 0.3 : 0.08),
                          blurRadius: 6,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // "Today's Total" badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.sage.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            showingDailyTotal || foodItems.isEmpty
                                ? "Today's Total"
                                : foodItems.first.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppColors.sage,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Large carb number
                        RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: showingDailyTotal || foodItems.isEmpty
                                    ? totalCarbs.toStringAsFixed(1)
                                    : foodItems.first.carbs.toStringAsFixed(1),
                                style: TextStyle(
                                  fontSize: 64,
                                  fontWeight: FontWeight.w300,
                                  color:
                                      Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              TextSpan(
                                text: 'g',
                                style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w300,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (dailyCarbGoal != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            totalCarbs > dailyCarbGoal!
                                ? '${(totalCarbs - dailyCarbGoal!).toStringAsFixed(0)}g over goal'
                                : 'of ${dailyCarbGoal!.toStringAsFixed(0)}g daily goal',
                            style: TextStyle(
                              fontSize: 14,
                              color: totalCarbs > dailyCarbGoal!
                                  ? AppColors.terracotta
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Linear progress bar
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value:
                                  (totalCarbs / dailyCarbGoal!).clamp(0.0, 1.0),
                              minHeight: 8,
                              backgroundColor: isDark
                                  ? AppColors.darkBorderMedium
                                  : const Color(0xFFE5E7EB),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                totalCarbs > dailyCarbGoal!
                                    ? AppColors.terracotta
                                    : AppColors.sage,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),
```

**with:**

```dart
                              .withValues(alpha: isDark ? 0.3 : 0.08),
                          blurRadius: 6,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    // One deliberate stop. Left alone these merge into
                    // "Apple 25.0g of 100g daily goal, 25" — the raw number,
                    // the goal line, and a bare percentage the progress bar
                    // contributes as its value.
                    child: Semantics(
                      label: showingDailyTotal || foodItems.isEmpty
                          ? "Today's total"
                          : foodItems.first.name,
                      value: showingDailyTotal || foodItems.isEmpty
                          ? carbProgressValue(
                              total: totalCarbs, goal: dailyCarbGoal)
                          : spokenGrams(foodItems.first.carbs),
                      excludeSemantics: true,
                      child: Column(
                        children: [
                          // "Today's Total" badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppColors.sage.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              showingDailyTotal || foodItems.isEmpty
                                  ? "Today's Total"
                                  : foodItems.first.name,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: AppColors.sage,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Large carb number
                          RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text: showingDailyTotal || foodItems.isEmpty
                                      ? totalCarbs.toStringAsFixed(1)
                                      : foodItems.first.carbs
                                          .toStringAsFixed(1),
                                  style: TextStyle(
                                    fontSize: 64,
                                    fontWeight: FontWeight.w300,
                                    color:
                                        Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                                TextSpan(
                                  text: 'g',
                                  style: TextStyle(
                                    fontSize: 30,
                                    fontWeight: FontWeight.w300,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (dailyCarbGoal != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              totalCarbs > dailyCarbGoal!
                                  ? '${(totalCarbs - dailyCarbGoal!).toStringAsFixed(0)}g over goal'
                                  : 'of ${dailyCarbGoal!.toStringAsFixed(0)}g daily goal',
                              style: TextStyle(
                                fontSize: 14,
                                color: totalCarbs > dailyCarbGoal!
                                    ? AppColors.terracotta
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Linear progress bar
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: (totalCarbs / dailyCarbGoal!)
                                    .clamp(0.0, 1.0),
                                minHeight: 8,
                                backgroundColor: isDark
                                    ? AppColors.darkBorderMedium
                                    : const Color(0xFFE5E7EB),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  totalCarbs > dailyCarbGoal!
                                      ? AppColors.terracotta
                                      : AppColors.sage,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),
```


- [ ] **Step 4: Run the tests**

Run: `flutter test test/a11y_totals_test.dart` → `+3: All tests passed!`
Then `flutter analyze && flutter test`.

The sync indicator's three labels have no test: it only renders behind `Platform.isIOS`, which is false in host tests, so it is on the device checklist.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/a11y_totals_test.dart
git commit -m "feat(a11y): read the day's total as one stop, and name the sync state"
```

---

### Task 5: The widget's goal ring says what it is

**Files:**
- Create: `ios/CarbShared/Sources/CarbShared/CarbAccessibility.swift`, `ios/CarbShared/Tests/CarbSharedTests/CarbAccessibilityTests.swift`
- Modify: `ios/CarbWiseWidget/CarbWiseWidget.swift`

**Interfaces:**
- Produces: `CarbAccessibility.grams(_:)` and `CarbAccessibility.carbsValue(total:goal:)`, worded to match the app's Dart labels so the same number is spoken the same way in both places.

- [ ] **Step 1: Write the wording and its tests**

Create `ios/CarbShared/Sources/CarbShared/CarbAccessibility.swift`:

```swift
import Foundation

/// What VoiceOver reads for the widget's ring, which is otherwise two
/// undescribed circles.
///
/// The wording matches the app's (`lib/utils/a11y_labels.dart`) so the same
/// number is spoken the same way in both places.
public enum CarbAccessibility {
    /// A gram value as it should be spoken: "25 grams", "1 gram", "25.5 grams" —
    /// never "25.0", which is read aloud as "twenty five point zero".
    public static func grams(_ value: Double) -> String {
        let text = number(value)
        return "\(text) \(text == "1" ? "gram" : "grams")"
    }

    /// The ring's value: "45 of 100 grams", or "45 grams, no goal set".
    public static func carbsValue(total: Double, goal: Double?) -> String {
        guard let goal, goal > 0 else {
            return "\(grams(total)), no goal set"
        }
        return "\(number(total)) of \(grams(goal))"
    }

    /// A number without a trailing ".0".
    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }
}
```

Create `ios/CarbShared/Tests/CarbSharedTests/CarbAccessibilityTests.swift`:

```swift
import Testing
@testable import CarbShared

struct CarbAccessibilityTests {
    @Test func gramsDropsThePointZeroVoiceOverWouldReadAloud() {
        #expect(CarbAccessibility.grams(25) == "25 grams")
        #expect(CarbAccessibility.grams(25.5) == "25.5 grams")
    }

    @Test func gramsIsSingularForOne() {
        #expect(CarbAccessibility.grams(1) == "1 gram")
    }

    @Test func valueReadsTheTotalAgainstTheGoal() {
        #expect(CarbAccessibility.carbsValue(total: 45, goal: 100) == "45 of 100 grams")
    }

    @Test func valueSaysWhenNoGoalIsSet() {
        #expect(CarbAccessibility.carbsValue(total: 45, goal: nil) == "45 grams, no goal set")
        // A zero goal means "no goal" everywhere else in the app.
        #expect(CarbAccessibility.carbsValue(total: 45, goal: 0) == "45 grams, no goal set")
    }
}
```

- [ ] **Step 2: Run the Swift tests**

Run: `cd ios/CarbShared && swift test` → `Test run with 54 tests in 7 suites passed`.

- [ ] **Step 3: Make the ring one element**

In `ios/CarbWiseWidget/CarbWiseWidget.swift`:

**Edit 1 of 1 — replace:**

```swift
                        Text(String(format: "%.0fg", entry.data.totalCarbs))
                            .font(.system(size: 28, weight: .light, design: .rounded))
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }

                    if isOver {
                        Text(String(format: "+%.0fg over", entry.data.totalCarbs - goal))
                            .font(.system(size: 14))
                            .foregroundStyle(terracotta)
                    } else {
                        Text(String(format: "%.0fg left", goal - entry.data.totalCarbs))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(format: "%.1fg", entry.data.totalCarbs))
                        .font(.system(size: 52, weight: .light, design: .rounded))
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)

                    Text("total carbs")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                if !entry.data.lastFoodName.isEmpty {
                    HStack {
                        Text(entry.data.lastFoodName)
                            .font(.system(size: 13, weight: .medium))
```

**with:**

```swift
                        Text(String(format: "%.0fg", entry.data.totalCarbs))
                            .font(.system(size: 28, weight: .light, design: .rounded))
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    // One element: the ring is two undescribed circles, and
                    // the number alone reads as "45g" with no context.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Carbs today")
                    .accessibilityValue(
                        CarbAccessibility.carbsValue(
                            total: entry.data.totalCarbs, goal: goal
                        )
                    )

                    if isOver {
                        Text(String(format: "+%.0fg over", entry.data.totalCarbs - goal))
                            .font(.system(size: 14))
                            .foregroundStyle(terracotta)
                    } else {
                        Text(String(format: "%.0fg left", goal - entry.data.totalCarbs))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 0) {
                        Text(String(format: "%.1fg", entry.data.totalCarbs))
                            .font(.system(size: 52, weight: .light, design: .rounded))
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)

                        Text("total carbs")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Carbs today")
                    .accessibilityValue(
                        CarbAccessibility.carbsValue(
                            total: entry.data.totalCarbs, goal: nil
                        )
                    )
                }

                if !entry.data.lastFoodName.isEmpty {
                    HStack {
                        Text(entry.data.lastFoodName)
                            .font(.system(size: 13, weight: .medium))
```


- [ ] **Step 4: Build**

Run the iOS build from the Global Constraints (note the `-derivedDataPath`).
Expected: `** BUILD SUCCEEDED **`.

SwiftUI accessibility can't be asserted from `swift test`, so the ring itself is verified on the device; these tests cover the wording it speaks.

- [ ] **Step 5: Commit**

```bash
git add ios/CarbShared/Sources/CarbShared/CarbAccessibility.swift ios/CarbShared/Tests/CarbSharedTests/CarbAccessibilityTests.swift ios/CarbWiseWidget/CarbWiseWidget.swift
git commit -m "feat(a11y): give the widget's goal ring a label and a value"
```

---

### Task 6: Remove a screen-sized unlabelled button, widen two hit areas, and guard it

Three findings from running Flutter's guideline matchers properly — with the disclaimer seeded as accepted, so the home screen is actually in the accessibility tree.

**Files:**
- Modify: `lib/main.dart`
- Create: `test/a11y_guidelines_test.dart`

- [ ] **Step 1: Write the guard**

Create `test/a11y_guidelines_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A guardrail for the one guideline the app actually meets.
///
/// Two others are deliberately not asserted, because the app fails them today
/// and fixing either changes how it looks, which this batch does not:
///  - text contrast, on the disclaimer dialog's body text;
///  - tap target size, on the Auto/Manual toggle, whose pills are 37pt high
///    against a 44pt minimum. Giving them button semantics is what made the
///    guideline notice them; the two header icons were also below the minimum
///    and are fixed, since their hit area could grow without moving anything
///    on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    final appGroup = <String, Object?>{};
    messenger().setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      final args = (call.arguments as Map?) ?? const {};
      if (call.method == 'saveWidgetData') {
        appGroup[args['id'] as String] = args['data'];
        return true;
      }
      if (call.method == 'getWidgetData') return appGroup[args['id'] as String];
      return null;
    });
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'disclaimer_accepted': true,
      'daily_carb_goal': 100.0,
      'food_items': jsonEncode([
        {
          'id': 'a',
          'name': 'Apple',
          'carbs': 25.0,
          'loggedAt': '2026-09-22T08:30:00.000',
          'category': 'snack'
        },
      ]),
      'last_save_date': '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}',
    });
  });

  tearDown(() {
    messenger()
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), null);
  });

  testWidgets('every tappable thing has a label', (WidgetTester tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

    handle.dispose();
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/a11y_guidelines_test.dart`
Expected: fails with a tappable node the size of the page and no label —
`SemanticsNode#7(Rect.fromLTRB(0.0, 56.0, 800.0, 600.0), actions: [tap])`.
That is the keyboard-dismiss catcher, and it fails on unmodified code too.

- [ ] **Step 3: Exclude the tap catcher and widen the two icons**

In `lib/main.dart`:

**Edit 1 of 2 — replace:**

```dart
    required String tooltip,
  }) {
    final isActive = _currentPage == page;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => _switchToPage(page),
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? (isDark ? AppColors.lightInk : AppColors.charcoal)
                : Colors.transparent,
          ),
          child: Center(child: icon),
        ),
      ),
    );
  }

  @override
```

**with:**

```dart
    required String tooltip,
  }) {
    final isActive = _currentPage == page;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => _switchToPage(page),
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltip,
        // 44x44 is the smallest hit area iOS asks for; the circle stays 40, so
        // nothing moves on screen. At 40 these two were the only controls in
        // the app below the minimum.
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? (isDark ? AppColors.lightInk : AppColors.charcoal)
                    : Colors.transparent,
              ),
              child: Center(child: icon),
            ),
          ),
        ),
      ),
    );
  }

  @override
```

**Edit 2 of 2 — replace:**

```dart
    );
  }

  Widget _buildHomePage(bool isDark) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissKeyboard,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          left: 24.0,
```

**with:**

```dart
    );
  }

  Widget _buildHomePage(bool isDark) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Tapping anywhere dismisses the keyboard. Without this, VoiceOver saw
      // an unlabelled button the size of the whole screen.
      excludeFromSemantics: true,
      onTap: _dismissKeyboard,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          left: 24.0,
```


- [ ] **Step 4: Run everything**

Run: `flutter test test/a11y_guidelines_test.dart` → `+1: All tests passed!`
Then `flutter analyze && flutter test` → `No issues found!` and `+168: All tests passed!`
Then `cd ios/CarbShared && swift test` → 54 passing, and the iOS build.

The tap-target guideline is deliberately **not** asserted: the Auto/Manual pills are 37pt against a 44pt minimum, and making them taller is a visual change this batch excludes. The test file says so, so the omission isn't mistaken for an oversight.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/a11y_guidelines_test.dart
git commit -m "fix(a11y): drop a screen-sized unlabelled button; widen the nav hit areas"
```

---

### Task 7: Hear it on a device

Not code, and the part that actually decides whether this worked. Turn VoiceOver on (Settings › Accessibility › VoiceOver, or triple-click the side button).

- [ ] **Step 1: The food list**
  - [ ] Swipe through the home screen. Every stop says something useful, in a sensible order, and nothing is read twice.
  - [ ] On a food, swipe up/down to reach Actions: "Delete" and "Save to Food list" are both there.
  - [ ] Delete one; the food goes, and the undo in the snackbar is reachable.
  - [ ] Save one; it appears in the Food list.
  - [ ] Double tap a food: the details dialog opens, and Delete and Save are reachable there too.
  - [ ] With VoiceOver **off**, long press a food: the same dialog opens. (Tests can't drive this — the swipe recogniser swallows the long press in the harness.)

- [ ] **Step 2: Controls and numbers**
  - [ ] The Auto/Manual toggle announces which mode is selected, and the selection moves when you switch.
  - [ ] Reset and Clear All announce as buttons.
  - [ ] The day's total reads "Today's total, 45 of 100 grams" — one stop, no stray "25".
  - [ ] With no goal set, it reads "… grams, no goal set".
  - [ ] The sync indicator announces "Synced" / "Syncing" / "Sync failed" (turn iCloud off to see the last one). This has no automated test.

- [ ] **Step 3: The widget**
  - [ ] Add the Home Screen widget, and with VoiceOver reach the ring: it reads "Carbs today, 45 of 100 grams".
  - [ ] With no goal set it reads "… grams, no goal set".

- [ ] **Step 4: Record what you heard**

Replace the line below with anything that read badly, then commit.

> Device pass: pending.

```bash
git add docs/superpowers/plans/2026-09-22-voiceover-support.md
git commit -m "docs: record the VoiceOver device pass"
```

---

## Notes for the reviewer

- The row's custom actions are the whole point of the batch. If a refactor drops `customSemanticsActions` from `_buildFoodTile`, deleting a food becomes unreachable again for VoiceOver users and only the dialog remains.
- Wording lives in `a11y_labels.dart` and `CarbAccessibility`. A number spoken differently in the app and the widget means someone edited one and not the other.
- `excludeSemantics: true` on the row and on the day's total is deliberate: both merge children that would otherwise be read raw ("25.0g", a bare percentage). It also means anything genuinely new inside them will be silent, so check that when adding to either.
- Every home-screen test seeds `'disclaimer_accepted': true`. Without it the dialog covers the screen and a test can pass while asserting nothing about the screen it names.
