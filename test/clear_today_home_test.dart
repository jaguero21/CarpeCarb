import 'dart:async';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

/// Records Health calls in order. Deletes finish only when [releaseDeletes]
/// is called, to prove Undo waits for them before writing.
class _SlowHealth extends HealthKitService {
  final calls = <String>[];
  final _deletes = Completer<void>();

  void releaseDeletes() => _deletes.complete();

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    await _deletes.future;
    calls.add('delete ${item.name}');
    return true;
  }

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.name}');
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> food(String id, String name, double carbs, int minutesAgo) => {
        'id': id,
        'name': name,
        'carbs': carbs,
        'category': 'lunch',
        'loggedAt':
            DateTime.now().subtract(Duration(minutes: minutesAgo)).toIso8601String(),
      };

  Future<CarbTrackerHomeState> start(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs([
      food('s', 'Soup', 20, 3),
      food('r', 'Roll', 32, 2),
    ]));
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  Future<void> openClear(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Today options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Clear today's log…"));
    await tester.pumpAndSettle();
  }

  testWidgets('the menu asks first, with the number of foods; Cancel keeps them',
      (tester) async {
    final state = await start(tester);
    await openClear(tester);
    expect(find.text("Clear today's log?"), findsOneWidget);
    expect(find.text('All 2 foods will be removed from today and from Apple Health.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.foodItems.length, 2);
  });

  testWidgets('Clear empties today; Undo puts the foods back, in Health too, after the deletes',
      (tester) async {
    final state = await start(tester);
    final health = _SlowHealth();
    state.healthKitService = health;

    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(state.foodItems, isEmpty);
    expect(find.text("Today's log cleared"), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(health.calls.where((c) => c.startsWith('write')), isEmpty,
        reason: 'Undo must not write before the Clear deletes finish');
    health.releaseDeletes();
    await tester.pumpAndSettle();

    expect(state.foodItems.map((f) => f.id).toSet(), {'s', 'r'});
    final firstWrite = health.calls.indexWhere((c) => c.startsWith('write'));
    final lastDelete = health.calls.lastIndexWhere((c) => c.startsWith('delete'));
    expect(firstWrite, greaterThan(lastDelete));
    expect(health.calls.where((c) => c.startsWith('write')).length, 2);
  });

  testWidgets('a food logged between Clear and Undo stays, and nothing doubles',
      (tester) async {
    final state = await start(tester);
    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Apple', carbs: 25)]));
    await tester.pumpAndSettle();
    final cleared = state.foodItems.length; // just the apple
    expect(cleared, 1);

    // The lookup's own snackbar may have replaced the cleared one; Undo is
    // driven directly here so the test is about what Undo restores.
    await state.undoClearTodayForTest();
    await tester.pumpAndSettle();
    expect(state.foodItems.map((f) => f.name).toSet(), {'Soup', 'Roll', 'Apple'});
    expect(state.foodItems.length, 3);
  });

  testWidgets('VoiceOver: the menu button is "Today options"', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester);
      // PopupMenuButton gives its tooltip to semantics as the tooltip, not as
      // a label (the iOS engine folds it into the label VoiceOver speaks).
      expect(tester.getSemantics(find.byTooltip('Today options')),
          isSemantics(
              tooltip: 'Today options', isButton: true, hasTapAction: true));
    } finally {
      handle.dispose();
    }
  });
}
