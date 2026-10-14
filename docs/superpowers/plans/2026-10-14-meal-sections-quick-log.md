# Meal Sections and One-Tap Re-log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group today's foods into meal sections with per-meal carb totals, and add a row of one-tap chips (saved foods, then recent foods) that log a food with no lookup.

**Architecture:**
- **Pure functions** in `lib/models/` decide sections and chip order.
- **A small `RecentFoods` service** keeps recent foods in SharedPreferences.
- **`main.dart`'s `AnimatedList` is replaced** by a column of sections computed from `foodItems` on every build. Rows are keyed by food id, so nothing is kept in step by index.
- **Chips** sit under the food fields and reuse the saved-food logging path, with Undo.

**Tech Stack:** Flutter/Dart, `shared_preferences`, `flutter_test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-14-meal-sections-quick-log-design.md`

## Global Constraints

- **Sections:**
  - Group by `FoodItem.category`. Order sections by their newest food's `loggedAt`, newest first, and foods within a section newest first.
  - Equal times keep `foodItems` order. Only meals with food appear.
  - The header shows the meal icon/color/label and its carb total with one decimal plus " g".
- **Header VoiceOver:** a heading, read as "Lunch, 52 grams of carbs, 2 foods" ("1 food"), using `spokenGrams`.
- **Chips:**
  - Every saved food, in saved-list order, then up to `maxRecentChips = 8` recent foods, newest first.
  - Skip any recent food whose name matches a saved food (`trim().toLowerCase()`).
  - Hide the row when it's empty. Show it in both Auto and Manual modes.
- **Chip label:** "Banana · 27.0 g" (one decimal), with an ellipsis for long names, max 200 pt wide.
- **Chip VoiceOver:** a button, "Log Banana, 27 grams of carbs". A recent chip also has the custom action "Remove from recents". The row is labelled "Quick add".
- **Chip tap:**
  - Logs a new food now: a new id, `loggedAt` = now, so the meal comes from the current time. It keeps the carbs, macros, details, citations, manual flag and serving.
  - Uses no lookup and no quota. It saves, updates the widget, and writes to Health when Health sync is on.
  - Snackbar: "Logged Banana · 27.0 g" with Undo (4 s). Announcement: "Logged Banana, 27 grams of carbs".
