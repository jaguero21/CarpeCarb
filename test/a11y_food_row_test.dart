import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  void stubChannels() {
    final appGroup = <String, Object?>{};
    messenger().setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      final args = (call.arguments as Map?) ?? const {};
      if (call.method == 'saveWidgetData') {
        appGroup[args['id'] as String] = args['data'];
        return true;
      }
      if (call.method == 'getWidgetData') return appGroup[args['id'] as String];
      return null;
    });
    // Logging or deleting saves and pushes; an unstubbed channel never answers.
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/siribuffer'), (call) async => null);
    addTearDown(() {
      for (final name in const [
        'home_widget',
        'com.carpecarb/cloudsync',
        'com.carpecarb/siribuffer',
      ]) {
        messenger().setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
  }

  void seedTwoFoods() {
    SharedPreferences.setMockInitialValues({
      'food_items': jsonEncode([
        {
          'id': 'a',
          'name': 'Apple',
          'carbs': 25.0,
          'loggedAt': '2026-09-22T08:30:00.000',
          'category': 'snack'
        },
        {
          'id': 'b',
          'name': 'Bagel',
          'carbs': 48.0,
          'loggedAt': '2026-09-22T08:00:00.000',
          'category': 'breakfast'
        },
      ]),
      'last_save_date': todayKey(),
      // Otherwise the disclaimer dialog covers the screen and the rows are not
      // in the accessibility tree at all.
      'disclaimer_accepted': true,
    });
  }

  /// Performs a named rotor action on the row whose label is [label].
  void performRotorAction(WidgetTester tester, String label, String action) {
    final finder = find.semantics.byLabel(label);
    final node = finder.evaluate().single;
    final id = node
        .getSemanticsData()
        .customSemanticsActionIds!
        .firstWhere((i) => CustomSemanticsAction.getAction(i)!.label == action);
    tester.semantics
        .performAction(finder, SemanticsAction.customAction, args: id);
  }

  /// Activates the row the way VoiceOver does, opening its details dialog.
  void openDetails(WidgetTester tester, String label) {
    tester.semantics
        .performAction(find.semantics.byLabel(label), SemanticsAction.tap);
  }

  testWidgets('a food row reads as one sentence with both actions',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(
      find.semantics
          .byLabel('Apple, 25 grams of carbs, logged 8:30 AM')
          .evaluate()
          .single,
      isSemantics(
        hint: 'Double tap for details',
        customActions: const [
          CustomSemanticsAction(label: 'Delete'),
          CustomSemanticsAction(label: 'Save to Food list'),
        ],
      ),
    );

    handle.dispose();
  });

  testWidgets('the Delete rotor action actually removes the food',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state =
        tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.foodItems.map((f) => f.name), ['Apple', 'Bagel']);

    // An advertised action that does nothing is worse than none.
    performRotorAction(
        tester, 'Apple, 25 grams of carbs, logged 8:30 AM', 'Delete');
    await tester.pump(const Duration(milliseconds: 400));

    expect(state.foodItems.map((f) => f.name), ['Bagel']);
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the Delete rotor action removes the food it was offered on',
      (WidgetTester tester) async {
    // Deleting only ever the first row can't tell `removeItem(index)` from
    // `removeItem(0)`. Bagel is at index 1, so position has to be right.
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state =
        tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));

    performRotorAction(
        tester, 'Bagel, 48 grams of carbs, logged 8:00 AM', 'Delete');
    await tester.pump(const Duration(milliseconds: 400));

    expect(state.foodItems.map((f) => f.name), ['Apple']);
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the row hides the raw numbers it draws',
      (WidgetTester tester) async {
    // Without `excludeSemantics` the sentence label is still there and every
    // row test still passes, while VoiceOver also reads "25.0g" — the exact
    // "point zero" the label exists to avoid.
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    final row = find.semantics
        .byLabel('Apple, 25 grams of carbs, logged 8:30 AM')
        .evaluate()
        .single;
    final descendants = <String>[];
    void visit(SemanticsNode node) {
      node.visitChildren((child) {
        descendants.add(child.getSemanticsData().label);
        visit(child);
        return true;
      });
    }

    visit(row);
    expect(descendants.join(' | '), isNot(contains('25.0')));

    handle.dispose();
  });

  testWidgets('the Save rotor action saves the food to the Food list',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    performRotorAction(tester, 'Apple, 25 grams of carbs, logged 8:30 AM',
        'Save to Food list');
    await tester.pump(const Duration(milliseconds: 400));

    final saved =
        (await SharedPreferences.getInstance()).getString('saved_foods');
    expect(saved, contains('Apple'));
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the details dialog offers Delete and Save without a swipe',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state =
        tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));

    // VoiceOver's double tap. A long press opens the same dialog for a
    // sighted user, but the row's swipe recogniser swallows it in tests, so
    // that path is on the device checklist instead.
    openDetails(tester, 'Apple, 25 grams of carbs, logged 8:30 AM');
    await tester.pumpAndSettle();
    expect(find.text('Save to Food list'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(state.foodItems.map((f) => f.name), ['Bagel']);
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the details dialog can save a food to the Food list',
      (WidgetTester tester) async {
    stubChannels();
    seedTwoFoods();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    // VoiceOver's double tap. A long press opens the same dialog for a
    // sighted user, but the row's swipe recogniser swallows it in tests, so
    // that path is on the device checklist instead.
    openDetails(tester, 'Apple, 25 grams of carbs, logged 8:30 AM');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to Food list'));
    await tester.pumpAndSettle();

    final saved =
        (await SharedPreferences.getInstance()).getString('saved_foods');
    expect(saved, contains('Apple'));
    handle.dispose();
    await tester.pump(const Duration(seconds: 4));
  });
}
