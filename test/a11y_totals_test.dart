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
        isSemantics(value: '25 grams, 25 of 100 grams today'));

    handle.dispose();
  });

  testWidgets('the day against the goal is spoken in the default state too',
      (WidgetTester tester) async {
    // `showingDailyTotal` starts false and is forced back to false on every
    // add, so this — not the day-total branch — is what a user hears after
    // logging anything. The goal has to survive into it.
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

    final state =
        tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.showingDailyTotal, isFalse);
    expect(
      find.semantics.byLabel('Apple').evaluate().single.getSemanticsData().value,
      contains('of 100 grams'),
    );

    handle.dispose();
  });

  testWidgets('the totals card announces itself as a button, with a hint',
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

    expect(
      find.semantics.byLabel('Apple').evaluate().single,
      isSemantics(
        isButton: true,
        hint: "Double tap to switch between today's total and the last "
            'food logged',
      ),
    );

    handle.dispose();
  });

  testWidgets('the totals card offers its long press as a rotor action',
      (WidgetTester tester) async {
    // VoiceOver has no long press, so the card's second gesture is only
    // reachable as a named action.
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
    expect(find.text('Favorites'), findsNothing);

    final finder = find.semantics.byLabel('Apple');
    final id = finder
        .evaluate()
        .single
        .getSemanticsData()
        .customSemanticsActionIds!
        .firstWhere((i) =>
            CustomSemanticsAction.getAction(i)!.label == 'Open settings');
    tester.semantics.performAction(finder, SemanticsAction.customAction,
        args: id);
    await tester.pumpAndSettle();

    // The Settings page, open on its first tab. Only the selected tab
    // renders its label, so this is the page's own text.
    expect(find.text('Favorites'), findsOneWidget);

    handle.dispose();
  });

  // The cloud sync indicator only renders behind `Platform.isIOS`, which is
  // false in host tests, so its "Synced" / "Syncing" / "Sync failed" labels
  // are on the device checklist rather than here.
}
