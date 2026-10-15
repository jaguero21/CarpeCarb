import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

/// Stands in for HealthKit (Health sync is always on), recording the time of
/// each sample it deletes or writes. Same idea as test/serving_edit_test.dart.
class _RecordingHealth extends HealthKitService {
  final calls = <String>[];

  /// Each delete's food and the millisecond its window starts in
  /// (healthDeleteWindow), which is what decides the samples it removes.
  final deletes = <(String, int)>[];

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    calls.add('delete ${item.loggedAt.hour}:${item.loggedAt.minute}');
    deletes.add((item.name, item.loggedAt.millisecondsSinceEpoch));
    return true;
  }

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.loggedAt.hour}:${item.loggedAt.minute}');
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Lunch today, with seconds, the way a food logged then would carry them.
  DateTime lunchtime(DateTime now) =>
      DateTime(now.year, now.month, now.day, 12, 30, 15, 250);

  /// Shows today with [foods] logged. The time picker answers with [picks],
  /// in order.
  Future<CarbTrackerHomeState> showToday(
      WidgetTester tester, List<Map<String, Object?>> foods,
      {List<TimeOfDay?> picks = const []}) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(foods));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final queue = [...picks];
    state.pickTime = (_, __) async => queue.isEmpty ? null : queue.removeAt(0);
    return state;
  }

  /// Opens [name]'s details the way VoiceOver does.
  Future<void> openDetails(WidgetTester tester, String name) async {
    final handle = tester.ensureSemantics();
    tester.semantics.performAction(
        find.semantics.byLabel(RegExp('^$name,')), SemanticsAction.tap);
    await tester.pumpAndSettle();
    handle.dispose();
  }

  /// Picks the next time from the picker, then taps Update.
  Future<void> moveAndUpdate(WidgetTester tester) async {
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
  }

  /// Shows today with Soup in it, logged at [loggedAt] (lunchtime by
  /// default) as [category] (Lunch by default), and opens Soup's details.
  /// The time picker answers with [picks], in order.
  Future<CarbTrackerHomeState> openSoup(WidgetTester tester, DateTime now,
      {List<TimeOfDay?> picks = const [],
      DateTime? loggedAt,
      String category = 'lunch'}) async {
    final state = await showToday(tester, [
      {
        'id': 'l1',
        'name': 'Soup',
        'carbs': 20.0,
        'category': category,
        'loggedAt': (loggedAt ?? lunchtime(now)).toIso8601String(),
      },
    ], picks: picks);
    await openDetails(tester, 'Soup');
    return state;
  }

  // Midnight is always today and never later than now (reset hour 0), except
  // in the first minute of the day, when it is now's own minute. Tests that
  // pick it skip that minute.
  const midnight = TimeOfDay(hour: 0, minute: 0);
  bool inMidnightMinute(DateTime now) => now.hour == 0 && now.minute == 0;

  testWidgets('a new time moves the food to the meal for that time', (tester) async {
    final now = DateTime.now();
    if (inMidnightMinute(now)) return;
    final state = await openSoup(tester, now, picks: [midnight]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(find.text('Time · 12:00 AM'), findsOneWidget);
    expect(find.text('Snack'), findsWidgets); // the meal dropdown followed the time

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    final soup = state.foodItems.single;
    expect(soup.loggedAt.hour, 0);
    expect(soup.loggedAt.minute, 0);
    expect(soup.category.name, 'snack');
    expect(soup.updatedAt, isNotNull);
    expect(find.text('Moved to Snack, 12:00 AM'), findsOneWidget);
  });

  testWidgets('a meal picked by hand stays when the time changes', (tester) async {
    final now = DateTime.now();
    if (inMidnightMinute(now)) return;
    final state = await openSoup(tester, now, picks: [midnight]);
    await tester.tap(find.text('Lunch').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dinner').last);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(state.foodItems.single.category.name, 'dinner');
  });

  testWidgets('a time outside today is refused inside the dialog', (tester) async {
    final now = DateTime.now();
    // At 23:59 itself this pick is valid; skip in that one minute.
    if (now.hour == 23 && now.minute == 59) return;
    final state = await openSoup(tester, now,
        picks: [const TimeOfDay(hour: 23, minute: 59)]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(find.text('Pick a time from today, up to now'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
    expect(state.foodItems.single.loggedAt, lunchtime(now));
  });

  testWidgets('Health moves the entry: delete at the old time, then write at the new',
      (tester) async {
    final now = DateTime.now();
    if (inMidnightMinute(now)) return;
    final state = await openSoup(tester, now, picks: [midnight]);
    final health = _RecordingHealth();
    state.healthKitService = health;
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(health.calls, ['delete 12:30', 'write 0:0']);
  });

  testWidgets('VoiceOver hears the new meal and time', (tester) async {
    final now = DateTime.now();
    if (inMidnightMinute(now)) return;
    final announcements = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility, (message) async {
      final map = message as Map;
      if (map['type'] == 'announce') {
        announcements.add((map['data'] as Map)['message'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, null));
    await openSoup(tester, now, picks: [midnight]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(announcements, contains('Snack, 12:00 AM'));
  });

  testWidgets('two foods from one lookup moved to one minute keep their own Health samples',
      (tester) async {
    final now = DateTime.now();
    if (inMidnightMinute(now)) return;
    final state = await showToday(tester, const [], picks: [midnight, midnight]);
    final health = _RecordingHealth();
    state.healthKitService = health;
    // A lookup spaces its foods 1 ms apart, so each has its own Health sample.
    await state.applyLookupResultForTest(LookupResult(items: [
      FoodItem(name: 'Burger', carbs: 40, loggedAt: now),
      FoodItem(
          name: 'Fries', carbs: 48, loggedAt: now.add(const Duration(milliseconds: 1))),
    ]));
    await tester.pumpAndSettle();

    for (final name in ['Burger', 'Fries']) {
      await openDetails(tester, name);
      await moveAndUpdate(tester);
    }
    final burger = state.foodItems.firstWhere((f) => f.name == 'Burger');
    final fries = state.foodItems.firstWhere((f) => f.name == 'Fries');
    expect(burger.loggedAt.hour, 0);
    expect(fries.loggedAt.hour, 0);
    expect(
        (burger.loggedAt.millisecondsSinceEpoch - fries.loggedAt.millisecondsSinceEpoch)
            .abs(),
        greaterThanOrEqualTo(1));

    health.deletes.clear();
    state.removeItemById(burger.id);
    await tester.pumpAndSettle();
    expect(health.deletes, [('Burger', burger.loggedAt.millisecondsSinceEpoch)]);
    expect(health.deletes.single.$2, isNot(fries.loggedAt.millisecondsSinceEpoch),
        reason: "deleting Burger must not take Fries' sample with it");
  });

  testWidgets('foods with the same seconds moved to one minute still get a millisecond each',
      (tester) async {
    final now = DateTime.now();
    // Both foods must be today: now and a minute before.
    if (now.hour == 0 && now.minute < 2) return;
    final earlier = now.subtract(const Duration(minutes: 1));
    final state = await showToday(tester, [
      {'id': 'a', 'name': 'Tea', 'carbs': 5.0, 'category': 'snack',
       'loggedAt': now.toIso8601String()},
      {'id': 'b', 'name': 'Toast', 'carbs': 15.0, 'category': 'snack',
       'loggedAt': earlier.toIso8601String()},
    ], picks: [midnight, midnight]);
    for (final name in ['Tea', 'Toast']) {
      await openDetails(tester, name);
      await moveAndUpdate(tester);
    }
    final tea = state.foodItems.firstWhere((f) => f.name == 'Tea');
    final toast = state.foodItems.firstWhere((f) => f.name == 'Toast');
    expect(tea.loggedAt.minute, 0);
    expect(toast.loggedAt.minute, 0);
    expect(toast.loggedAt.millisecondsSinceEpoch,
        tea.loggedAt.millisecondsSinceEpoch + 1,
        reason: 'Toast lands in Tea\'s millisecond, so Update moves it on by one');
  });

  testWidgets('picking the food\'s own minute changes nothing, even after another pick',
      (tester) async {
    final now = DateTime.now();
    if (inMidnightMinute(now)) return;
    final own = TimeOfDay.fromDateTime(now);
    final state = await openSoup(tester, now,
        loggedAt: now,
        category: FoodCategory.fromTime(now).name,
        picks: [own, midnight, own]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(find.text('Update'), findsNothing);

    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(find.text('Update'), findsOneWidget);

    // Back to the minute it was logged in: its exact time, so no Update.
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(find.text('Update'), findsNothing);
    expect(state.foodItems.single.loggedAt, now);
  });
}
