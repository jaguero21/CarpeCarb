import 'package:carb_tracker/config/app_theme.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/widgets/time_meal_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/contrast.dart';

void main() {
  Future<(List<String>, List<FoodCategory>)> pump(WidgetTester tester,
      {String? error, ThemeData? theme}) async {
    final picks = <String>[];
    final meals = <FoodCategory>[];
    await tester.pumpWidget(MaterialApp(
      theme: theme,
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

  test('the error is readable on the dialog in both modes', () {
    // The dialog is the surface colour at 92% over a dimmed page; the
    // surface itself is what the text sits on.
    expect(contrastRatio(timeErrorColor(dark: false), lightTheme().colorScheme.surface),
        greaterThanOrEqualTo(4.5));
    expect(contrastRatio(timeErrorColor(dark: true), darkTheme().colorScheme.surface),
        greaterThanOrEqualTo(4.5));
  });

  testWidgets('the error is drawn in the readable colour', (tester) async {
    for (final (theme, dark) in [(lightTheme(), false), (darkTheme(), true)]) {
      await pump(tester, error: 'Pick a time from today, up to now', theme: theme);
      await tester.pumpAndSettle(); // MaterialApp animates a theme change
      final text = tester.widget<Text>(find.text('Pick a time from today, up to now'));
      expect(text.style!.color, timeErrorColor(dark: dark));
    }
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

  testWidgets('at a large text size the row stacks and nothing overflows', (tester) async {
    // Every meal, since the longest label (Breakfast) is the one that would
    // not fit.
    for (final meal in FoodCategory.values) {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: AlertDialog(
                  insetPadding: EdgeInsets.zero,
                  content: TimeMealRow(
                    time: DateTime(2026, 10, 14, 12, 5),
                    meal: meal,
                    onPickTime: () {},
                    onMealChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull, reason: meal.label);
      expect(find.text('Time · 12:05 PM'), findsOneWidget);
      expect(find.text(meal.label), findsOneWidget);
    }
  });
}
