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

  test('a time and meal edit keeps the carbs, macros and serving', () {
    final serving = ServingInfo.fromServerItem({
      'source': 'usda',
      'fdcId': 1,
      'serving': {'portionId': 'p1', 'label': '1 cup', 'grams': 245, 'count': 1},
      'portions': [
        {'id': 'p1', 'label': '1 cup', 'grams': 245},
      ],
      'per100g': {'carbs': 5.6, 'protein': 3.1, 'fat': 1.2, 'fiber': 0.4, 'calories': 45},
    }, const Nutrients(carbs: 13.7))!;
    final full = FoodItem(
      name: 'Pho',
      carbs: 13.7,
      protein: 7.6,
      fat: 2.9,
      fiber: 1.0,
      calories: 110,
      serving: serving,
      isManualEntry: true,
      updatedAt: DateTime.utc(2026, 10, 14, 12),
      loggedAt: DateTime(2026, 10, 14, 15, 10),
      category: FoodCategory.snack,
    );
    final moved = full.edited(
        loggedAt: DateTime(2026, 10, 14, 13, 30),
        category: FoodCategory.lunch,
        now: now);
    expect(moved.id, full.id);
    expect(moved.carbs, 13.7);
    expect(moved.protein, 7.6);
    expect(moved.fat, 2.9);
    expect(moved.fiber, 1.0);
    expect(moved.calories, 110);
    expect(moved.serving, same(serving));
    expect(moved.isManualEntry, isTrue);
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

  test('withNewId changes the id and nothing else', () {
    final serving = ServingInfo.fromServerItem({
      'source': 'usda',
      'fdcId': 1,
      'serving': {'portionId': 'p1', 'label': '1 cup', 'grams': 245, 'count': 1},
      'portions': [
        {'id': 'p1', 'label': '1 cup', 'grams': 245},
      ],
      'per100g': {'carbs': 5.6, 'protein': 3.1, 'fat': 1.2, 'fiber': 0.4, 'calories': 45},
    }, const Nutrients(carbs: 13.7))!;
    final full = FoodItem(
      id: 'pho-1',
      name: 'Pho',
      carbs: 13.7,
      protein: 7.6,
      fat: 2.9,
      fiber: 1.0,
      calories: 110,
      details: logged.details,
      citations: logged.citations,
      serving: serving,
      isManualEntry: true,
      updatedAt: DateTime.utc(2026, 10, 14, 12),
      loggedAt: DateTime(2026, 10, 14, 15, 10),
      // Not the meal its time would give, so a copy can't just recompute it.
      category: FoodCategory.drink,
    );
    final copy = full.withNewId();
    expect(copy.id, isNot(full.id));
    expect(copy.id, isNotEmpty);
    expect(full.withNewId().id, isNot(copy.id));
    expect(copy.toJson()..remove('id'), full.toJson()..remove('id'));
    expect(copy.serving, same(full.serving));
    expect(copy.citations, full.citations);
  });
}
