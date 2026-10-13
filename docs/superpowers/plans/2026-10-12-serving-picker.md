# Serving Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users change a logged food's serving (USDA foods) or servings count (web foods) in its details dialog, with carbs and macros recalculated on the device and the change flowing to the day total, widget, Apple Health and iCloud.

**Architecture:** A new `ServingInfo` value type holds what's needed to recalculate (USDA portions and per-100 g values, or a web food's base values) plus the chosen portion and count. `FoodItem` carries it optionally, with an `updatedAt` timestamp. An edit produces a new `FoodItem` with recalculated nutrients, so every existing reader keeps reading `carbs`. iCloud merge prefers the newer `updatedAt`; Apple Health replaces the food's own sample. Siri passes the server's serving fields through unchanged so the Dart side has one parser.

**Tech Stack:** Flutter/Dart (`flutter_test`), Swift 6 package `ios/CarbShared` (Swift Testing), existing Firebase response (no server change).

**Spec:** `docs/superpowers/specs/2026-10-12-serving-picker-design.md`

## Global Constraints

- USDA recalculation: each nutrient = `per100g × (portion.grams × count) / 100`. Web: each nutrient = `base × count`. Nulls stay null.
- Rounding to 1 decimal: `(v * 10).round() / 10` — matches the server's `Math.round(v * 10) / 10` for the same inputs.
- Count steps: ½, from ½ to 20. A stored count from the server may be anything in 0.25–20; the stepper never goes below ½ or above 20.
- A food with no `serving` (pre-1.0.4, manual entry, saved by a 1.0.3 device) behaves exactly as today and shows no picker.
- `serving` and `updatedAt` are written to JSON only when present.
- iCloud merge: on a shared food id, the copy with the later `updatedAt` wins; null is older than any timestamp; a tie keeps the cloud copy.
- Apple Health on edit: delete the food's own sample first; write the new one only if the delete succeeded; on any failure show the existing Health sync error, and keep the edit in the app.
- Row text: USDA "typical serving (270 g)" at count 1, "2 × 1 cup (240 g)" otherwise; web "×2" when count ≠ 1, nothing at 1. Joined to the time with " · ".
- Accessibility: buttons "Fewer servings" / "More servings"; value "N servings"; each step announces "<carbs> grams of carbs" (use `spokenGrams`).
- Dialog: live preview; "was X g" shown when changed; an **Update** action only after a change; **Close** discards; snackbar "Updated to X g" after Update.
- Commits: no `Co-Authored-By` trailer and no "Generated with Claude Code" line, ever.
- Checks: `flutter analyze lib test` and `flutter test` from the repo root; `cd ios/CarbShared && swift test`.

## Decision recorded during planning

The spec said `LoggedFood` gains a Codable serving. The plan instead passes the server's serving fields through Siri as JSON (`LookupItem.servingJSON` → `LoggedFood.servingJSON` → merged into the stored entry), so the Dart side parses Siri foods and app foods with the same `ServingInfo.fromServerItem`. One parser, no Swift copy of the rules, same behaviour.

## File Structure

| File | Responsibility |
|---|---|
| `lib/models/serving_info.dart` (create) | `Nutrients`, `ServingPortion`, `ServingInfo`: recalculation, stepping, row text, stored JSON, server parsing |
| `lib/models/food_item.dart` (modify) | `serving`, `updatedAt`, `withServing`, JSON |
| `lib/services/lookup_api.dart` (modify) | attach `serving` from the server response |
| `lib/services/siri_import.dart` (modify) | attach `serving` from Siri entries |
| `lib/services/sync_merge.dart` (modify) | newer edit wins on a shared id |
| `lib/services/health_kit_service.dart` (modify) | `replaceFoodItem` |
| `lib/utils/a11y_labels.dart` (modify) | serving in the row label; picker labels |
| `lib/widgets/serving_picker.dart` (create) | controlled picker widget |
| `lib/main.dart` (modify) | row text, details dialog, `_updateFoodItem`, favorites keep serving |
| `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift`, `CarbDataStore.swift` (modify) | pass serving fields through |
| tests: `test/serving_info_test.dart`, `test/food_item_serving_test.dart`, `test/serving_picker_test.dart`, `test/serving_edit_test.dart` (create); `test/lookup_api_test.dart`, `test/siri_import_test.dart`, `test/sync_merge_test.dart`, `test/health_kit_service_test.dart`, `test/a11y_labels_test.dart`, Swift `PerplexityClientTests.swift`, `CarbDataStoreTests.swift` (modify) |

---

### Task 1: `ServingInfo` model

**Files:**
- Create: `lib/models/serving_info.dart`
- Test: `test/serving_info_test.dart`

**Interfaces:**
- Produces:
  - `class Nutrients { const Nutrients({required double carbs, double? protein, double? fat, double? fiber, double? calories}); Map<String, dynamic> toJson(); static Nutrients? fromJson(Object? json); }` with value equality.
  - `class ServingPortion { const ServingPortion({required String id, required String label, required double grams}); Map<String, dynamic> toJson(); static ServingPortion? fromJson(Object? json); }`
  - `class ServingInfo` with factories `ServingInfo.usda({required int fdcId, required List<ServingPortion> portions, required Nutrients per100g, required String portionId, required double count})` and `ServingInfo.web({required Nutrients base, double count = 1})`; fields `source` (`'usda'|'web'`), `fdcId`, `portions`, `per100g`, `base`, `portionId`, `count`; getters `isUsda`, `portion`, `canDecrease`, `canIncrease`; methods `Nutrients nutrients()`, `ServingInfo copyWith({String? portionId, double? count})`, `ServingInfo decreased()`, `ServingInfo increased()`, `String? rowLabel()`, `Map<String, dynamic> toJson()`, `static ServingInfo? fromJson(Object? json)`, `static ServingInfo? fromServerItem(Map item, Nutrients looked)`; value equality.
  - Top-level `double round1(double v)` and `String formatCount(double count)`.

- [ ] **Step 1: Write the failing tests**

Create `test/serving_info_test.dart`:

