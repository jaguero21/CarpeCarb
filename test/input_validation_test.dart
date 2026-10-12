import 'dart:convert';
import 'dart:io';
import 'package:carb_tracker/utils/input_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Input Validation Tests', () {
    // The real validator, not a copy of it.
    String? validateFoodInput(String input) =>
        InputValidation.validateFoodInput(input);

    test('accepts valid food names', () {
      expect(validateFoodInput('Apple'), null);
      expect(validateFoodInput('Banana Bread'), null);
      expect(validateFoodInput('Chicken & Rice'), null);
      expect(validateFoodInput("McDonald's Fries"), null);
      expect(validateFoodInput('Brown Rice (cooked)'), null);
      expect(validateFoodInput('Coca-Cola'), null);
      expect(validateFoodInput('Soup, Tomato'), null);
      expect(validateFoodInput('Mac & Cheese'), null);
    });

    test('rejects empty input', () {
      expect(validateFoodInput(''), 'Please enter a food item');
      expect(validateFoodInput('   '), 'Please enter a food item');
    });

    test('rejects too short input', () {
      expect(validateFoodInput('A'), 'Food name must be at least 2 characters');
    });

    test('rejects too long input', () {
      final longString = 'A' * 101;
      expect(validateFoodInput(longString),
        'Food name is too long (max 100 characters)');
    });

    test('rejects invalid special characters', () {
      expect(validateFoodInput('Apple@Home'),
        'Please use only letters, numbers, and common punctuation');
      expect(validateFoodInput('Food#1'),
        'Please use only letters, numbers, and common punctuation');
      expect(validateFoodInput('Test\$Food'),
        'Please use only letters, numbers, and common punctuation');
    });

    test('rejects only numbers', () {
      expect(validateFoodInput('123'), 'Please enter a valid food name');
      expect(validateFoodInput('12.5'), 'Please enter a valid food name');
    });

    test('trims whitespace correctly', () {
      expect(validateFoodInput('  Apple  '), null);
      expect(validateFoodInput('\nBanana\n'), null);
    });

    test('accepts numbers in food names', () {
      expect(validateFoodInput('Vitamin B12'), null);
      expect(validateFoodInput('7-Eleven Pizza'), null);
      expect(validateFoodInput('2% Milk'), null);
    });

    test('accepts common punctuation', () {
      expect(validateFoodInput('Mrs. Dash Seasoning'), null);
      expect(validateFoodInput('Salt & Pepper'), null);
      expect(validateFoodInput('Bread, Wheat'), null);
      expect(validateFoodInput('Pasta (whole wheat)'), null);
    });
  });

  // The same cases the server runs (functions/test/foodInput.test.js), so the
  // app and the server can't drift apart again.
  group('shared rules with the server', () {
    final cases = jsonDecode(
        File('functions/test/fixtures/food-input-cases.json').readAsStringSync());
    String inputOf(Map c) => c['repeat'] != null
        ? (c['repeat'][0] as String) * (c['repeat'][1] as int)
        : c['input'] as String;

    test('valid cases pass', () {
      for (final c in cases['valid']) {
        expect(InputValidation.validateFoodInput(c['input']), isNull,
            reason: jsonEncode(c['input']));
      }
    });

    test('invalid cases are rejected with the same message', () {
      for (final c in cases['invalid']) {
        final input = inputOf(c);
        expect(InputValidation.validateFoodInput(input), c['error'],
            reason: jsonEncode(input));
      }
    });

    test('curly quotes and the inch mark become a straight quote for the API', () {
      expect(InputValidation.sanitizeForApi('6\u201D sub'), '6" sub');
      expect(InputValidation.sanitizeForApi('6\u2033 sub'), '6" sub');
      expect(InputValidation.sanitizeForApi('\u201C6 inch\u201D sub'), '"6 inch" sub');
    });
  });
}
