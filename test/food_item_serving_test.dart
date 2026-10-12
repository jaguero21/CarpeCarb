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
    details:
        'USDA FoodData Central (Survey (FNDDS)): Soup, pho, with meat, 1 cup (245 g).',
    loggedAt: logged,
    serving: serving,
  );

  test('withServing recalculates and keeps identity, time, meal and details',
      () {
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
    final edited = item.withServing(serving.copyWith(count: 2),
        now: DateTime.utc(2026, 10, 12, 13));
    final back = FoodItem.fromJson(edited.toJson());
    expect(back.serving, edited.serving);
    expect(back.updatedAt, edited.updatedAt);
    expect(edited.toJson()['updatedAt'], endsWith('Z'),
        reason: 'a UTC stamp keeps its zone, so devices compare the same moment');
  });

  test('a food without them writes neither key, and old JSON still loads', () {
    final plain =
        FoodItem(id: 'f2', name: 'Apple', carbs: 25, loggedAt: logged);
    expect(plain.toJson().containsKey('serving'), isFalse);
    expect(plain.toJson().containsKey('updatedAt'), isFalse);
    final old = FoodItem.fromJson({
      'id': 'f3',
      'name': 'Bagel',
      'carbs': 48.0,
      'loggedAt': '2026-09-22T08:00:00.000',
      'category': 'breakfast',
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