```dart
import 'package:carb_tracker/models/serving_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pho100 = Nutrients(carbs: 5.6, protein: 5.81, fat: 3.33, fiber: 0.4, calories: 77);
  const cup = ServingPortion(id: 'p1', label: '1 cup', grams: 245);
  const hundred = ServingPortion(id: '100g', label: '100 g', grams: 100);
  final pho = ServingInfo.usda(
      fdcId: 2707124, portions: const [cup, hundred], per100g: pho100, portionId: 'p1', count: 3);

  group('recalculation', () {
    test('USDA: per-100 g × portion grams × count, rounded like the server', () {
      // The server's own test case (functions/test/lookup.test.js): 3 cups of pho.
      expect(pho.nutrients(),
          const Nutrients(carbs: 41.2, protein: 42.7, fat: 24.5, fiber: 2.9, calories: 566));
    });

    test('USDA: another portion recalculates from the same per-100 g values', () {
      expect(pho.copyWith(portionId: '100g', count: 1).nutrients().carbs, 5.6);
    });

    test('web: base × count; a missing nutrient stays missing', () {
      final web = ServingInfo.web(base: const Nutrients(carbs: 27, protein: 1.3));
      expect(web.copyWith(count: 2).nutrients(), const Nutrients(carbs: 54, protein: 2.6));
      expect(web.copyWith(count: 1.5).nutrients().fat, isNull);
    });

    test('round1 matches Math.round(v * 10) / 10', () {
      expect(round1(41.16), 41.2);
      expect(round1(565.95), 566);
      expect(round1(9.664), 9.7);
    });
  });

  group('stepping', () {
    test('steps by ½ between ½ and 20', () {
      final one = ServingInfo.web(base: const Nutrients(carbs: 10));
      expect(one.increased().count, 1.5);
      expect(one.decreased().count, 0.5);
      expect(one.decreased().canDecrease, isFalse);
      expect(one.copyWith(count: 20).canIncrease, isFalse);
    });

    test('a server count below ½ can only go up', () {
      final quarter = pho.copyWith(count: 0.25);
      expect(quarter.canDecrease, isFalse);
      expect(quarter.increased().count, 0.75);
    });
  });

  group('row text', () {
    test('USDA shows the portion and its grams, with the count when it is not 1', () {
      expect(pho.copyWith(count: 1).rowLabel(), '1 cup (245 g)');
      expect(pho.rowLabel(), '3 × 1 cup (735 g)');
      expect(pho.copyWith(count: 2.5).rowLabel(), '2.5 × 1 cup (613 g)');
    });

    test('web shows ×N only when the count is not 1', () {
      final web = ServingInfo.web(base: const Nutrients(carbs: 10));
      expect(web.rowLabel(), isNull);
      expect(web.copyWith(count: 2).rowLabel(), '×2');
      expect(web.copyWith(count: 0.5).rowLabel(), '×0.5');
    });
  });

  group('stored JSON', () {
    test('round-trips USDA and web', () {
      expect(ServingInfo.fromJson(pho.toJson()), pho);
      final web = ServingInfo.web(base: const Nutrients(carbs: 27, fiber: 3.1), count: 2);
      expect(ServingInfo.fromJson(web.toJson()), web);
    });

    test('anything malformed is dropped, never half-read', () {
      for (final bad in <Object?>[
        null,
        'x',
        {'source': 'usda'},
        {...pho.toJson(), 'portionId': 'nope'},
        {...pho.toJson(), 'count': 50},
        {'source': 'web', 'count': 1},
        {'source': 'other', 'count': 1},
      ]) {
        expect(ServingInfo.fromJson(bad), isNull, reason: '$bad');
      }
    });
  });

  group('fromServerItem', () {
    final usdaItem = {
      'source': 'usda',
      'fdcId': 2707124,
      'serving': {'portionId': 'p1', 'label': '1 cup', 'grams': 245, 'count': 3},
      'portions': [
        {'id': 'p1', 'label': '1 cup', 'grams': 245},
        {'id': '100g', 'label': '100 g', 'grams': 100},
      ],
      'per100g': {'carbs': 5.6, 'protein': 5.81, 'fat': 3.33, 'fiber': 0.4, 'calories': 77},
    };
    const looked = Nutrients(carbs: 41.2, protein: 42.7);

    test('reads a USDA item', () {
      expect(ServingInfo.fromServerItem(usdaItem, looked), pho);
    });

    test('a web item keeps its looked-up values as the base, at count 1', () {
      expect(ServingInfo.fromServerItem({'source': 'web'}, looked),
          ServingInfo.web(base: looked));
    });

    test('no source, or a USDA item that does not add up, gives no serving', () {
      expect(ServingInfo.fromServerItem({}, looked), isNull);
      expect(ServingInfo.fromServerItem({...usdaItem, 'portions': []}, looked), isNull);
      expect(
          ServingInfo.fromServerItem(
              {...usdaItem, 'serving': {'portionId': 'p9', 'count': 1}}, looked),
          isNull);
      expect(ServingInfo.fromServerItem({...usdaItem, 'per100g': null}, looked), isNull);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/serving_info_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:carb_tracker/models/serving_info.dart'`.

- [ ] **Step 3: Implement `lib/models/serving_info.dart`**

