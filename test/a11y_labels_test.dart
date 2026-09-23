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
}
