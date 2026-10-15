import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const []));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  Finder hint(String text) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == text);

  testWidgets('there is no Auto/Manual switch', (tester) async {
    await start(tester);
    expect(find.text('Auto'), findsNothing);
    expect(hint('What did you eat?'), findsOneWidget);
    expect(find.text('Add Food'), findsOneWidget);
  });

  testWidgets('the link shows the carbs field, and back again', (tester) async {
    await start(tester);
    await tester.tap(find.text('Enter carbs yourself'));
    await tester.pumpAndSettle();
    expect(hint('Food name'), findsOneWidget);
    expect(hint('Carbs (g)'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Look it up instead'), findsOneWidget);

    await tester.enterText(hint('Carbs (g)'), '45');
    await tester.tap(find.text('Look it up instead'));
    await tester.pumpAndSettle();
    expect(hint('Carbs (g)'), findsNothing);
    expect(hint('What did you eat?'), findsOneWidget);
    expect(find.text('Add Food'), findsOneWidget);

    // Showing it again starts empty.
    await tester.tap(find.text('Enter carbs yourself'));
    await tester.pumpAndSettle();
    final carbs = tester.widget<TextField>(hint('Carbs (g)'));
    expect(carbs.controller!.text, isEmpty);
  });

  testWidgets('a lookup with no carbs still opens the carbs field', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(
        const LookupResult(items: [], unknownCarbs: ['mystery stew']));
    await tester.pumpAndSettle();
    expect(hint('Carbs (g)'), findsOneWidget);
    expect(find.text('Look it up instead'), findsOneWidget);
  });

  testWidgets('VoiceOver reads the link as a button', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester);
      expect(find.semantics.byLabel('Enter carbs yourself').evaluate().single,
          isSemantics(isButton: true, hasTapAction: true));
    } finally {
      handle.dispose();
    }
  });
}