```dart
/// The serving a looked-up food was logged at, and everything needed to
/// change it on the device: USDA foods carry their portions and per-100 g
/// values; web foods carry the values they were looked up with.
library;

/// Rounds to 1 decimal the way the server does (`Math.round(v * 10) / 10`).
double round1(double v) => (v * 10).round() / 10;

/// A count as people read it: "3", "2.5", "0.75".
String formatCount(double count) {
  final rounded = (count * 100).round() / 100;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toString();
}

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

class Nutrients {
  const Nutrients({required this.carbs, this.protein, this.fat, this.fiber, this.calories});

  final double carbs;
  final double? protein;
  final double? fat;
  final double? fiber;
  final double? calories;

  Nutrients scaled(double factor) {
    double? s(double? v) => v == null ? null : round1(v * factor);
    return Nutrients(
      carbs: s(carbs)!,
      protein: s(protein),
      fat: s(fat),
      fiber: s(fiber),
      calories: s(calories),
    );
  }

  Map<String, dynamic> toJson() => {
        'carbs': carbs,
        if (protein != null) 'protein': protein,
        if (fat != null) 'fat': fat,
        if (fiber != null) 'fiber': fiber,
        if (calories != null) 'calories': calories,
      };

  static Nutrients? fromJson(Object? json) {
    if (json is! Map) return null;
    final carbs = _num(json['carbs']);
    if (carbs == null || carbs < 0) return null;
    return Nutrients(
      carbs: carbs,
      protein: _num(json['protein']),
      fat: _num(json['fat']),
      fiber: _num(json['fiber']),
      calories: _num(json['calories']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Nutrients &&
      other.carbs == carbs &&
      other.protein == protein &&
      other.fat == fat &&
      other.fiber == fiber &&
      other.calories == calories;

  @override
  int get hashCode => Object.hash(carbs, protein, fat, fiber, calories);

  @override
  String toString() =>
      'Nutrients(carbs: $carbs, protein: $protein, fat: $fat, fiber: $fiber, calories: $calories)';
}

class ServingPortion {
  const ServingPortion({required this.id, required this.label, required this.grams});

  final String id;
  final String label;
  final double grams;

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'grams': grams};

  static ServingPortion? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final label = json['label'];
    final grams = _num(json['grams']);
    if (id is! String || label is! String || grams == null || grams <= 0) return null;
    return ServingPortion(id: id, label: label, grams: grams);
  }

  @override
  bool operator ==(Object other) =>
      other is ServingPortion && other.id == id && other.label == label && other.grams == grams;

  @override
  int get hashCode => Object.hash(id, label, grams);
}

class ServingInfo {
  static const double step = 0.5;
  static const double minCount = 0.5;
  static const double maxCount = 20;
  // The server accepts 0.25–20, so a stored count may start below the stepper's minimum.
  static const double _minStored = 0.25;

  const ServingInfo._({
    required this.source,
    required this.count,
    this.fdcId,
    this.portions = const [],
    this.per100g,
    this.base,
    this.portionId,
  });

  factory ServingInfo.usda({
    required int fdcId,
    required List<ServingPortion> portions,
    required Nutrients per100g,
    required String portionId,
    required double count,
  }) =>
      ServingInfo._(
          source: 'usda',
          fdcId: fdcId,
          portions: List.unmodifiable(portions),
          per100g: per100g,
          portionId: portionId,
          count: count);

  factory ServingInfo.web({required Nutrients base, double count = 1}) =>
      ServingInfo._(source: 'web', base: base, count: count);

  final String source;
  final int? fdcId;
  final List<ServingPortion> portions;
  final Nutrients? per100g;
  final Nutrients? base;
  final String? portionId;
  final double count;

  bool get isUsda => source == 'usda';

  ServingPortion? get portion {
    for (final p in portions) {
      if (p.id == portionId) return p;
    }
    return null;
  }

  bool get canDecrease => count - step >= minCount - 1e-9;
  bool get canIncrease => count + step <= maxCount + 1e-9;

  /// The food's nutrients at this serving, rounded like the server.
  Nutrients nutrients() {
    if (isUsda) {
      final grams = portion!.grams * count;
      final p = per100g!;
      double? s(double? v) => v == null ? null : round1(v * grams / 100);
      return Nutrients(
        carbs: s(p.carbs)!,
        protein: s(p.protein),
        fat: s(p.fat),
        fiber: s(p.fiber),
        calories: s(p.calories),
      );
    }
    return base!.scaled(count);
  }

  ServingInfo copyWith({String? portionId, double? count}) => ServingInfo._(
        source: source,
        fdcId: fdcId,
        portions: portions,
        per100g: per100g,
        base: base,
        portionId: portionId ?? this.portionId,
        count: count ?? this.count,
      );

  ServingInfo decreased() => canDecrease ? copyWith(count: count - step) : this;
  ServingInfo increased() => canIncrease ? copyWith(count: count + step) : this;

  /// What the food row shows next to the time, or null for nothing extra.
  String? rowLabel() {
    if (isUsda) {
      final p = portion!;
      if (count == 1) return '${p.label} (${p.grams.round()} g)';
      return '${formatCount(count)} × ${p.label} (${(p.grams * count).round()} g)';
    }
    return count == 1 ? null : '×${formatCount(count)}';
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'count': count,
        if (fdcId != null) 'fdcId': fdcId,
        if (portions.isNotEmpty) 'portions': portions.map((p) => p.toJson()).toList(),
        if (per100g != null) 'per100g': per100g!.toJson(),
        if (base != null) 'base': base!.toJson(),
        if (portionId != null) 'portionId': portionId,
      };

  static bool _countOk(double? c) => c != null && c >= _minStored && c <= maxCount;

  static List<ServingPortion>? _portions(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final out = <ServingPortion>[];
    for (final r in raw) {
      final p = ServingPortion.fromJson(r);
      if (p == null) return null;
      out.add(p);
    }
    return out;
  }

  static int? _int(Object? v) =>
      v is int ? v : (v is num && v == v.roundToDouble() ? v.toInt() : null);

  static ServingInfo? _usda(Object? fdcIdRaw, Object? portionsRaw, Object? per100gRaw,
      Object? portionId, double? count) {
    final fdcId = _int(fdcIdRaw);
    final portions = _portions(portionsRaw);
    final per100g = Nutrients.fromJson(per100gRaw);
    if (fdcId == null || portions == null || per100g == null) return null;
    if (portionId is! String || !portions.any((p) => p.id == portionId)) return null;
    if (!_countOk(count)) return null;
    return ServingInfo.usda(
        fdcId: fdcId, portions: portions, per100g: per100g, portionId: portionId, count: count!);
  }

  /// The stored form, as written by [toJson]. Anything malformed gives null:
  /// the food then simply has no picker.
  static ServingInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final count = _num(json['count']);
    switch (json['source']) {
      case 'usda':
        return _usda(json['fdcId'], json['portions'], json['per100g'], json['portionId'], count);
      case 'web':
        final base = Nutrients.fromJson(json['base']);
        if (base == null || !_countOk(count)) return null;
        return ServingInfo.web(base: base, count: count!);
      default:
        return null;
    }
  }

  /// A food from the lookup response (or a Siri entry, which carries the same
  /// fields). [looked] is the food's own looked-up nutrients, the base for a
  /// web food.
  static ServingInfo? fromServerItem(Map item, Nutrients looked) {
    switch (item['source']) {
      case 'usda':
        final serving = item['serving'];
        if (serving is! Map) return null;
        return _usda(item['fdcId'], item['portions'], item['per100g'], serving['portionId'],
            _num(serving['count']));
      case 'web':
        return ServingInfo.web(base: looked);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ServingInfo &&
      other.source == source &&
      other.fdcId == fdcId &&
      _listEquals(other.portions, portions) &&
      other.per100g == per100g &&
      other.base == base &&
      other.portionId == portionId &&
      other.count == count;

  @override
  int get hashCode =>
      Object.hash(source, fdcId, Object.hashAll(portions), per100g, base, portionId, count);

  static bool _listEquals(List<ServingPortion> a, List<ServingPortion> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/serving_info_test.dart`
Expected: all pass. Then `flutter analyze lib test` → "No issues found!".

- [ ] **Step 5: Commit**

```bash
git add lib/models/serving_info.dart test/serving_info_test.dart
git commit -m "feat(serving): ServingInfo model for recalculating a logged food"
```

---

### Task 2: `FoodItem` carries the serving; lookup and Siri attach it

**Files:**
- Modify: `lib/models/food_item.dart`
- Modify: `lib/services/lookup_api.dart` (the `foods.add(FoodItem(...))` in `parseLookupResponse`)
- Modify: `lib/services/siri_import.dart` (the `FoodItem(...)` in `SiriImport.parse`)
- Test: `test/food_item_serving_test.dart` (create), `test/lookup_api_test.dart`, `test/siri_import_test.dart`

**Interfaces:**
- Consumes: Task 1 `ServingInfo`, `Nutrients`.
- Produces: `FoodItem.serving` (`ServingInfo?`), `FoodItem.updatedAt` (`DateTime?`), constructor params `serving`, `updatedAt`; `FoodItem withServing(ServingInfo next, {required DateTime now})`.

- [ ] **Step 1: Write the failing tests**

Create `test/food_item_serving_test.dart`:

