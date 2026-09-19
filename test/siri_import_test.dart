import 'dart:convert';

import 'package:carb_tracker/services/siri_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 18, 12, 0);
  String utc(DateTime local) => local.toUtc().toIso8601String();

  test('splits items logged today from items logged on an earlier day', () {
    final json = jsonEncode([
      {'name': 'Oatmeal', 'carbs': 27, 'loggedAt': utc(DateTime(2026, 9, 18, 8, 0))},
      {'name': 'Late snack', 'carbs': 15, 'loggedAt': utc(DateTime(2026, 9, 17, 22, 0))},
    ]);

    final result = SiriImport.parse(json, now, 0);

    expect(result.today.map((i) => i.name), ['Oatmeal']);
    expect(result.earlier.map((i) => i.name), ['Late snack']);
    expect(result.earlier.single.loggedAt, DateTime(2026, 9, 17, 22, 0));
  });

  test('the reset hour decides which day an item belongs to', () {
    // 02:00 on the 18th is still the 17th with a 4 AM reset...
    final json = jsonEncode([
      {'name': 'Night snack', 'carbs': 10, 'loggedAt': utc(DateTime(2026, 9, 18, 2, 0))},
    ]);

    // ...so at 03:00 it's today, at noon it's earlier.
    expect(SiriImport.parse(json, DateTime(2026, 9, 18, 3, 0), 4).today, hasLength(1));
    expect(SiriImport.parse(json, now, 4).earlier, hasLength(1));
  });

  test('keeps macros, details, and citations', () {
    final json = jsonEncode([
      {
        'name': 'Big Mac',
        'carbs': 45,
        'protein': 25,
        'fat': 30.5,
        'fiber': 3,
        'calories': 590,
        'details': "McDonald's [1]",
        'citations': ['https://example.com', 7],
        'loggedAt': utc(DateTime(2026, 9, 18, 11, 0)),
      },
    ]);

    final item = SiriImport.parse(json, now, 0).today.single;

    expect(item.carbs, 45.0);
    expect(item.protein, 25.0);
    expect(item.fat, 30.5);
    expect(item.fiber, 3.0);
    expect(item.calories, 590.0);
    expect(item.details, "McDonald's [1]");
    expect(item.citations, ['https://example.com']);
  });

  test('missing, bad, or future timestamps count as today', () {
    final json = jsonEncode([
      {'name': 'No time', 'carbs': 5},
      {'name': 'Bad time', 'carbs': 5, 'loggedAt': 'yesterday-ish'},
      {'name': 'Future', 'carbs': 5, 'loggedAt': utc(DateTime(2026, 9, 19, 9, 0))},
    ]);

    final result = SiriImport.parse(json, now, 0);

    expect(result.today.map((i) => i.name), ['No time', 'Bad time', 'Future']);
    expect(result.today.first.loggedAt, now);
    expect(result.earlier, isEmpty);
  });

  test('skips entries without a name and rejects a non-list buffer', () {
    final json = jsonEncode([
      {'carbs': 5},
      'junk',
      {'name': 'Apple', 'carbs': 25},
    ]);

    expect(SiriImport.parse(json, now, 0).today.map((i) => i.name), ['Apple']);
    expect(() => SiriImport.parse('{"name": "Apple"}', now, 0), throwsFormatException);
  });
}