- **Undo after a chip tap:** deletes the food through the normal delete path (iCloud delete marker, Health delete), with no second snackbar. It does NOT remove the recent entry.
- **Long-press a recent chip:** a sheet with "Remove from recents". Saved chips have no long-press action.
- **Recents:**
  - Every food that joins Today is recorded: lookup, manual, Siri import (today's foods), saved/chip log.
  - One entry per name (`trim().toLowerCase()`), and logging the same name again replaces the entry with the new copy.
  - Entries more than 30 days old by `lastLoggedAt` are dropped. At most 20 entries are kept.
  - Device-local key `StorageKeys.recentFoods = 'recent_foods'`, not synced.
- **Delete:**
  - Deleting a food from Today (swipe, details → Delete, or the VoiceOver Delete action) removes the recent entry whose `sourceId` is that food's id.
  - Undoing that delete does not restore the entry. Reset and day rollover don't touch recents.
- **Animations:** a newly added food's row fades and grows in over 400 ms. Rows present at first load, after an iCloud merge or after a rollover don't animate. Removed rows close up with a short size animation (300 ms).
- **Unchanged:** the daily total card, the macro strip, the widget data, Health, iCloud and the stored `food_items` format.
- **Commits:**
  - Use `git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit ...`.
  - NO `Co-Authored-By` trailer and no Claude/Claude Code attribution of any kind.
  - Explicit `git add` paths only. Never commit `iap_review_screenshot.png`.
- **Checks:**
  - Before each commit: `flutter analyze lib test` (no issues) plus the task's tests.
  - At the end of every task: the full `flutter test` (299 passed before this plan).

---

### Task 1: Pure section and chip logic, with VoiceOver wording

**Files:**
- Create: `lib/models/meal_sections.dart`
- Create: `lib/models/quick_log.dart`
- Modify: `lib/utils/a11y_labels.dart` (append three functions)
- Test: `test/meal_sections_test.dart`, `test/quick_log_test.dart`, `test/a11y_labels_test.dart` (append)

**Interfaces:**
- Produces:
  - `class MealSection { final FoodCategory category; final List<FoodItem> items; double get totalCarbs; }`
  - `List<MealSection> mealSections(List<FoodItem> items)`
  - `const int maxRecentChips = 8`
  - `class QuickLogChip { final FoodItem food; final bool isRecent; }`
  - `List<QuickLogChip> quickLogChips({required List<FoodItem> saved, required List<FoodItem> recent})`
  - `String mealHeaderLabel({required String meal, required double carbs, required int foods})`
  - `String quickLogChipLabel({required String name, required double carbs})`
  - `String quickLoggedAnnouncement({required String name, required double carbs})`

- [ ] **Step 1: Write the failing tests**

Create `test/meal_sections_test.dart`:

```dart
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/meal_sections.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = DateTime(2026, 10, 14, 12);
  FoodItem food(String name, double carbs, FoodCategory category, int minute) =>
      FoodItem(
        name: name,
        carbs: carbs,
        category: category,
        loggedAt: base.add(Duration(minutes: minute)),
      );

  test('no foods, no sections', () {
    expect(mealSections([]), isEmpty);
  });

  test('groups by meal and totals each meal', () {
    final sections = mealSections([
      food('eggs', 1.2, FoodCategory.breakfast, 0),
      food('toast', 14.5, FoodCategory.breakfast, 1),
      food('soup', 20.3, FoodCategory.lunch, 2),
    ]);
    expect(sections.map((s) => s.category),
        [FoodCategory.lunch, FoodCategory.breakfast]);
    expect(sections[1].totalCarbs, closeTo(15.7, 1e-9));
    expect(sections[0].totalCarbs, closeTo(20.3, 1e-9));
  });

  test('the meal with the newest food comes first', () {
    final sections = mealSections([
      food('soup', 20, FoodCategory.lunch, 0),
      food('latte', 14, FoodCategory.breakfast, 30),
    ]);
    expect(sections.first.category, FoodCategory.breakfast);
  });

  test('foods inside a meal are newest first', () {
    final sections = mealSections([
      food('first', 1, FoodCategory.lunch, 0),
      food('third', 3, FoodCategory.lunch, 20),
      food('second', 2, FoodCategory.lunch, 10),
    ]);
    expect(sections.single.items.map((f) => f.name), ['third', 'second', 'first']);
  });

  test('equal times keep the input order', () {
    final sections = mealSections([
      food('a', 1, FoodCategory.snack, 5),
      food('b', 2, FoodCategory.snack, 5),
    ]);
    expect(sections.single.items.map((f) => f.name), ['a', 'b']);
  });
}
```

Create `test/quick_log_test.dart`:

```dart
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/quick_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FoodItem food(String name) => FoodItem(name: name, carbs: 10);

  test('nothing saved or recent, no chips', () {
    expect(quickLogChips(saved: [], recent: []), isEmpty);
  });

  test('saved foods first, in saved order, then recents', () {
    final chips = quickLogChips(
      saved: [food('Oatmeal'), food('Banana')],
      recent: [food('Pho'), food('Bagel')],
    );
    expect(chips.map((c) => c.food.name), ['Oatmeal', 'Banana', 'Pho', 'Bagel']);
    expect(chips.map((c) => c.isRecent), [false, false, true, true]);
  });

  test('a recent food already saved is skipped, ignoring case and spaces', () {
    final chips = quickLogChips(
      saved: [food('Banana')],
      recent: [food('  banana '), food('Pho')],
    );
    expect(chips.map((c) => c.food.name), ['Banana', 'Pho']);
  });

  test('at most 8 recents, newest first as given', () {
    final chips = quickLogChips(
      saved: [food('Saved')],
      recent: [for (var i = 0; i < 12; i++) food('r$i')],
    );
    expect(chips.length, 1 + maxRecentChips);
    expect(chips.last.food.name, 'r7');
  });
}
```

Append to `test/a11y_labels_test.dart`, inside its `main()`:

```dart
  group('meal sections and quick add', () {
    test('meal header reads as a sentence', () {
      expect(mealHeaderLabel(meal: 'Lunch', carbs: 52.0, foods: 2),
          'Lunch, 52 grams of carbs, 2 foods');
      expect(mealHeaderLabel(meal: 'Snack', carbs: 1.0, foods: 1),
          'Snack, 1 gram of carbs, 1 food');
    });

    test('chip label and logged announcement', () {
      expect(quickLogChipLabel(name: 'Banana', carbs: 27.0),
          'Log Banana, 27 grams of carbs');
      expect(quickLoggedAnnouncement(name: 'Banana', carbs: 27.5),
          'Logged Banana, 27.5 grams of carbs');
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/meal_sections_test.dart test/quick_log_test.dart test/a11y_labels_test.dart`
Expected: FAIL. The new files and functions don't exist.

- [ ] **Step 3: Implement**

Create `lib/models/meal_sections.dart`:

```dart
import 'food_item.dart';

/// One meal in today's list: its foods, newest first, and their carb total.
class MealSection {
  const MealSection({required this.category, required this.items});

  final FoodCategory category;
  final List<FoodItem> items;

  double get totalCarbs => items.fold(0.0, (sum, item) => sum + item.carbs);
}

/// Today's foods grouped by meal, for dosing per meal instead of adding a
/// meal up by hand. The meal with the newest food comes first, and foods
/// inside a meal are newest first. Equal times keep [items]' order.
List<MealSection> mealSections(List<FoodItem> items) {
  final ordered = [for (var i = 0; i < items.length; i++) (i, items[i])]
    ..sort((a, b) {
      final byTime = b.$2.loggedAt.compareTo(a.$2.loggedAt);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  // A map literal keeps insertion order, and each meal is inserted at its
  // newest food, so the sections come out newest first.
  final byMeal = <FoodCategory, List<FoodItem>>{};
  for (final (_, item) in ordered) {
    byMeal.putIfAbsent(item.category, () => []).add(item);
  }
  return [
    for (final entry in byMeal.entries)
      MealSection(category: entry.key, items: entry.value),
  ];
}
```

Create `lib/models/quick_log.dart`:

```dart
import 'food_item.dart';

/// How many recent foods the quick-add row shows after the saved ones.
const int maxRecentChips = 8;

/// One quick-add chip. [isRecent] chips can be removed from recents; saved
/// ones are managed in Settings.
class QuickLogChip {
  const QuickLogChip(this.food, {required this.isRecent});

  final FoodItem food;
  final bool isRecent;
}

String _nameKey(String name) => name.trim().toLowerCase();

/// The quick-add row: every saved food, then up to [maxRecentChips] recent
/// foods that aren't saved already. [recent] is newest first.
List<QuickLogChip> quickLogChips({
  required List<FoodItem> saved,
  required List<FoodItem> recent,
}) {
  final savedNames = {for (final food in saved) _nameKey(food.name)};
  return [
    for (final food in saved) QuickLogChip(food, isRecent: false),
    for (final food in recent
        .where((food) => !savedNames.contains(_nameKey(food.name)))
        .take(maxRecentChips))
      QuickLogChip(food, isRecent: true),
  ];
}
```

Append to `lib/utils/a11y_labels.dart`:

```dart
/// A meal's header in today's list: "Lunch, 52 grams of carbs, 2 foods".
String mealHeaderLabel({
  required String meal,
  required double carbs,
  required int foods,
}) =>
    '$meal, ${spokenGrams(carbs)} of carbs, $foods ${foods == 1 ? 'food' : 'foods'}';

/// A quick-add chip: "Log Banana, 27 grams of carbs".
String quickLogChipLabel({required String name, required double carbs}) =>
    'Log $name, ${spokenGrams(carbs)} of carbs';

/// Spoken after a chip logs a food: "Logged Banana, 27 grams of carbs".
String quickLoggedAnnouncement({required String name, required double carbs}) =>
    'Logged $name, ${spokenGrams(carbs)} of carbs';
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/meal_sections_test.dart test/quick_log_test.dart test/a11y_labels_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 5: Commit**

```bash
git add lib/models/meal_sections.dart lib/models/quick_log.dart lib/utils/a11y_labels.dart test/meal_sections_test.dart test/quick_log_test.dart test/a11y_labels_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): group foods by meal and order quick-add chips"
```

---

### Task 2: RecentFoods store

**Files:**
- Modify: `lib/config/storage_keys.dart` (one key)
- Create: `lib/services/recent_foods.dart`
- Test: `test/recent_foods_test.dart`

**Interfaces:**
- Produces:
  - `StorageKeys.recentFoods`
  - `class RecentFoods`:
    - `static const int maxEntries = 20`
    - `static const Duration keepFor = Duration(days: 30)`
    - `Future<List<FoodItem>> load(DateTime now)` (newest first, expired entries dropped)
    - `Future<void> record(Iterable<FoodItem> items, DateTime now)`
    - `Future<void> remove(String name)`
    - `Future<void> removeSource(String foodId)`

- [ ] **Step 1: Add the key**

In `lib/config/storage_keys.dart`, after `static const String savedFoods = 'saved_foods';`:

```dart
  // Foods logged lately, for the quick-add row. Device-local, not synced.
  static const String recentFoods = 'recent_foods';