```dart
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/serving_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final serving = ServingInfo.usda(
    fdcId: 2707124,
    portions: const [
      ServingPortion(id: 'p1', label: '1 cup', grams: 245),
      ServingPortion(id: '100g', label: '100 g', grams: 100),
    ],
    per100g: const Nutrients(carbs: 5.6, protein: 5.81),
    portionId: 'p1',
    count: 1,
  );
  final logged = DateTime(2026, 10, 12, 12, 0, 0, 3);
  final item = FoodItem(
    id: 'f1',
    name: 'pho',
    carbs: 13.7,
    protein: 14.2,
    details: 'USDA FoodData Central (Survey (FNDDS)): Soup, pho, with meat, 1 cup (245 g).',
    loggedAt: logged,
    serving: serving,
  );

  test('withServing recalculates and keeps identity, time, meal and details', () {
    final now = DateTime(2026, 10, 12, 13);
    final edited = item.withServing(serving.copyWith(count: 3), now: now);

    expect(edited.id, 'f1');
    expect(edited.loggedAt, logged);
    expect(edited.category, item.category);
    expect(edited.details, item.details);
    expect(edited.carbs, 41.2);
    expect(edited.protein, 42.7);
    expect(edited.fat, isNull);
    expect(edited.serving!.count, 3);
    expect(edited.updatedAt, now);
  });

  test('serving and updatedAt survive a JSON round trip', () {
    final edited = item.withServing(serving.copyWith(count: 2), now: DateTime.utc(2026, 10, 12, 13));
    final back = FoodItem.fromJson(edited.toJson());
    expect(back.serving, edited.serving);
    expect(back.updatedAt, edited.updatedAt);
  });

  test('a food without them writes neither key, and old JSON still loads', () {
    final plain = FoodItem(id: 'f2', name: 'Apple', carbs: 25, loggedAt: logged);
    expect(plain.toJson().containsKey('serving'), isFalse);
    expect(plain.toJson().containsKey('updatedAt'), isFalse);
    final old = FoodItem.fromJson({
      'id': 'f3', 'name': 'Bagel', 'carbs': 48.0,
      'loggedAt': '2026-09-22T08:00:00.000', 'category': 'breakfast',
    });
    expect(old.serving, isNull);
    expect(old.updatedAt, isNull);
  });

  test('a malformed stored serving is dropped, the food still loads', () {
    final json = item.toJson()..['serving'] = {'source': 'usda'};
    final back = FoodItem.fromJson(json);
    expect(back.serving, isNull);
    expect(back.carbs, 13.7);
  });
}
```

Append to `test/lookup_api_test.dart`, inside `main()` after the existing groups:

```dart
  group('serving data from the server', () {
    test('a USDA item carries its serving; a web item gets its own values as the base', () {
      final result = parseLookupResponse(callableResult({
        'items': [
          {
            'name': 'pho', 'carbs': 41.2, 'protein': 42.7, 'details': 'USDA',
            'source': 'usda', 'fdcId': 2707124,
            'serving': {'portionId': 'p1', 'label': '1 cup', 'grams': 245, 'count': 3},
            'portions': [{'id': 'p1', 'label': '1 cup', 'grams': 245}],
            'per100g': {'carbs': 5.6, 'protein': 5.81},
          },
          {'name': 'Pad Thai', 'carbs': 55, 'fiber': 3, 'details': 'web', 'source': 'web'},
          {'name': 'Old', 'carbs': 10},
        ],
        'citations': [],
      }));

      expect(result.items[0].serving!.isUsda, isTrue);
      expect(result.items[0].serving!.count, 3);
      expect(result.items[1].serving!.isUsda, isFalse);
      expect(result.items[1].serving!.base!.carbs, 55);
      expect(result.items[1].serving!.base!.fiber, 3);
      expect(result.items[1].serving!.count, 1);
      expect(result.items[2].serving, isNull, reason: 'no source: an older server response');
    });
  });
```

Append to `test/siri_import_test.dart`, inside `main()`:

```dart
  test('a Siri entry carries the same serving fields as the app lookup', () {
    final json = jsonEncode([
      {
        'name': 'pho', 'carbs': 13.7, 'loggedAt': '2026-09-18T12:00:00Z',
        'source': 'usda', 'fdcId': 2707124,
        'serving': {'portionId': 'p1', 'count': 1},
        'portions': [{'id': 'p1', 'label': '1 cup', 'grams': 245}],
        'per100g': {'carbs': 5.6},
      },
      {'name': 'Pad Thai', 'carbs': 55, 'loggedAt': '2026-09-18T12:01:00Z', 'source': 'web'},
      {'name': 'Apple', 'carbs': 25, 'loggedAt': '2026-09-18T12:02:00Z'},
    ]);
    final today = SiriImport.parse(json, DateTime(2026, 9, 18, 14), 0).today;

    expect(today[0].serving!.isUsda, isTrue);
    expect(today[1].serving!.base!.carbs, 55);
    expect(today[2].serving, isNull);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/food_item_serving_test.dart test/lookup_api_test.dart test/siri_import_test.dart`
Expected: FAIL — `No named parameter with the name 'serving'` / `The getter 'serving' isn't defined`.

- [ ] **Step 3: Implement**

In `lib/models/food_item.dart`, add the import at the top with the others:

```dart
import 'serving_info.dart';
```

Add the fields after `final bool isManualEntry;`:

```dart
  /// The serving a looked-up food was logged at, for the serving picker.
  /// Null for manual entries and for foods logged before 1.0.4.
  final ServingInfo? serving;

  /// When the food was last edited; null if never. iCloud merge keeps the
  /// copy with the later value.
  final DateTime? updatedAt;
```

Add the constructor parameters after `this.isManualEntry = false,`:

```dart
    this.serving,
    this.updatedAt,
```

Add after `bool get hasMacros => ...;`:

```dart
  /// This food at [next], with its nutrients recalculated. Identity, time,
  /// meal, name and details stay; [updatedAt] becomes [now].
  FoodItem withServing(ServingInfo next, {required DateTime now}) {
    final n = next.nutrients();
    return FoodItem(
      id: id,
      name: name,
      carbs: n.carbs,
      protein: n.protein,
      fat: n.fat,
      fiber: n.fiber,
      calories: n.calories,
      details: details,
      citations: citations,
      isManualEntry: isManualEntry,
      loggedAt: loggedAt,
      category: category,
      serving: next,
      updatedAt: now,
    );
  }
```

In `toJson()`, after `if (isManualEntry) 'isManualEntry': true,`:

```dart
      if (serving != null) 'serving': serving!.toJson(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
```

In `FoodItem.fromJson`, after the `category:` argument:

```dart
      serving: ServingInfo.fromJson(json['serving']),
      updatedAt: json['updatedAt'] is String
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
```

In `lib/services/lookup_api.dart`, add `import '../models/serving_info.dart';` and in `parseLookupResponse` replace the `foods.add(FoodItem(` block with:

```dart
    final protein = parseOptional(item['protein']);
    final fat = parseOptional(item['fat']);
    final fiber = parseOptional(item['fiber']);
    final calories = parseOptional(item['calories']);
    foods.add(FoodItem(
      name: name,
      carbs: carbs,
      protein: protein,
      fat: fat,
      fiber: fiber,
      calories: calories,
      details: item['details'] as String?,
      citations: citations,
      // Each food from one lookup starts in its own millisecond, so deleting
      // one from Apple Health can't take the others with it: the delete
      // matches a single millisecond (HealthKitService.deleteFoodItem).
      loggedAt: base.add(Duration(milliseconds: foods.length)),
      serving: ServingInfo.fromServerItem(
        item,
        Nutrients(carbs: carbs, protein: protein, fat: fat, fiber: fiber, calories: calories),
      ),
    ));
```

In `lib/services/siri_import.dart`, add `import '../models/serving_info.dart';` and replace the `final item = FoodItem(` block with:

