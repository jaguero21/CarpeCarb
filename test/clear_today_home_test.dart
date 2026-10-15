import 'dart:async';
import 'dart:convert';

import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/held_health.dart';
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

/// Health that answers at once, so no failure snackbar joins the queue.
class _OkHealth extends HealthKitService {
  @override
  Future<bool> deleteFoodItem(FoodItem item) async => true;

  @override
  Future<bool> writeFoodItem(FoodItem item) async => true;
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

    expect(state.foodItems.map((f) => f.name).toSet(), {'Soup', 'Roll'});
    final firstWrite = health.calls.indexWhere((c) => c.startsWith('write'));
    final lastDelete = health.calls.lastIndexWhere((c) => c.startsWith('delete'));
    expect(firstWrite, greaterThan(lastDelete));
    expect(health.calls.where((c) => c.startsWith('write')).length, 2);
  });

  testWidgets('Undo writes back to Health only the foods whose delete worked',
      (tester) async {
    final state = await start(tester);
    final health = HeldHealth();
    state.healthKitService = health;
    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    // Soup's sample is still in Health, so writing it again would double it.
    health.finishDelete('Soup', ok: false);
    health.finishDelete('Roll');
    await tester.pumpAndSettle();
    expect(state.foodItems.map((f) => f.name).toSet(), {'Soup', 'Roll'});
    expect(health.writes, ['Roll']);
  });

  testWidgets('a restored food deleted before the deletes finish is not written',
      (tester) async {
    final state = await start(tester);
    final health = HeldHealth();
    state.healthKitService = health;
    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    state.removeItemById(state.foodItems.singleWhere((f) => f.name == 'Soup').id);
    await tester.pumpAndSettle();
    health.finishDelete('Soup');
    health.finishDelete('Roll');
    await tester.pumpAndSettle();
    expect(health.writes, ['Roll']);
  });

  testWidgets("a second Clear: the first Undo writes nothing, the second's waits on its own deletes",
      (tester) async {
    final state = await start(tester);
    final health = HeldHealth();
    state.healthKitService = health;
    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    // Cleared again while the first Undo still waits on the first deletes.
    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    health.finishDelete('Soup');
    health.finishDelete('Roll');
    await tester.pumpAndSettle();
    expect(health.writes, isEmpty,
        reason: "the first Undo's foods aren't listed any more");

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(health.writes, isEmpty,
        reason: "the second Clear's deletes haven't finished");
    health.finishDelete('Soup');
    health.finishDelete('Roll');
    await tester.pumpAndSettle();
    expect(health.writes, unorderedEquals(['Soup', 'Roll']));
    expect(state.foodItems, hasLength(2));
  });

  testWidgets('Undo puts back fresh copies; the old ids stay deleted for iCloud',
      (tester) async {
    final state = await start(tester);
    state.healthKitService = _OkHealth();
    final before = {for (final f in state.foodItems) f.id: f};

    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(state.foodItems, hasLength(2));
    for (final copy in state.foodItems) {
      // The other device may already have merged the clear's markers, which
      // would delete the old ids again; a new id syncs as a new food.
      expect(before.keys, isNot(contains(copy.id)));
      final original = before.values.singleWhere((f) => f.name == copy.name);
      expect(copy.carbs, original.carbs);
      expect(copy.loggedAt, original.loggedAt);
      expect(copy.category, original.category);
    }
    final prefs = await SharedPreferences.getInstance();
    final markers =
        jsonDecode(prefs.getString(StorageKeys.foodItemsDeleted)!) as List;
    expect(markers, containsAll(['s', 'r']));
    final stored =
        jsonDecode(prefs.getString(StorageKeys.foodItems)!) as List;
    expect(stored.map((f) => (f as Map)['id']).toSet(),
        state.foodItems.map((f) => f.id).toSet());
  });

  testWidgets('the cleared snackbar goes away on its own', (tester) async {
    final state = await start(tester);
    state.healthKitService = _OkHealth();
    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text("Today's log cleared"), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text("Today's log cleared"), findsNothing);
  });

  testWidgets('under VoiceOver the cleared snackbar stays, so Undo can be reached',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = await start(tester);
    state.healthKitService = _OkHealth();
    await openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text("Today's log cleared"), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
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
    final afterLookup = state.foodItems.length; // just the apple
    expect(afterLookup, 1);

    // The lookup's own snackbar may have replaced the cleared one; Undo is
    // driven directly here so the test is about what Undo restores.
    await state.undoClearTodayForTest();
    await tester.pumpAndSettle();
    expect(state.foodItems.map((f) => f.name).toSet(), {'Soup', 'Roll', 'Apple'});
    expect(state.foodItems.length, 3);
  });

  testWidgets('VoiceOver: the menu button is "Today options", and opens the menu',
      (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester);
      final button = find.semantics.byLabel('Today options');
      expect(button.evaluate().single,
          isSemantics(isButton: true, hasTapAction: true));
      // A real label, not a tooltip: both would say the name twice.
      expect(button.evaluate().single.getSemanticsData().tooltip, isEmpty);

      // VoiceOver's double tap opens the menu.
      tester.semantics.performAction(button, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.text("Clear today's log…"), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('a long press still shows the "Today options" tooltip',
      (tester) async {
    await start(tester);
    expect(find.byTooltip('Today options'), findsOneWidget);
  });
}
