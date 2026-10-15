import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester) async {
    // The default 800x600 screen puts the Add button under the bottom bar.
    tester.view.physicalSize = const Size(2400, 3600); // 800x1200 at 3x
    addTearDown(tester.view.reset);
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

  /// Types [carbs] into the carbs field and taps Add, as the user would.
  Future<void> addManually(WidgetTester tester, String carbs) async {
    await tester.enterText(hint('Carbs (g)'), carbs);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
  }

  testWidgets('after a not-found food is added, the next entry is a lookup again',
      (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(
        const LookupResult(items: [], unknownCarbs: ['mystery stew']));
    await tester.pumpAndSettle();
    await addManually(tester, '30');

    expect(state.foodItems.single.name, 'mystery stew');
    expect(find.text('Enter carbs yourself'), findsOneWidget);
    expect(hint('What did you eat?'), findsOneWidget);
    expect(hint('Carbs (g)'), findsNothing);
  });

  testWidgets('the carbs field opened with the link stays open after an add',
      (tester) async {
    final state = await start(tester);
    await tester.tap(find.text('Enter carbs yourself'));
    await tester.pumpAndSettle();
    await tester.enterText(hint('Food name'), 'Toast');
    await addManually(tester, '14.5');

    expect(state.foodItems.single.name, 'Toast');
    expect(find.text('Look it up instead'), findsOneWidget);
    expect(hint('Carbs (g)'), findsOneWidget);
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