```dart
      final carbs = _number(raw['carbs']) ?? 0.0;
      final protein = _number(raw['protein']);
      final fat = _number(raw['fat']);
      final fiber = _number(raw['fiber']);
      final calories = _number(raw['calories']);
      final item = FoodItem(
        name: name,
        carbs: carbs,
        protein: protein,
        fat: fat,
        fiber: fiber,
        calories: calories,
        details: details is String ? details : null,
        citations:
            citations is List ? citations.whereType<String>().toList() : const [],
        loggedAt: loggedAt ?? now,
        // Siri passes the server's serving fields through unchanged
        // (CarbDataStore.addFood), so they read exactly like an app lookup.
        serving: ServingInfo.fromServerItem(
          raw,
          Nutrients(carbs: carbs, protein: protein, fat: fat, fiber: fiber, calories: calories),
        ),
      );
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/food_item_serving_test.dart test/lookup_api_test.dart test/siri_import_test.dart`
Expected: all pass. Then `flutter analyze lib test` and `flutter test` (whole suite) → all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/models/food_item.dart lib/services/lookup_api.dart lib/services/siri_import.dart test/food_item_serving_test.dart test/lookup_api_test.dart test/siri_import_test.dart
git commit -m "feat(serving): foods carry their serving from the lookup and from Siri"
```

---

### Task 3: iCloud merge — the newer edit wins

**Files:**
- Modify: `lib/services/sync_merge.dart:156-165`
- Test: `test/sync_merge_test.dart`

**Interfaces:**
- Consumes: Task 2 `FoodItem.updatedAt`.

- [ ] **Step 1: Write the failing tests**

`test/sync_merge_test.dart` already has `state({List<FoodItem> items, ...})` (same `dayKey` for both sides by default) and `merge(SyncState local, SyncState cloud)`. Add inside `main()`:

```dart
  group('an edited food', () {
    final logged = DateTime(2026, 10, 12, 12);
    FoodItem copy(double carbs, DateTime? updatedAt) => FoodItem(
        id: 'same', name: 'pho', carbs: carbs, loggedAt: logged, updatedAt: updatedAt);

    List<FoodItem> mergedItems(FoodItem local, FoodItem cloud) =>
        merge(state(items: [local]), state(items: [cloud])).items;

    test('the later edit wins, from either side', () {
      final older = copy(13.7, DateTime(2026, 10, 12, 13));
      final newer = copy(41.2, DateTime(2026, 10, 12, 13, 5));
      expect(mergedItems(newer, older).single.carbs, 41.2, reason: 'local newer');
      expect(mergedItems(older, newer).single.carbs, 41.2, reason: 'cloud newer');
    });

    test('an edit beats a copy that was never edited (or came from 1.0.3)', () {
      final edited = copy(41.2, DateTime(2026, 10, 12, 13));
      final plain = copy(13.7, null);
      expect(mergedItems(edited, plain).single.carbs, 41.2);
      expect(mergedItems(plain, edited).single.carbs, 41.2);
    });

    test('a tie keeps the cloud copy, so both devices agree', () {
      final t = DateTime(2026, 10, 12, 13);
      expect(mergedItems(copy(1, t), copy(2, t)).single.carbs, 2);
      expect(mergedItems(copy(1, null), copy(2, null)).single.carbs, 2);
    });
  });
```


- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/sync_merge_test.dart`
Expected: FAIL in "the later edit wins" (local newer case gets 13.7) and "an edit beats…" (cloud plain wins).

- [ ] **Step 3: Implement**

In `lib/services/sync_merge.dart`, replace:

```dart
    final seen = <String>{};
    final merged = <FoodItem>[];
    // Cloud first, so on a shared id the cloud's copy is the one kept. That is
    // only safe because a logged item is never edited in place — the two
    // copies are the same item. If editing is ever added, the newer edit has
    // to win here instead.
    for (final item in [...cloud.items, ...local.items]) {
      if (deletedItemIds.contains(item.id)) continue;
      if (seen.add(item.id)) merged.add(item);
    }
```

with:

```dart
    // On a shared id the copy with the later edit wins. A copy never edited
    // (or saved by a version that drops updatedAt) counts as oldest. Cloud is
    // offered first, so a tie keeps the cloud's copy and both devices agree.
    final byId = <String, FoodItem>{};
    for (final item in [...cloud.items, ...local.items]) {
      if (deletedItemIds.contains(item.id)) continue;
      final kept = byId[item.id];
      if (kept == null || _editedLater(item, kept)) byId[item.id] = item;
    }
    final merged = byId.values.toList();
```

and add this private function below `mergeSyncState`:

```dart
/// True when [a] was edited after [b]. Null means never edited.
bool _editedLater(FoodItem a, FoodItem b) {
  final ta = a.updatedAt;
  final tb = b.updatedAt;
  if (ta == null) return false;
  if (tb == null) return true;
  return ta.isAfter(tb);
}
```

