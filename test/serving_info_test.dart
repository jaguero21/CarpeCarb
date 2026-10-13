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
