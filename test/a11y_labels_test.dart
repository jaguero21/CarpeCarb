import 'package:carb_tracker/models/serving_info.dart';
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

    test('says how far over the goal the day is', () {
      // The card draws "20g over goal" in terracotta; without this the
      // spoken value stops at the two numbers and leaves the comparison to
      // the listener.
      expect(carbProgressValue(total: 120, goal: 100),
          '120 of 100 grams, 20 grams over goal');
    });

    test('says nothing about being over when exactly at the goal', () {
      expect(carbProgressValue(total: 100, goal: 100), '100 of 100 grams');
    });

    test('says nothing about being over when under the goal', () {
      expect(carbProgressValue(total: 99.5, goal: 100), '99.5 of 100 grams');
    });
  });

  group('spokenServing', () {
    ServingInfo usda(double count) => ServingInfo.usda(
          fdcId: 1,
          portions: const [ServingPortion(id: 'p1', label: '1 cup', grams: 240)],
          per100g: const Nutrients(carbs: 5),
          portionId: 'p1',
          count: count,
        );
    ServingInfo web(double count) =>
        ServingInfo.web(base: const Nutrients(carbs: 10), count: count);

    test('USDA, one portion: the portion and its weight in words', () {
      expect(spokenServing(usda(1)), '1 cup, 240 grams');
    });

    test('USDA, several: the count in words, not "×"', () {
      expect(spokenServing(usda(2)), '2 servings of 1 cup, 480 grams');
      expect(spokenServing(usda(2.5)), '2.5 servings of 1 cup, 600 grams');
    });

    test('web: nothing extra for one, the count for more', () {
      expect(spokenServing(web(1)), isNull);
      expect(spokenServing(web(2)), '2 servings');
      expect(spokenServing(web(0.5)), '0.5 servings');
    });
  });

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
}
