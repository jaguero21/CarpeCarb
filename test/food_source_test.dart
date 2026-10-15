import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/food_source.dart';
import 'package:carb_tracker/models/serving_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ServingInfo web() =>
      ServingInfo.fromServerItem({'source': 'web'}, const Nutrients(carbs: 10))!;
  ServingInfo usda() => ServingInfo.fromServerItem({
        'source': 'usda',
        'fdcId': 1,
        'serving': {'portionId': 'p1', 'label': '1 cup', 'grams': 245, 'count': 1},
        'portions': [
          {'id': 'p1', 'label': '1 cup', 'grams': 245},
        ],
        'per100g': {'carbs': 5.6},
      }, const Nutrients(carbs: 13.7))!;

  test('a manual entry is manual, even with a USDA serving', () {
    expect(
        foodSourceOf(FoodItem(name: 'x', carbs: 1, isManualEntry: true, serving: usda())),
        FoodSource.manual);
  });

  test('the saved serving decides', () {
    expect(foodSourceOf(FoodItem(name: 'x', carbs: 1, serving: usda())), FoodSource.usda);
    expect(foodSourceOf(FoodItem(name: 'x', carbs: 1, serving: web())), FoodSource.web);
  });

  test('without a serving, the server details decide', () {
    expect(
        foodSourceOf(FoodItem(
            name: 'x',
            carbs: 1,
            details: 'USDA FoodData Central (Survey (FNDDS)): Soup, pho, 1 cup (245 g).')),
        FoodSource.usda);
    expect(
        foodSourceOf(FoodItem(
            name: 'x', carbs: 1, details: 'Web source, not USDA. Per the label, 1 bar.')),
        FoodSource.web);
  });

  test('anything else has no known source', () {
    expect(foodSourceOf(FoodItem(name: 'x', carbs: 1)), isNull);
    expect(foodSourceOf(FoodItem(name: 'x', carbs: 1, details: 'Per Chipotle, 1 bowl.')),
        isNull);
  });

  test('labels and spoken forms', () {
    expect(FoodSource.values.map((s) => s.label), ['USDA', 'Web', 'Manual']);
    expect(FoodSource.values.map((s) => s.spoken),
        ['from USDA', 'from the web', 'entered manually']);
  });
}