```

- [ ] **Step 2: Write the failing tests**

Create `test/recent_foods_test.dart`:

```dart
import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/recent_foods.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 10, 14, 12);
  FoodItem food(String name, double carbs, {DateTime? at}) =>
      FoodItem(name: name, carbs: carbs, loggedAt: at ?? now);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('starts empty', () async {
    expect(await RecentFoods().load(now), isEmpty);
  });

  test('records foods, newest first', () async {
    final recents = RecentFoods();
    await recents.record([food('Bagel', 48, at: now.subtract(const Duration(hours: 2)))], now);
    await recents.record([food('Banana', 27)], now);
    expect((await recents.load(now)).map((f) => f.name), ['Banana', 'Bagel']);
  });

  test('logging the same name again keeps only the newest copy', () async {
    final recents = RecentFoods();
    await recents.record([food('Pho', 13.7, at: now.subtract(const Duration(hours: 1)))], now);
    await recents.record([food('  pho ', 27.4)], now);
    final loaded = await recents.load(now);
    expect(loaded.length, 1);
    expect(loaded.single.carbs, 27.4);
  });

  test('keeps the logged food data', () async {
    final recents = RecentFoods();
    final logged = FoodItem(
        name: 'Toast', carbs: 14.5, protein: 3, details: 'USDA', isManualEntry: true);
    await recents.record([logged], now);
    final loaded = (await recents.load(now)).single;
    expect(loaded.protein, 3);
    expect(loaded.details, 'USDA');
    expect(loaded.isManualEntry, isTrue);
  });

  test('drops foods older than 30 days', () async {
    final recents = RecentFoods();
    await recents.record([food('Old', 10, at: now.subtract(const Duration(days: 31)))], now);
    await recents.record([food('Fresh', 10, at: now.subtract(const Duration(days: 29)))], now);
    expect((await recents.load(now)).map((f) => f.name), ['Fresh']);
  });

  test('keeps at most 20, dropping the oldest', () async {
    final recents = RecentFoods();
    for (var i = 0; i < 25; i++) {
      await recents.record([food('f$i', 1, at: now.add(Duration(minutes: i)))], now);
    }
    final loaded = await recents.load(now.add(const Duration(hours: 1)));
    expect(loaded.length, RecentFoods.maxEntries);
    expect(loaded.first.name, 'f24');
    expect(loaded.last.name, 'f5');
  });

  test('remove forgets a name', () async {
    final recents = RecentFoods();
    await recents.record([food('Bagel', 48), food('Banana', 27)], now);
    await recents.remove(' BAGEL');
    expect((await recents.load(now)).map((f) => f.name), ['Banana']);
  });

  test('removeSource forgets the entry a deleted food created', () async {
    final recents = RecentFoods();
    final wrong = food('Mystery stew', 80);
    await recents.record([wrong, food('Banana', 27)], now);
    await recents.removeSource(wrong.id);
    expect((await recents.load(now)).map((f) => f.name), ['Banana']);
  });

  test('corrupt storage loads as empty', () async {
    SharedPreferences.setMockInitialValues({StorageKeys.recentFoods: 'not json'});
    expect(await RecentFoods().load(now), isEmpty);
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/recent_foods_test.dart`
Expected: FAIL. `recent_foods.dart` doesn't exist.

- [ ] **Step 4: Implement**

Create `lib/services/recent_foods.dart`:

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_keys.dart';
import '../models/food_item.dart';

/// Foods logged lately, so the quick-add row can log them again in one tap.
///
/// One entry per name: logging a food again replaces its entry, so a changed
/// serving carries forward. Stored on this device only; saved foods are what
/// sync.
class RecentFoods {
  static const int maxEntries = 20;
  static const Duration keepFor = Duration(days: 30);

  static String _nameKey(String name) => name.trim().toLowerCase();

  /// Recent foods, newest first, without any older than [keepFor].
  Future<List<FoodItem>> load(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    return [for (final entry in _fresh(_read(prefs), now)) entry.food];
  }

  /// Records [items] as just logged.
  Future<void> record(Iterable<FoodItem> items, DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _read(prefs);
    for (final item in items) {
      entries.removeWhere((e) => _nameKey(e.food.name) == _nameKey(item.name));
      entries.add(_RecentEntry(item, sourceId: item.id, lastLoggedAt: item.loggedAt));
    }
    await _write(prefs, _fresh(entries, now).take(maxEntries).toList());
  }

  /// Forgets [name] (the quick-add row's "Remove from recents").
  Future<void> remove(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _read(prefs)
      ..removeWhere((e) => _nameKey(e.food.name) == _nameKey(name));
    await _write(prefs, entries);
  }

  /// Forgets the entry that the logged food [foodId] created. A food deleted
  /// the same day was probably a wrong lookup, not one to offer again.
  Future<void> removeSource(String foodId) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _read(prefs)..removeWhere((e) => e.sourceId == foodId);
    await _write(prefs, entries);
  }

  /// Newest first, without expired entries.
  List<_RecentEntry> _fresh(List<_RecentEntry> entries, DateTime now) {
    final cutoff = now.subtract(keepFor);
    return entries.where((e) => !e.lastLoggedAt.isBefore(cutoff)).toList()
      ..sort((a, b) => b.lastLoggedAt.compareTo(a.lastLoggedAt));
  }

  List<_RecentEntry> _read(SharedPreferences prefs) {
    final raw = prefs.getString(StorageKeys.recentFoods);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final e in decoded.whereType<Map<String, dynamic>>())
          if (_RecentEntry.tryFromJson(e) case final entry?) entry,
      ];
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to decode recent_foods: $e');
      return [];
    }
  }

  Future<void> _write(SharedPreferences prefs, List<_RecentEntry> entries) =>
      prefs.setString(StorageKeys.recentFoods,
          jsonEncode([for (final e in entries) e.toJson()]));
}

class _RecentEntry {
  _RecentEntry(this.food, {required this.sourceId, required this.lastLoggedAt});

  final FoodItem food;
  final String sourceId;
  final DateTime lastLoggedAt;

  Map<String, dynamic> toJson() => {
        'food': food.toJson(),
        'sourceId': sourceId,
        'lastLoggedAt': lastLoggedAt.toUtc().toIso8601String(),
      };

  static _RecentEntry? tryFromJson(Map<String, dynamic> json) {
    try {
      final at = DateTime.tryParse(json['lastLoggedAt'] as String? ?? '');
      final sourceId = json['sourceId'];
      if (at == null || sourceId is! String) return null;
      return _RecentEntry(
        FoodItem.fromJson(json['food'] as Map<String, dynamic>),
        sourceId: sourceId,
        lastLoggedAt: at,
      );
    } catch (_) {
      return null;
    }
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/recent_foods_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 6: Commit**

```bash
git add lib/config/storage_keys.dart lib/services/recent_foods.dart test/recent_foods_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): remember recently logged foods"
```

---

### Task 3: Today as meal sections

**Files:**
- Create: `lib/widgets/meal_section_header.dart`
- Create: `lib/widgets/appear_once.dart`
- Modify: `lib/main.dart`. The places to change are listed below; find them by the quoted code, because line numbers drift.
- Create: `test/helpers/home_harness.dart`
- Test: `test/meal_sections_home_test.dart`
- Modify: `test/widget_test.dart` (comments that mention `AnimatedList` only, if they no longer make sense)

**Interfaces:**
- Consumes (Task 1): `mealSections`, `MealSection`, and `mealHeaderLabel`.
- Produces:
  - `MealSectionHeader({required MealSection section})`
  - `AppearOnce({required bool animate, required Widget child})`
  - On `CarbTrackerHomeState`:
    - `void removeItemById(String id, {bool showUndo = true, bool forgetRecent = true})`. `forgetRecent` is unused until Task 4, which wires it.
    - `void removeItem(int index)`, kept as a wrapper because tests use it.
    - `void _markArriving(Iterable<FoodItem> items)`.
  - `test/helpers/home_harness.dart` provides:
    - `void stubHomeChannels({String? siriItems})`
    - `String todayKey()`
    - `Map<String, Object> todayPrefs(List<Map<String, Object?>> foods, {Map<String, Object> extra = const {}})`

- [ ] **Step 1: Test harness**

Create `test/helpers/home_harness.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/utils/day_key.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Today's day key at the default reset hour, as the app stores it.
String todayKey() => dayKey(DateTime.now(), 0);

/// SharedPreferences values for a day that already has [foods] logged, with
/// the disclaimer accepted.
Map<String, Object> todayPrefs(List<Map<String, Object?>> foods,
        {Map<String, Object> extra = const {}}) =>
    {
      'food_items': jsonEncode(foods),
      'last_save_date': todayKey(),
      'disclaimer_accepted': true,
      ...extra,
    };

/// Stubs the channels the home screen calls, so saves and pushes complete.
/// [siriItems] is handed over once by the Siri buffer, as Siri would.
void stubHomeChannels({String? siriItems}) {
  final appGroup = <String, Object?>{};
  _messenger.setMockMethodCallHandler(const MethodChannel('home_widget'),
      (call) async {
    final args = (call.arguments as Map?) ?? const {};
    if (call.method == 'saveWidgetData') {
      appGroup[args['id'] as String] = args['data'];
      return true;
    }
    if (call.method == 'getWidgetData') return appGroup[args['id'] as String];
    return null;
  });
  _messenger.setMockMethodCallHandler(
      const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
  var pending = siriItems;
  _messenger.setMockMethodCallHandler(
      const MethodChannel('com.carpecarb/siribuffer'), (call) async {
    final items = pending;
    pending = null;
    return items;
  });
  addTearDown(() {
    for (final name in const [
      'home_widget',
      'com.carpecarb/cloudsync',
      'com.carpecarb/siribuffer',
    ]) {
      _messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
}
```

If `dayKey`'s signature differs (check `lib/utils/day_key.dart`), match it. The app stores `_todayString()` = `dayKey(DateTime.now(), resetHour)`.

- [ ] **Step 2: Write the failing widget tests**

Create `test/meal_sections_home_test.dart`:

```dart
import 'package:carb_tracker/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> food(String id, String name, double carbs, String meal,
          int minutesAgo) =>
      {
        'id': id,
        'name': name,
        'carbs': carbs,
        'category': meal,
        'loggedAt':
            DateTime.now().subtract(Duration(minutes: minutesAgo)).toIso8601String(),
      };

  Future<CarbTrackerHomeState> start(
      WidgetTester tester, List<Map<String, Object?>> foods) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(foods));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  final day = [
    food('b1', 'Toast', 14.5, 'breakfast', 300),
    food('l1', 'Soup', 20.0, 'lunch', 60),
    food('l2', 'Roll', 32.0, 'lunch', 50),
  ];

  testWidgets('foods are grouped under meal headers with totals, newest meal first',
      (tester) async {
    await start(tester, day);
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('Breakfast'), findsOneWidget);
    expect(find.text('52.0 g'), findsOneWidget);
    expect(find.text('14.5 g'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Lunch')).dy,
        lessThan(tester.getTopLeft(find.text('Breakfast')).dy));
    // Newest first inside a meal.
    expect(tester.getTopLeft(find.text('Roll')).dy,
        lessThan(tester.getTopLeft(find.text('Soup')).dy));
  });

  testWidgets('deleting a food updates its meal; the last one removes the meal',
      (tester) async {
    final state = await start(tester, day);
    state.removeItemById('l2');
    await tester.pumpAndSettle();
    expect(find.text('20.0 g'), findsOneWidget);

    state.removeItemById('b1');
    await tester.pumpAndSettle();
    expect(find.text('Breakfast'), findsNothing);
  });

  testWidgets('Undo puts the food back in its meal', (tester) async {
    final state = await start(tester, day);
    state.removeItemById('l1');
    await tester.pumpAndSettle();
    expect(find.text('32.0 g'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('52.0 g'), findsOneWidget);
    expect(state.foodItems.any((f) => f.id == 'l1'), isTrue);
  });

  testWidgets('swiping a row left deletes that food', (tester) async {
    final state = await start(tester, day);
    await tester.drag(find.text('Soup'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(state.foodItems.any((f) => f.id == 'l1'), isFalse);
    expect(find.text('32.0 g'), findsOneWidget);
  });

  testWidgets('a meal header is a heading VoiceOver reads as a sentence',
      (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester, day);
      expect(
        find.semantics.byLabel('Lunch, 52 grams of carbs, 2 foods').evaluate().single,
        isSemantics(isHeader: true),
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('a food logged again appears as a new row', (tester) async {
    final state = await start(tester, day);
    state.addSavedFoodForTest(
        state.foodItems.firstWhere((f) => f.id == 'l1'));
    await tester.pumpAndSettle();
    // Logged now, so its meal comes from the current time; the total for
    // that meal includes it. Count Soup rows instead of guessing the meal.
    expect(find.text('Soup'), findsNWidgets(2));
  });
}
```

If the header's text is split differently from `'Lunch'` and `'52.0 g'` (see Step 4), keep the assertions as written and build the header to match them.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/meal_sections_home_test.dart`
Expected: FAIL, because there are no headers and no `removeItemById`.

- [ ] **Step 4: Implement the widgets**

Create `lib/widgets/meal_section_header.dart`:

```dart
import 'package:flutter/material.dart';

import '../models/meal_sections.dart';
import '../utils/a11y_labels.dart';

/// The header above one meal's foods in today's list: icon, meal name, and
/// the meal's carb total, which is what a per-meal insulin dose is based on.
class MealSectionHeader extends StatelessWidget {
  const MealSectionHeader({super.key, required this.section});

  final MealSection section;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurface,
    );
    return Semantics(
      header: true,
      label: mealHeaderLabel(
        meal: section.category.label,
        carbs: section.totalCarbs,
        foods: section.items.length,
      ),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Row(
          children: [
            Icon(section.category.icon, size: 18, color: section.category.color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(section.category.label,
                  style: style, overflow: TextOverflow.ellipsis),
            ),
            const Spacer(),
            Text('${section.totalCarbs.toStringAsFixed(1)} g', style: style),
          ],
        ),
      ),
    );
  }
}
```

`Flexible` followed by `Spacer` is valid: both are flex children.

Create `lib/widgets/appear_once.dart`:

```dart
import 'package:flutter/material.dart';

/// Fades and grows its child in once, when first built with [animate] true.
/// Rows that were already there when the screen loaded are built with
/// [animate] false and just appear.
class AppearOnce extends StatefulWidget {
  const AppearOnce({super.key, required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<AppearOnce> createState() => _AppearOnceState();
}

class _AppearOnceState extends State<AppearOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
    value: widget.animate ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    return SizeTransition(
      sizeFactor: curve,
      child: FadeTransition(opacity: curve, child: widget.child),
    );
  }
}
```

- [ ] **Step 5: Rework `lib/main.dart`**

Imports: add `import 'models/meal_sections.dart';`, `import 'widgets/appear_once.dart';` and `import 'widgets/meal_section_header.dart';` next to the existing model and widget imports.

**a. State.** Replace the field
`GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();`
with:

```dart
  /// Foods added since the last frame, whose rows fade in. Rows already
  /// there when the list loads just appear.
  final Set<String> _arrivingIds = {};

  void _markArriving(Iterable<FoodItem> items) {
    _arrivingIds.addAll(items.map((item) => item.id));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _arrivingIds.clear());
  }
```

**b. Remove every `_listKey` use:**
- In `_loadSavedData`, delete `_listKey = GlobalKey<AnimatedListState>();` and its comment.
- In `_importSiriLoggedItems`, `_applyLookupResult`, `_addManualFood` and `_addSavedFood`, delete each `_listKey.currentState?.insertItem(...)` statement. Call `_markArriving([...])` with the same food(s) inside the `setState` that inserts them:
  - Siri: `_markArriving([foodItem])` in the loop.
  - Lookup: `_markArriving(items)` inside a `setState` around the insert loop. The loop currently inserts outside `setState`, so wrap it.
  - Manual: `_markArriving([item])`.
  - Saved: `_markArriving([item])`.
- In `_resetTotal`, delete the `for` loop that calls `_listKey.currentState?.removeItem`, and its "Capture items before clearing" comment. Keep `snapshot` (Health and delete markers still use it).
- Update comments that explain the AnimatedList ("keep AnimatedList's internal count in sync", "the old AnimatedList, which still counts the previous items", and so on). Either delete them or rewrite them to say what the code now does. In `_importSiriLoggedItems`, the `await WidgetsBinding.instance.endOfFrame;` can stay; its comment should no longer mention AnimatedList.
- Delete `_buildAnimatedItem`.

**c. Delete by id.** Replace `void removeItem(int index) { ... }` with:

```dart
  /// Deletes the food at [index] in [foodItems]. Kept for tests; the UI
  /// deletes by id.
  void removeItem(int index) => removeItemById(foodItems[index].id);

  /// Deletes a food from today: list, total, widget, iCloud (a delete marker,
  /// so the other device's copy doesn't merge back) and Apple Health.
  /// [showUndo] is false when the deletion is itself an undo (a quick-add chip's).
  /// [forgetRecent] drops the recent-foods entry this food created.
  void removeItemById(String id, {bool showUndo = true, bool forgetRecent = true}) {
    final index = foodItems.indexWhere((f) => f.id == id);
    // Gone already if the list changed under the caller.
    if (index == -1) return;
    final removedItem = foodItems[index];
    setState(() => foodItems.removeAt(index));
    _saveAfterDeleting([removedItem.id]);
    _updateWidget();
    if (_premiumService.isHealthSyncEnabled) {
      _deleteFromHealthKit(removedItem);
    }

    if (!showUndo || !mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${removedItem.name} removed'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          textColor: Colors.white,
          onPressed: () {
            setState(() {
              foodItems.insert(index.clamp(0, foodItems.length), removedItem);
              _markArriving([removedItem]);
            });
            _saveAfterRestoring(removedItem.id);
            _updateWidget();
            if (_premiumService.isHealthSyncEnabled) {
              _writeToHealthKit(removedItem);
            }
          },
        ),
      ),
    );
  }
```

The details dialog's Delete button and `_buildFoodTile`'s VoiceOver Delete action now call `removeItemById(item.id)` instead of looking up an index. Change `_buildFoodTile(FoodItem item, {int? index})` to `_buildFoodTile(FoodItem item)`, always include the Delete custom action, and update its doc comment (it no longer has an index).

**d. Render sections.** Replace the whole `AnimatedList(...)` expression in `_buildHomePage` (the `: AnimatedList(` branch after `foodItems.isEmpty ? Center(...)`) with:

```dart
                    : AnimatedSize(
                        duration: const Duration(milliseconds: 300),
                        alignment: Alignment.topCenter,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final section in mealSections(foodItems)) ...[
                              MealSectionHeader(
                                key: ValueKey('meal-${section.category.name}'),
                                section: section,
                              ),
                              for (final item in section.items)
                                _buildTodayRow(item),
                            ],
                          ],
                        ),
                      ),
```

Add next to `_buildFoodTile`:

```dart
  /// One food in today's list: swipe right to save it, left to delete it.
  Widget _buildTodayRow(FoodItem item) {
    return AppearOnce(
      key: ValueKey('row-${item.id}'),
      animate: _arrivingIds.contains(item.id),
      child: Dismissible(
        key: Key(item.id),
        direction: DismissDirection.horizontal,
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.startToEnd) {
            HapticFeedback.lightImpact();
            await _saveToSavedFoods(item);
            return false;
          }
          HapticFeedback.mediumImpact();
          return true;
        },
        onDismissed: (_) => removeItemById(item.id),
        background: /* move the existing sage bookmark Container here unchanged */,
        secondaryBackground: /* move the existing terracotta delete Container here unchanged */,
        child: _buildFoodTile(item),
      ),
    );
  }
```

Move the two background `Container`s from the old `AnimatedList` item builder over unchanged, keeping the padding/margins the old rows had between them. If the old item builder wrapped rows in padding, keep that padding around `Dismissible`.

- [ ] **Step 6: Run the tests**

Run: `flutter test test/meal_sections_home_test.dart`
Expected: PASS. Then run `flutter test`. Existing tests that call `state.removeItem(i)`, `addSavedFoodForTest`, `applyLookupResultForTest` or `resetTotalForTest` must still pass. If one fails because it relied on `AnimatedList` behavior, fix the test only where the old behavior was an artefact of `AnimatedList` (for example, the comment at `test/widget_test.dart` "Banana is in foodItems but AnimatedList only knows about 1 item"), and explain each change in the report. Then run `flutter analyze lib test` (no issues).

- [ ] **Step 7: Commit**

```bash
git add lib/main.dart lib/widgets/meal_section_header.dart lib/widgets/appear_once.dart test/helpers/home_harness.dart test/meal_sections_home_test.dart
# plus test/widget_test.dart (or other tests) only if changed in Step 6
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): show today's foods in meal sections with per-meal totals"
```

---

### Task 4: Record recent foods

**Files:**
- Modify: `lib/main.dart`
- Test: `test/recent_foods_home_test.dart`

**Interfaces:**
- Consumes:
  - Task 2: `RecentFoods`, with `record`, `removeSource` and `load`.
  - Task 3: `removeItemById(String id, {bool showUndo, bool forgetRecent})`.
  - Task 3: `test/helpers/home_harness.dart`.
- Produces:
  - `final RecentFoods _recentFoods`
  - `Future<void> _recordRecent(Iterable<FoodItem> items)`, which Task 5 extends to refresh the chips.

- [ ] **Step 1: Write the failing tests**

Create `test/recent_foods_home_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/recent_foods.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester, {String? siriItems}) async {
    stubHomeChannels(siriItems: siriItems);
    SharedPreferences.setMockInitialValues(todayPrefs(const []));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  Future<List<String>> recentNames() async =>
      [for (final f in await RecentFoods().load(DateTime.now())) f.name];

  testWidgets('a looked-up food is remembered', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Pho', carbs: 41.2)]));
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Pho']);
  });

  testWidgets('a saved food logged again is remembered', (tester) async {
    final state = await start(tester);
    state.addSavedFoodForTest(FoodItem(name: 'Oatmeal', carbs: 27));
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Oatmeal']);
  });

  testWidgets('a food Siri logged today is remembered', (tester) async {
    await start(tester,
        siriItems: jsonEncode([
          {'name': 'Bagel', 'carbs': 48.0, 'loggedAt': DateTime.now().toUtc().toIso8601String()},
        ]));
    expect(await recentNames(), ['Bagel']);
  });

  testWidgets('deleting a food forgets it; Reset does not', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(LookupResult(items: [
      FoodItem(name: 'Mystery stew', carbs: 80),
      FoodItem(name: 'Banana', carbs: 27),
    ]));
    await tester.pumpAndSettle();

    state.removeItemById(state.foodItems.firstWhere((f) => f.name == 'Mystery stew').id);
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Banana']);

    state.resetTotalForTest();
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Banana']);
  });

  testWidgets('a deletion that is itself an undo keeps the recent food', (tester) async {
    final state = await start(tester);
    state.addSavedFoodForTest(FoodItem(name: 'Oatmeal', carbs: 27));
    await tester.pumpAndSettle();
    state.removeItemById(state.foodItems.single.id, showUndo: false, forgetRecent: false);
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Oatmeal']);
  });
}
```

The Siri JSON shape is what `SiriImport.parse` reads (`lib/services/siri_import.dart`). If a required field is missing, add it from that parser.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/recent_foods_home_test.dart`
Expected: FAIL, because nothing records recents yet.

- [ ] **Step 3: Implement**

In `lib/main.dart`, import `services/recent_foods.dart` and add the field next to `_syncStore`:

```dart
  final RecentFoods _recentFoods = RecentFoods();

  /// Remembers foods that just joined today, for the quick-add row. Never
  /// fails loudly: logging doesn't depend on it.
  Future<void> _recordRecent(Iterable<FoodItem> items) async {
    try {
      await _recentFoods.record(items, DateTime.now());
    } catch (e) {
      if (kDebugMode) debugPrint('Recording recent foods failed: $e');
    }
  }
```

Call `_recordRecent(...)` after each place a food joins Today. Don't await it in synchronous methods: use `unawaited(_recordRecent(...))`, since `dart:async` is imported. The four places:
- `_applyLookupResult`: `unawaited(_recordRecent(items));` inside `if (items.isNotEmpty)`.
- `_addManualFood`: `unawaited(_recordRecent([item]));`.
- `_importSiriLoggedItems`: after the today loop, `await _recordRecent(siri.today);` (it's async), only when `siri.today` is not empty.
- `_addSavedFood`: `unawaited(_recordRecent([item]));`.

In `removeItemById`, after `_saveAfterDeleting(...)`:

```dart
    if (forgetRecent) {
      unawaited(_recentFoods.removeSource(removedItem.id).catchError((Object e) {
        if (kDebugMode) debugPrint('Forgetting a recent food failed: $e');
      }));
    }
```

`_resetTotal` must not touch recents.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/recent_foods_home_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/recent_foods_home_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): remember foods as they're logged, forget deleted ones"
```

---

### Task 5: Quick-add chips

**Files:**
- Create: `lib/widgets/quick_log_chips.dart`
- Modify: `lib/main.dart`
- Test: `test/quick_log_chips_test.dart`, `test/quick_log_home_test.dart`

**Interfaces:**
- Consumes:
  - Task 1: `QuickLogChip`, `quickLogChips`, `quickLogChipLabel` and `quickLoggedAnnouncement`.
  - Task 2: `RecentFoods.load` and `remove`.
  - Task 3: `removeItemById`.
  - Task 4: `_recordRecent` and `_recentFoods`.
- Produces:
  - `QuickLogChips({required List<QuickLogChip> chips, required ValueChanged<FoodItem> onLog, required ValueChanged<FoodItem> onRemoveRecent})`
  - On `CarbTrackerHomeState`:
    - `List<QuickLogChip> quickChips` (`@visibleForTesting` getter)
    - `Future<void> _reloadQuickLog()`
    - `void _quickLog(FoodItem food)`

- [ ] **Step 1: Write the failing widget test for the chip row**

Create `test/quick_log_chips_test.dart`:

```dart
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/quick_log.dart';
import 'package:carb_tracker/widgets/quick_log_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final banana = FoodItem(name: 'Banana', carbs: 27);
  final pho = FoodItem(name: 'Pho', carbs: 41.2);

  Future<(List<FoodItem>, List<FoodItem>)> pump(WidgetTester tester) async {
    final logged = <FoodItem>[];
    final removed = <FoodItem>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QuickLogChips(
          chips: [
            QuickLogChip(banana, isRecent: false),
            QuickLogChip(pho, isRecent: true),
          ],
          onLog: logged.add,
          onRemoveRecent: removed.add,
        ),
      ),
    ));
    return (logged, removed);
  }

  testWidgets('chips show name and carbs; a tap logs that food', (tester) async {
    final (logged, _) = await pump(tester);
    expect(find.text('Banana · 27.0 g'), findsOneWidget);
    expect(find.text('Pho · 41.2 g'), findsOneWidget);
    await tester.tap(find.text('Pho · 41.2 g'));
    expect(logged, [pho]);
  });

  testWidgets('long-pressing a recent chip offers Remove from recents', (tester) async {
    final (_, removed) = await pump(tester);
    await tester.longPress(find.text('Pho · 41.2 g'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from recents'));
    await tester.pumpAndSettle();
    expect(removed, [pho]);
  });

  testWidgets('long-pressing a saved chip does nothing', (tester) async {
    await pump(tester);
    await tester.longPress(find.text('Banana · 27.0 g'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from recents'), findsNothing);
  });

  testWidgets('VoiceOver: buttons with spoken labels, and a remove action on recents',
      (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final (logged, removed) = await pump(tester);
      expect(find.semantics.byLabel('Quick add'), findsOneWidget);
      expect(
        find.semantics.byLabel('Log Banana, 27 grams of carbs').evaluate().single,
        isSemantics(isButton: true, hasTapAction: true),
      );
      final phoNode =
          find.semantics.byLabel('Log Pho, 41.2 grams of carbs').evaluate().single;
      expect(phoNode, isSemantics(isButton: true, hasTapAction: true));
      final action = phoNode.getSemanticsData().customSemanticsActionIds!.single;
      tester.binding.pipelineOwner.semanticsOwner!.performAction(
          phoNode.id, SemanticsAction.customAction, action);
      await tester.pumpAndSettle();
      expect(removed, [pho]);
      expect(logged, isEmpty);
    } finally {
      handle.dispose();
    }
  });
}
```

If triggering the custom action through `performAction` doesn't fit this Flutter version's test API, use the closest supported way (for example, `tester.semantics.performAction`). Keep the assertion that the action calls `onRemoveRecent`.

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/quick_log_chips_test.dart`
Expected: FAIL, because the widget doesn't exist.

- [ ] **Step 3: Implement the chip row**

Create `lib/widgets/quick_log_chips.dart`:

```dart
import 'package:flutter/material.dart';

import '../models/food_item.dart';
import '../models/quick_log.dart';
import '../utils/a11y_labels.dart';

/// A row of foods to log again in one tap: saved foods, then recent ones.
class QuickLogChips extends StatelessWidget {
  const QuickLogChips({
    super.key,
    required this.chips,
    required this.onLog,
    required this.onRemoveRecent,
  });

  final List<QuickLogChip> chips;
  final ValueChanged<FoodItem> onLog;
  final ValueChanged<FoodItem> onRemoveRecent;

  Future<void> _offerRemove(BuildContext context, FoodItem food) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.history_toggle_off),
          title: const Text('Remove from recents'),
          subtitle: Text(food.name),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (remove == true) onRemoveRecent(food);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Quick add',
      explicitChildNodes: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final chip in chips)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Semantics(
                  button: true,
                  label: quickLogChipLabel(
                      name: chip.food.name, carbs: chip.food.carbs),
                  onTap: () => onLog(chip.food),
                  customSemanticsActions: chip.isRecent
                      ? {
                          const CustomSemanticsAction(label: 'Remove from recents'):
                              () => onRemoveRecent(chip.food),
                        }
                      : null,
                  excludeSemantics: true,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200, minHeight: 44),
                    child: Material(
                      color: colorScheme.surfaceContainerHighest,
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => onLog(chip.food),
                        onLongPress: chip.isRecent
                            ? () => _offerRemove(context, chip.food)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Text(
                            '${chip.food.name} · ${chip.food.carbs.toStringAsFixed(1)} g',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14, color: colorScheme.onSurface),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
```

Run `flutter test test/quick_log_chips_test.dart` and expect PASS.

- [ ] **Step 4: Write the failing home-screen tests**

Create `test/quick_log_home_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/recent_foods.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester,
      {List<FoodItem> saved = const [], List<FoodItem> recent = const []}) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const [], extra: {
      'saved_foods': jsonEncode([for (final f in saved) f.toJson()]),
    }));
    if (recent.isNotEmpty) await RecentFoods().record(recent, DateTime.now());
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  testWidgets('no saved or recent foods, no chip row', (tester) async {
    await start(tester);
    expect(find.text('Quick add'), findsNothing);
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.quickChips, isEmpty);
  });

  testWidgets('saved foods come before recent ones', (tester) async {
    await start(tester,
        saved: [FoodItem(name: 'Oatmeal', carbs: 27)],
        recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    expect(tester.getTopLeft(find.text('Oatmeal · 27.0 g')).dx,
        lessThan(tester.getTopLeft(find.text('Pho · 41.2 g')).dx));
  });

  testWidgets('a chip logs the food with Undo, and Undo keeps the chip', (tester) async {
    final state = await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.tap(find.text('Pho · 41.2 g'));
    await tester.pumpAndSettle();
    expect(state.foodItems.single.name, 'Pho');
    expect(find.text('Logged Pho · 41.2 g'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(state.foodItems, isEmpty);
    expect(find.text('Pho · 41.2 g'), findsOneWidget);
  });

  testWidgets('Remove from recents removes the chip', (tester) async {
    await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.longPress(find.text('Pho · 41.2 g'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from recents'));
    await tester.pumpAndSettle();
    expect(find.text('Pho · 41.2 g'), findsNothing);
  });

  testWidgets('a lookup adds a chip; deleting that food takes it away', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Mystery stew', carbs: 80)]));
    await tester.pumpAndSettle();
    expect(find.text('Mystery stew · 80.0 g'), findsOneWidget);

    state.removeItemById(state.foodItems.single.id);
    await tester.pumpAndSettle();
    expect(find.text('Mystery stew · 80.0 g'), findsNothing);
  });

  testWidgets('saving a food to the Food list moves its chip to the saved group',
      (tester) async {
    final state = await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    expect(state.quickChips.single.isRecent, isTrue);
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Bagel', carbs: 48)]));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Bagel'), const Offset(600, 0)); // swipe right = save
    await tester.pumpAndSettle();
    final bagel = state.quickChips.firstWhere((c) => c.food.name == 'Bagel');
    expect(bagel.isRecent, isFalse);
  });
}
```

If `find.text('Bagel')` matches both the row and the chip in the last test, use `find.descendant` scoped to the food row (`FoodItemCard`) for the drag.

- [ ] **Step 5: Run them to verify they fail**

Run: `flutter test test/quick_log_home_test.dart`
Expected: FAIL, because there are no chips on the home screen.

- [ ] **Step 6: Wire the chips into `lib/main.dart`**

Imports: add `models/quick_log.dart` and `widgets/quick_log_chips.dart`.

State:

```dart
  List<QuickLogChip> _quickChips = const [];

  @visibleForTesting
  List<QuickLogChip> get quickChips => _quickChips;

  /// Rebuilds the quick-add row from saved foods and recent foods.
  Future<void> _reloadQuickLog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = prefs.getString(StorageKeys.savedFoods);
      final saved = savedJson == null
          ? <FoodItem>[]
          : [
              for (final f in jsonDecode(savedJson) as List)
                FoodItem.fromJson(f as Map<String, dynamic>),
            ];
      final recent = await _recentFoods.load(DateTime.now());
      if (!mounted) return;
      setState(() => _quickChips = quickLogChips(saved: saved, recent: recent));
    } catch (e) {
      if (kDebugMode) debugPrint('Loading quick-add foods failed: $e');
    }
  }
```

Refresh the row whenever saved foods or recents change:
- At the end of `_recordRecent` (after the try/catch): `await _reloadQuickLog();`
- In `removeItemById`, chain the reload onto `removeSource`: `_recentFoods.removeSource(...).then((_) => _reloadQuickLog())`, keeping the `catchError`.
- At the end of `_loadSavedData`'s two return paths: call `await _reloadQuickLog();` before each `await _importSiriLoggedItems();`. This covers launch, resume, rollover and iCloud merges, which call `_loadSavedData`.
- In `_saveToSavedFoods`, after the saved list is written (the `if (!exists)` branch): `unawaited(_reloadQuickLog());`
- In `_onFavoritesChanged`: `Future<void> _onFavoritesChanged() async { await _pushLocalState(); await _reloadQuickLog(); }`

Logging from a chip. Make `_addSavedFood` return the food it logged (`FoodItem _addSavedFood(FoodItem saved)` with `return item;` at the end; Settings' `onAddFood` still accepts it). Then add:

```dart
  /// Logs a quick-add chip's food now, with no lookup, and offers Undo.
  void _quickLog(FoodItem food) {
    HapticFeedback.lightImpact();
    final item = _addSavedFood(food);
    SemanticsService.sendAnnouncement(
      View.of(context),
      quickLoggedAnnouncement(name: item.name, carbs: item.carbs),
      TextDirection.ltr,
    );
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Logged ${item.name} · ${item.carbs.toStringAsFixed(1)} g'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          textColor: Colors.white,
          // A mis-tap, not a wrong food: keep it in the quick-add row.
          onPressed: () =>
              removeItemById(item.id, showUndo: false, forgetRecent: false),
        ),
      ),
    );
  }

  void _removeRecent(FoodItem food) {
    _recentFoods.remove(food.name).then((_) => _reloadQuickLog());
  }
