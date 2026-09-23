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
