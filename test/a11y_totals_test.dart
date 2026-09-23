import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

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
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'),
        (call) async => call.method == 'pushToCloud' ? false : null);
    addTearDown(() {
      messenger()
          .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
      messenger().setMockMethodCallHandler(
          const MethodChannel('com.carpecarb/cloudsync'), null);
    });
  }

  String todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Map<String, Object> basePrefs({double? goal, List<Object>? foods}) => {
        'disclaimer_accepted': true,
        if (goal != null) 'daily_carb_goal': goal,
        if (foods != null) ...{
          'food_items': jsonEncode(foods),
          'last_save_date': todayKey(),
        },
      };

  testWidgets('the day total says what it is and how it compares to the goal',
      (WidgetTester tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues(basePrefs(goal: 100));
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    // Without this it merges into "0.0g of 100g daily goal" plus a bare
    // percentage from the progress bar.
    expect(find.semantics.byLabel("Today's total").evaluate().single,
        isSemantics(value: '0 of 100 grams'));

    handle.dispose();
  });

  testWidgets('the day total says when no goal is set',
      (WidgetTester tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues(basePrefs());
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(find.semantics.byLabel("Today's total").evaluate().single,
        isSemantics(value: '0 grams, no goal set'));

    handle.dispose();
  });

  testWidgets('showing a single food announces that food, not the day',
      (WidgetTester tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues(basePrefs(goal: 100, foods: [
      {
        'id': 'a',
        'name': 'Apple',
        'carbs': 25.0,
        'loggedAt': '2026-09-22T08:30:00.000',
        'category': 'snack'
      },
    ]));
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(find.semantics.byLabel('Apple').evaluate().single,
        isSemantics(value: '25 grams'));

    handle.dispose();
  });

  // The cloud sync indicator only renders behind `Platform.isIOS`, which is
  // false in host tests, so its "Synced" / "Syncing" / "Sync failed" labels
  // are on the device checklist rather than here.
}
