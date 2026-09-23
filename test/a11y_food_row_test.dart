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
}
