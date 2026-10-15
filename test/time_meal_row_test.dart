import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/widgets/time_meal_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(List<String>, List<FoodCategory>)> pump(WidgetTester tester,
      {String? error}) async {
    final picks = <String>[];
    final meals = <FoodCategory>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TimeMealRow(
          time: DateTime(2026, 10, 14, 12, 5),
          meal: FoodCategory.lunch,
          onPickTime: () => picks.add('pick'),
          onMealChanged: meals.add,
          error: error,
        ),
      ),
    ));
    return (picks, meals);
  }

  testWidgets('shows the time and meal; the time is a button', (tester) async {
    final (picks, _) = await pump(tester);
    expect(find.text('Time · 12:05 PM'), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
    await tester.tap(find.text('Time · 12:05 PM'));
    expect(picks, ['pick']);
  });

  testWidgets('picking a meal reports it', (tester) async {
    final (_, meals) = await pump(tester);
    await tester.tap(find.text('Lunch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dinner').last);
    await tester.pumpAndSettle();
    expect(meals, [FoodCategory.dinner]);
  });

  testWidgets('an error shows under the row', (tester) async {
    await pump(tester, error: 'Pick a time from today, up to now');
    expect(find.text('Pick a time from today, up to now'), findsOneWidget);
  });

  testWidgets('VoiceOver labels', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await pump(tester);
      final time = find.semantics.byLabel('Time, 12:05 PM').evaluate().single;
      expect(time, isSemantics(isButton: true, hasTapAction: true));
      expect(time.getSemanticsData().hint, 'Double tap to change');
      expect(find.semantics.byLabel(RegExp(r'^Meal, Lunch')), findsWidgets);
    } finally {
      handle.dispose();
    }
  });
}
