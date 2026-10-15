import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';
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

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    calls.add('delete ${item.loggedAt.hour}:${item.loggedAt.minute}');
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

  final now = DateTime.now();
  final lunch = {
    'id': 'l1',
    'name': 'Soup',
    'carbs': 20.0,
    'category': 'lunch',
    'loggedAt': now.toIso8601String(),
  };

  Future<CarbTrackerHomeState> openSoup(WidgetTester tester,
      {List<TimeOfDay?> picks = const []}) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs([lunch]));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final queue = [...picks];
    state.pickTime = (_, __) async => queue.isEmpty ? null : queue.removeAt(0);
    final handle = tester.ensureSemantics();
    tester.semantics.performAction(
        find.semantics.byLabel(RegExp(r'^Soup,')), SemanticsAction.tap);
    await tester.pumpAndSettle();
    handle.dispose();
    return state;
  }

  // Midnight is always today and never later than now (reset hour 0).
  const midnight = TimeOfDay(hour: 0, minute: 0);

  testWidgets('a new time moves the food to the meal for that time', (tester) async {
    final state = await openSoup(tester, picks: [midnight]);
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
    final state = await openSoup(tester, picks: [midnight]);
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
    final state = await openSoup(tester, picks: [const TimeOfDay(hour: 23, minute: 59)]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    // At 23:59 itself this pick is valid; skip in that one minute.
    if (now.hour == 23 && now.minute == 59) return;
    expect(find.text('Pick a time from today, up to now'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
    expect(state.foodItems.single.loggedAt, now);
  });

  testWidgets('Health moves the entry: delete at the old time, then write at the new',
      (tester) async {
    final state = await openSoup(tester, picks: [midnight]);
    final health = _RecordingHealth();
    state.healthKitService = health;
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(health.calls, ['delete ${now.hour}:${now.minute}', 'write 0:0']);
  });

  testWidgets('VoiceOver hears the new meal and time', (tester) async {
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
    await openSoup(tester, picks: [midnight]);
    await tester.tap(find.textContaining('Time · '));
    await tester.pumpAndSettle();
    expect(announcements, contains('Snack, 12:00 AM'));
  });
}