(The existing sort below — newest `loggedAt` first, id as tie-break — stays.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/sync_merge_test.dart test/sync_payload_test.dart test/sync_store_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/services/sync_merge.dart test/sync_merge_test.dart
git commit -m "feat(sync): the newer edit of a food wins on iCloud merge"
```

---

### Task 4: Apple Health — replace a food's sample

**Files:**
- Modify: `lib/services/health_kit_service.dart`
- Test: `test/health_kit_service_test.dart`

**Interfaces:**
- Produces: `Future<bool> HealthKitService.replaceFoodItem(FoodItem old, FoodItem updated)` — true only if both the delete and the write succeeded.

- [ ] **Step 1: Write the failing test**

Append to `test/health_kit_service_test.dart` (add `import 'package:carb_tracker/models/food_item.dart';` and `import 'package:carb_tracker/services/health_kit_service.dart';` if missing):

```dart
class _RecordingHealth extends HealthKitService {
  _RecordingHealth({required this.deleteOk, this.writeOk = true});
  final bool deleteOk;
  final bool writeOk;
  final calls = <String>[];

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    calls.add('delete ${item.carbs}');
    return deleteOk;
  }

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.carbs}');
    return writeOk;
  }
}
```

and inside `main()`:

```dart
  group('replaceFoodItem', () {
    final old = FoodItem(id: 'f', name: 'pho', carbs: 13.7, loggedAt: DateTime(2026, 10, 12, 12));
    final updated = FoodItem(id: 'f', name: 'pho', carbs: 41.2, loggedAt: DateTime(2026, 10, 12, 12));

    test('deletes the old sample, then writes the new one', () async {
      final health = _RecordingHealth(deleteOk: true);
      expect(await health.replaceFoodItem(old, updated), isTrue);
      expect(health.calls, ['delete 13.7', 'write 41.2']);
    });

    test('never writes if the delete failed, so the food cannot appear twice', () async {
      final health = _RecordingHealth(deleteOk: false);
      expect(await health.replaceFoodItem(old, updated), isFalse);
      expect(health.calls, ['delete 13.7']);
    });

    test('reports a failed write', () async {
      final health = _RecordingHealth(deleteOk: true, writeOk: false);
      expect(await health.replaceFoodItem(old, updated), isFalse);
    });
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/health_kit_service_test.dart`
Expected: FAIL — `The method 'replaceFoodItem' isn't defined`.

- [ ] **Step 3: Implement**

In `lib/services/health_kit_service.dart`, add after `deleteFoodItem`:

```dart
  /// Replaces [old]'s sample with [updated]'s, at the same logged time. The
  /// new sample is written only if the old one was deleted, so an edited food
  /// can never appear in Apple Health twice.
  Future<bool> replaceFoodItem(FoodItem old, FoodItem updated) async {
    if (!await deleteFoodItem(old)) return false;
    return writeFoodItem(updated);
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/health_kit_service_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/services/health_kit_service.dart test/health_kit_service_test.dart
git commit -m "feat(health): replace an edited food's sample, never duplicate it"
```

---

### Task 5: The `ServingPicker` widget and its labels

**Files:**
- Create: `lib/widgets/serving_picker.dart`
- Modify: `lib/utils/a11y_labels.dart`
- Test: `test/serving_picker_test.dart` (create), `test/a11y_labels_test.dart`

**Interfaces:**
- Consumes: Task 1 `ServingInfo`, `formatCount`.
- Produces:
  - `class ServingPicker extends StatelessWidget { const ServingPicker({super.key, required ServingInfo value, required ValueChanged<ServingInfo> onChanged}); }` — controlled; never edits state itself.
  - In `a11y_labels.dart`: `String servingsValue(double count)` → `"2 servings"` / `"1 serving"`; `String portionOptionLabel(String label, double grams)` → `"1 cup · 120 g"`; `foodRowLabel` gains an optional `String? serving` parameter.

- [ ] **Step 1: Write the failing tests**

Create `test/serving_picker_test.dart`:

```dart
import 'package:carb_tracker/models/serving_info.dart';
import 'package:carb_tracker/widgets/serving_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final usda = ServingInfo.usda(
    fdcId: 1,
    portions: const [
      ServingPortion(id: 'p1', label: '1 cup', grams: 120),
      ServingPortion(id: 'p2', label: 'typical serving', grams: 270),
      ServingPortion(id: '100g', label: '100 g', grams: 100),
    ],
    per100g: const Nutrients(carbs: 10.58),
    portionId: 'p2',
    count: 1,
  );

  Future<List<ServingInfo>> pump(WidgetTester tester, ServingInfo value) async {
    final changes = <ServingInfo>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ServingPicker(value: value, onChanged: changes.add)),
    ));
    return changes;
  }

  testWidgets('USDA: a menu of portions with their weights, and a count', (tester) async {
    final changes = await pump(tester, usda);

    expect(find.text('typical serving · 270 g'), findsOneWidget);
    await tester.tap(find.text('typical serving · 270 g'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 cup · 120 g').last);
    await tester.pumpAndSettle();
    expect(changes.single.portionId, 'p1');
    expect(changes.single.count, 1);
  });

  testWidgets('the stepper moves by ½ and labels itself for VoiceOver', (tester) async {
    final changes = await pump(tester, usda);

    expect(find.bySemanticsLabel('More servings'), findsOneWidget);
    expect(find.bySemanticsLabel('Fewer servings'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('More servings'));
    expect(changes.last.count, 1.5);
    await tester.tap(find.bySemanticsLabel('Fewer servings'));
    expect(changes.last.count, 0.5);
  });

  testWidgets('at ½ the Fewer button is disabled', (tester) async {
    final changes = await pump(tester, usda.copyWith(count: 0.5));
    await tester.tap(find.bySemanticsLabel('Fewer servings'));
    expect(changes, isEmpty);
  });

  testWidgets('web: only the count, labelled as servings of what was looked up', (tester) async {
    await pump(tester, ServingInfo.web(base: const Nutrients(carbs: 27)));
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('servings of what was looked up'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });
}
```

Append to `test/a11y_labels_test.dart` inside `main()`:

```dart
  test('serving labels', () {
    expect(servingsValue(1), '1 serving');
    expect(servingsValue(2.5), '2.5 servings');
    expect(portionOptionLabel('1 cup', 120), '1 cup · 120 g');
    expect(
      foodRowLabel(name: 'pho', carbs: 41.2, time: '12:00 PM', serving: '3 × 1 cup (735 g)'),
      'pho, 41.2 grams of carbs, 3 × 1 cup (735 g), logged 12:00 PM',
    );
    expect(foodRowLabel(name: 'Apple', carbs: 25, time: '8:30 AM'),
        foodRowLabel(name: 'Apple', carbs: 25, time: '8:30 AM', serving: null));
  });
```

(`spokenGrams(41.2)` returns `'41.2 grams'`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/serving_picker_test.dart test/a11y_labels_test.dart`
Expected: FAIL — missing `serving_picker.dart`, `servingsValue`, `portionOptionLabel`, and the `serving` parameter.

- [ ] **Step 3: Implement**

In `lib/utils/a11y_labels.dart`, replace `foodRowLabel` with:

```dart
String foodRowLabel({
  required String name,
  required double carbs,
  required String time,
  String? serving,
}) =>
    serving == null
        ? '$name, ${spokenGrams(carbs)} of carbs, logged $time'
        : '$name, ${spokenGrams(carbs)} of carbs, $serving, logged $time';

/// The servings stepper's value: "1 serving", "2.5 servings".
String servingsValue(double count) =>
    count == 1 ? '1 serving' : '${formatCount(count)} servings';

/// One option in the portion menu, with its weight: "1 cup · 120 g".
String portionOptionLabel(String label, double grams) => '$label · ${grams.round()} g';
```

and add `import '../models/serving_info.dart';` at the top of `a11y_labels.dart`.

Create `lib/widgets/serving_picker.dart`:

```dart
import 'package:flutter/material.dart';

import '../models/serving_info.dart';
import '../utils/a11y_labels.dart';

/// Chooses a logged food's serving. Controlled: [value] is shown, every change
/// goes to [onChanged], and nothing is saved here.
class ServingPicker extends StatelessWidget {
  const ServingPicker({super.key, required this.value, required this.onChanged});

  final ServingInfo value;
  final ValueChanged<ServingInfo> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Serving', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (value.isUsda)
          DropdownButton<String>(
            isExpanded: true,
            value: value.portionId,
            items: [
              for (final p in value.portions)
                DropdownMenuItem(
                  value: p.id,
                  child: Text(portionOptionLabel(p.label, p.grams)),
                ),
            ],
            onChanged: (id) {
              if (id != null && id != value.portionId) {
                onChanged(value.copyWith(portionId: id));
              }
            },
          ),
        Row(
          children: [
            IconButton(
              tooltip: 'Fewer servings',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: value.canDecrease ? () => onChanged(value.decreased()) : null,
            ),
            Semantics(
              value: servingsValue(value.count),
              excludeSemantics: true,
              child: Text(formatCount(value.count), style: theme.textTheme.titleMedium),
            ),
            IconButton(
              tooltip: 'More servings',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: value.canIncrease ? () => onChanged(value.increased()) : null,
            ),
            if (!value.isUsda) ...[
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  'servings of what was looked up',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/serving_picker_test.dart test/a11y_labels_test.dart`
Expected: all pass. (`IconButton.tooltip` provides the semantics label that `find.bySemanticsLabel` matches.)

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/serving_picker.dart lib/utils/a11y_labels.dart test/serving_picker_test.dart test/a11y_labels_test.dart
git commit -m "feat(serving): ServingPicker widget with VoiceOver labels"
```

---

### Task 6: Wire the picker into the app

**Files:**
- Modify: `lib/main.dart` — `_buildFoodTile` (≈line 1420), `_showFoodDetails` (≈line 1035), `_addSavedFood` (≈line 1552), Health helpers (≈lines 1139–1195); add `_updateFoodItem`.
- Test: `test/serving_edit_test.dart` (create)

**Interfaces:**
- Consumes: Task 2 `FoodItem.serving`, `withServing`; Task 4 `replaceFoodItem`; Task 5 `ServingPicker`, `foodRowLabel(serving:)`, `spokenGrams`.

- [ ] **Step 1: Write the failing tests**

Create `test/serving_edit_test.dart`. Copy the `messenger()`, `todayKey()` and `stubChannels()` helpers verbatim from `test/a11y_food_row_test.dart`, and add a stub for the health channel inside `stubChannels()`:

```dart
    messenger().setMockMethodCallHandler(const MethodChannel('flutter_health'),
        (call) async => true);
```

(add `'flutter_health'` to the teardown list too). Then:

```dart
  void seedPho() {
    SharedPreferences.setMockInitialValues({
      'food_items': jsonEncode([
        {
          'id': 'pho',
          'name': 'pho',
          'carbs': 13.7,
          'loggedAt': DateTime.now().toIso8601String(),
          'category': 'lunch',
          'details': 'USDA FoodData Central (Survey (FNDDS)): Soup, pho, with meat, 1 cup (245 g).',
          'serving': {
            'source': 'usda',
            'fdcId': 2707124,
            'portions': [
              {'id': 'p1', 'label': '1 cup', 'grams': 245},
              {'id': '100g', 'label': '100 g', 'grams': 100},
            ],
            'per100g': {'carbs': 5.6},
            'portionId': 'p1',
            'count': 1,
          },
        },
      ]),
      'last_save_date': todayKey(),
      'disclaimer_accepted': true,
    });
  }

  Future<void> openPho(WidgetTester tester) async {
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('pho').first);
    await tester.pumpAndSettle();
  }

  testWidgets('the row shows the serving next to the time', (tester) async {
    stubChannels();
    seedPho();
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('· 1 cup (245 g)'), findsOneWidget);
  });

  testWidgets('Update appears only after a change; Close throws the change away', (tester) async {
    stubChannels();
    seedPho();
    await openPho(tester);

    expect(find.text('Update'), findsNothing);
    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    expect(find.text('Update'), findsOneWidget);
    expect(find.text('was 13.7 g'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.foodItems.single.carbs, 13.7);
  });

  testWidgets('Update saves the recalculated food and the day total follows', (tester) async {
    stubChannels();
    seedPho();
    await openPho(tester);

    await tester.tap(find.byTooltip('More servings'));
    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.foodItems.single.carbs, 27.4, reason: '2 cups: 5.6 × 490 / 100 = 27.44');
    expect(state.foodItems.single.serving!.count, 2);
    expect(state.foodItems.single.updatedAt, isNotNull);
    expect(state.totalCarbs, 27.4);
    expect(find.text('Updated to 27.4 g'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('food_items')!) as List;
    expect((saved.single as Map)['carbs'], 27.4);
  });

  testWidgets('a food without a serving has no picker', (tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues({
      'food_items': jsonEncode([
        {'id': 'a', 'name': 'Apple', 'carbs': 25.0,
         'loggedAt': DateTime.now().toIso8601String(), 'category': 'snack'},
      ]),
      'last_save_date': todayKey(),
      'disclaimer_accepted': true,
    });
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Apple').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('More servings'), findsNothing);
  });
```

(`CarbTrackerHomeState.foodItems` and `totalCarbs` are public; the existing tests read them the same way.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/serving_edit_test.dart`
Expected: FAIL — no serving text on the row, no "More servings" button in the dialog.

- [ ] **Step 3: Implement in `lib/main.dart`**

1. Add imports near the other local imports:

```dart
import 'models/serving_info.dart';
import 'widgets/serving_picker.dart';
```

2. Row text — in `_buildFoodTile`, compute the serving text once and use it in both the semantics label and the subtitle:

```dart
  Widget _buildFoodTile(FoodItem item, {int? index}) {
    final serving = item.serving?.rowLabel();
    final time = formatTime(item.loggedAt);
    return Semantics(
      label: foodRowLabel(
        name: item.name,
        carbs: item.carbs,
        time: time,
        serving: serving,
      ),
```

and in the `FoodItemCard` below:

```dart
        subtitle: serving == null ? time : '$time · $serving',
```

(keep everything else in the method as it is).

3. Health failure reporting — extract the shared failure snackbar from `_writeToHealthKit` into one helper and use it from both existing helpers and the new update path:

```dart
  /// Tracks Apple Health sync status, telling the user only on the first
  /// failure (OK → failed) so batch writes don't stack snackbars.
  void _reportHealthResult(bool success) {
    if (!mounted) return;
    if (!success) {
      final wasOk = !_healthKitSyncError;
      setState(() => _healthKitSyncError = true);
      if (wasOk) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Health sync failed — check permissions in Settings'),
            backgroundColor: AppColors.terracotta.withValues(alpha: 0.9),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Settings',
              textColor: Colors.white,
              onPressed: () => setState(() => _currentPage = 1),
            ),
          ),
        );
      }
    } else if (_healthKitSyncError) {
      setState(() => _healthKitSyncError = false);
    }
  }

  void _writeToHealthKit(FoodItem item) {
    _healthKitService.writeFoodItem(item).then(_reportHealthResult);
  }

  void _deleteFromHealthKit(FoodItem item) {
    _healthKitService.deleteFoodItem(item).then(_reportHealthResult);
  }
```

(These replace the two existing method bodies, whose failure code is identical.)

4. Add the update path next to `removeItem`:

```dart
  /// Replaces a logged food with its edited version: list, total, widget,
  /// iCloud and Apple Health all follow.
  void _updateFoodItem(FoodItem old, FoodItem updated) {
    final index = foodItems.indexWhere((f) => f.id == old.id);
    // Gone already if the list changed while the dialog was open.
    if (index == -1) return;
    setState(() => foodItems[index] = updated);
    _saveData();
    _updateWidget();
    if (_premiumService.isHealthSyncEnabled) {
      _healthKitService.replaceFoodItem(old, updated).then(_reportHealthResult);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Updated to ${updated.carbs.toStringAsFixed(1)} g'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
```

5. Details dialog — in `_showFoodDetails`, wrap the dialog in a `StatefulBuilder` that holds a draft serving. Replace the method with:

```dart
  Future<void> _showFoodDetails(FoodItem item) async {
    final recognizers = <TapGestureRecognizer>[];
    ServingInfo? draft = item.serving;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final changed = draft != null && draft != item.serving;
          final shown = changed ? item.withServing(draft!, now: DateTime.now()) : item;
          final showMacros = _premiumService.isMacrosEnabled && shown.hasMacros;
          return AlertDialog(
            backgroundColor:
                Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
            title: Text(item.name),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (draft != null) ...[
                    ServingPicker(
                      value: draft!,
                      onChanged: (next) {
                        setDialogState(() => draft = next);
                        SemanticsService.announce(
                          '${spokenGrams(next.nutrients().carbs)} of carbs',
                          TextDirection.ltr,
                        );
                      },
                    ),
                    if (changed)
                      Text(
                        'was ${item.carbs.toStringAsFixed(1)} g',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    const SizedBox(height: 12),
                  ],
                  if (showMacros) ...[
                    _buildMacroGrid(shown, context),
                    const SizedBox(height: 16),
                  ],
                  RichText(
                    text: _buildDetailsTextSpan(
                      item.details ?? 'No details available for this item.',
                      item.citations,
                      baseColor: Theme.of(context).colorScheme.onSurface,
                      recognizers: recognizers,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              if (changed)
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _updateFoodItem(item, shown);
                  },
                  child: const Text('Update'),
                ),
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
          );
        },
      ),
    );
    for (final r in recognizers) {
      r.dispose();
    }
  }
```

Ensure `import 'package:flutter/semantics.dart';` is present (for `SemanticsService`); `spokenGrams` comes from the existing `a11y_labels.dart` import.

Note on `recognizers`: `_buildDetailsTextSpan` appends a recognizer per citation on every build. Because the dialog now rebuilds on each step, move the `recognizers` list creation so each build disposes the previous ones: at the top of the `StatefulBuilder` builder, before `_buildDetailsTextSpan`, add

```dart
          for (final r in recognizers) {
            r.dispose();
          }
          recognizers.clear();
```

6. Favorites keep the serving — in `_addSavedFood`, add to the `FoodItem(` copy:

```dart
      serving: saved.serving,
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/serving_edit_test.dart test/a11y_food_row_test.dart`
Expected: all pass. Then `flutter analyze lib test` → "No issues found!", and `flutter test` → all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/serving_edit_test.dart
git commit -m "feat(serving): change a logged food's serving from its details"
```

---

### Task 7: Siri passes the serving fields through

**Files:**
- Modify: `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift` (`LookupItem`, `parseResponse`, `LoggedFood.init(item:citations:)`)
- Modify: `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift` (`LoggedFood`, `addFood`)
- Test: `ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift`, `CarbDataStoreTests.swift`

**Interfaces:**
- Produces: `LookupItem.servingJSON: String?`, `LoggedFood.servingJSON: String?` (both default nil in their initializers). `addFood` writes the decoded keys (`source`, `fdcId`, `serving`, `portions`, `per100g`) at the top level of the Siri entry, which Task 2's `SiriImport.parse` reads.

- [ ] **Step 1: Write the failing tests**

Append to `PerplexityClientTests.swift` inside the test struct:

```swift
    @Test func keepsTheServerServingFieldsAsJSON() throws {
        let data = Data("""
        {"result": {"items": [
          {"name": "pho", "carbs": 41.2, "source": "usda", "fdcId": 2707124,
           "serving": {"portionId": "p1", "count": 3},
           "portions": [{"id": "p1", "label": "1 cup", "grams": 245}],
           "per100g": {"carbs": 5.6}},
          {"name": "Pad Thai", "carbs": 55, "source": "web"},
          {"name": "Old", "carbs": 10}
        ], "citations": []}}
        """.utf8)
        let items = try PerplexityClient.parseResponse(data).items

        let usda = try #require(items[0].servingJSON)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(usda.utf8)) as? [String: Any])
        #expect(decoded["source"] as? String == "usda")
        #expect(decoded["fdcId"] as? Int == 2707124)
        #expect((decoded["portions"] as? [[String: Any]])?.count == 1)
        #expect(decoded["name"] == nil, "only the serving fields are kept")
        #expect(items[1].servingJSON != nil)
        #expect(items[2].servingJSON == nil)
    }
```

Append to `CarbDataStoreTests.swift` inside the test struct:

```swift
    @Test func storesTheServingFieldsAtTheTopOfTheEntry() throws {
        let serving = #"{"source":"usda","fdcId":2707124,"serving":{"portionId":"p1","count":1},"portions":[{"id":"p1","label":"1 cup","grams":245}],"per100g":{"carbs":5.6}}"#
        store.addFood(LoggedFood(name: "pho", carbs: 13.7, servingJSON: serving), now: noon)
        store.addFood(LoggedFood(name: "Apple", carbs: 25), now: noon)

        let entries = store.siriLoggedItems()
        #expect(entries[0]["source"] as? String == "usda")
        #expect(entries[0]["fdcId"] as? Int == 2707124)
        #expect(entries[0]["name"] as? String == "pho", "the food's own fields are untouched")
        #expect(entries[1]["source"] == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/CarbShared && swift test`
Expected: FAIL — `value of type 'LookupItem' has no member 'servingJSON'` / extra argument `servingJSON`.

- [ ] **Step 3: Implement**

In `PerplexityClient.swift`, add to `LookupItem` a stored property and initializer parameter:

```swift
    /// The server's serving fields (source, fdcId, serving, portions, per100g)
    /// as JSON, passed through unchanged so the app parses Siri foods with the
    /// same code as its own lookups. Nil when the server sent none.
    public let servingJSON: String?
```

and change the initializer signature to end with `details: String? = nil, servingJSON: String? = nil)`, assigning `self.servingJSON = servingJSON`.

In `parseResponse`, inside the loop, pass:

```swift
                details: raw["details"] as? String,
                servingJSON: servingJSON(from: raw)
```

and add this static helper to `PerplexityClient`:

```swift
    static let servingKeys = ["source", "fdcId", "serving", "portions", "per100g"]

    /// The serving fields of one response item, re-encoded as JSON.
    static func servingJSON(from raw: [String: Any]) -> String? {
        let fields = raw.filter { servingKeys.contains($0.key) }
        guard !fields.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
```

Update `LoggedFood.init(item:citations:)` to pass `servingJSON: item.servingJSON`.

In `CarbDataStore.swift`, add to `LoggedFood`:

```swift
    /// The server's serving fields as JSON; see `LookupItem.servingJSON`.
    public let servingJSON: String?
```

with the initializer gaining a trailing `servingJSON: String? = nil` parameter and `self.servingJSON = servingJSON`.

In `addFood`, after `if !food.citations.isEmpty { entry["citations"] = food.citations }`:

```swift
        // Written at the top level, in the server's own shape, so the app reads
        // a Siri entry exactly like a lookup item (siri_import.dart).
        if let json = food.servingJSON,
           let fields = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            for (key, value) in fields where PerplexityClient.servingKeys.contains(key) {
                entry[key] = value
            }
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/CarbShared && swift test`
Expected: all tests pass (previous count + 2).

- [ ] **Step 5: Commit**

```bash
git add ios/CarbShared/Sources/CarbShared/PerplexityClient.swift ios/CarbShared/Sources/CarbShared/CarbDataStore.swift ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift
git commit -m "feat(siri): carry the serving fields so Siri foods get the picker"
```

---

### Task 8: Verify on a device (controller, with the owner)

Not for a subagent. After all tasks pass review:

- [ ] `flutter analyze lib test`, `flutter test`, `cd ios/CarbShared && swift test` all pass on the branch.
- [ ] Build to a device. Log "chicken burrito bowl" (USDA): the row shows "typical serving (270 g)". Open it, change to 2 servings, tap Update: the total, the widget and Apple Health (Health app → Browse → Nutrition → Carbohydrates) show the new value once, not twice.
- [ ] Log "pad thai" (web): change the count to 2: the row shows "×2", carbs double.
- [ ] Log a food with Siri ("Log food in CarpeCarb"), open the app: the food has a picker.
- [ ] With a second device on the same iCloud account: the edit appears there, and an edit made there wins when it's newer.
- [ ] VoiceOver: the stepper reads "Fewer servings", "2 servings", "More servings"; a step announces the new carbs.