```

Place the row in the food input card. Insert it directly after the manual-mode carbs `TextField` block (the `if (_isManualEntryMode && _premiumService.isManualEntryEnabled) ...[ ... ],` list) and before `const SizedBox(height: 16),` above the Add button:

```dart
                      if (_quickChips.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        QuickLogChips(
                          chips: _quickChips,
                          onLog: _quickLog,
                          onRemoveRecent: _removeRecent,
                        ),
                      ],
```

- [ ] **Step 7: Run the tests**

Run: `flutter test test/quick_log_chips_test.dart test/quick_log_home_test.dart test/recent_foods_home_test.dart test/meal_sections_home_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass). Existing tests that count `find.text('Banana')` or similar may now also find a chip. Where a test seeds saved foods or logs foods and then looks a row up by text, scope the finder to the row (`find.descendant(of: find.byType(FoodItemCard), ...)`) and explain each change in the report.

- [ ] **Step 8: Commit**

```bash
git add lib/main.dart lib/widgets/quick_log_chips.dart test/quick_log_chips_test.dart test/quick_log_home_test.dart
# plus any existing test files adjusted in Step 7
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): one-tap quick-add chips for saved and recent foods"
```

---

## After the tasks (controller)

- Run `flutter build ios --simulator --debug` in the main repo.
- Device check (Xcode debug build):
  - Sections and totals through a day.
  - A chip tap logs the food and reaches the widget and Apple Health.
  - Undo removes it from Health.
  - Long-press removes a recent.
  - VoiceOver reads headers and chips.
  - Large text: the header and chips don't clip.
