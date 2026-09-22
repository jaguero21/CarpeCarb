// ignore_for_file: invalid_use_of_protected_member
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';

void main() {
  String keyOf(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  String todayKey() => keyOf(DateTime.now());

  String yesterdayKey() {
    final now = DateTime.now();
    return keyOf(DateTime(now.year, now.month, now.day - 1));
  }

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Answers the home_widget plugin's calls, which otherwise never complete
  /// in tests, from an in-memory App Group. Returns it so a test can seed it.
  Map<String, Object?> stubHomeWidget() {
    const channel = MethodChannel('home_widget');
    final appGroup = <String, Object?>{};
    messenger().setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'saveWidgetData':
          appGroup[args['id'] as String] = args['data'];
          return true;
        case 'getWidgetData':
          return appGroup[args['id'] as String] ?? args['defaultValue'];
      }
      return null;
    });
    addTearDown(() => messenger().setMockMethodCallHandler(channel, null));
    return appGroup;
  }

  /// Makes iCloud pulls return an empty payload, so a resume runs
  /// `_applyCloudData` (and its `_loadSavedData`) alongside the resume's own.
  void stubCloudSync() {
    const channel = MethodChannel('com.carpecarb/cloudsync');
    messenger().setMockMethodCallHandler(channel,
        (call) async => call.method == 'pullFromCloud' ? <String, Object?>{} : null);
    addTearDown(() => messenger().setMockMethodCallHandler(channel, null));
  }

  // Setup SharedPreferences mock before tests
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Carb Tracker Total Calculation Tests', () {
    testWidgets('Initial total should be 0.0', (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.totalCarbs, 0.0);
      expect(state.foodItems, isEmpty);
    });

    testWidgets('Total updates when adding items manually',
        (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      // Get the state to manually add items (simulating successful API calls)
      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      // Manually add food items to simulate API responses
      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 25.0);

      // Add second item — must also notify AnimatedList
      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 52.0);
      // Banana is in foodItems but AnimatedList only knows about 1 item
      // (initialItemCount is only used on first build), so verify via state
      expect(state.foodItems.any((item) => item.name == 'Banana'), isTrue);
    });

    testWidgets('Total updates when removing items',
        (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      // Add multiple items
      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
        state.foodItems.add(FoodItem(name: 'Orange', carbs: 15.0));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 67.0);

      // Remove second item (Banana - 27g)
      state.removeItem(1);
      await tester.pumpAndSettle();

      // Total should be 40.0g (67 - 27)
      expect(state.totalCarbs, 40.0);
      expect(state.foodItems.any((item) => item.name == 'Banana'), isFalse);

      // Remove first item (Apple - 25g)
      state.removeItem(0);
      await tester.pumpAndSettle();

      // Total should be 15.0g (40 - 25)
      expect(state.totalCarbs, 15.0);
      expect(state.foodItems.any((item) => item.name == 'Apple'), isFalse);
    });

    testWidgets('Reset clears total and items', (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      // Add items
      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 52.0);
      expect(find.text('Reset'), findsOneWidget);

      // Invoke reset directly — the Reset button can be off-screen in the
      // default test surface (800×600) when the header row overflows.
      state.resetTotalForTest();
      await tester.pumpAndSettle();

      // Verify total is back to 0
      expect(state.totalCarbs, 0.0);
      expect(state.foodItems, isEmpty);
    });

    testWidgets('Total calculation with decimal values',
        (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      // Add items with decimal carb counts
      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Item1', carbs: 12.5));
        state.foodItems.add(FoodItem(name: 'Item2', carbs: 8.3));
        state.foodItems.add(FoodItem(name: 'Item3', carbs: 5.7));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      expect(state.totalCarbs, closeTo(26.5, 0.0001));

      // Remove item with 8.3g
      state.removeItem(1);
      await tester.pumpAndSettle();

      // Should be 18.2g (26.5 - 8.3)
      expect(state.totalCarbs, closeTo(18.2, 0.0001));
    });

    testWidgets('Delete updates total correctly', (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      // Add items
      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 52.0);

      // Simulate deleting the first item.
      state.removeItem(0);
      await tester.pumpAndSettle();

      // Total should update to 27.0g.
      expect(state.totalCarbs, 27.0);
      expect(state.foodItems.any((item) => item.name == 'Apple'), isFalse);
      expect(state.foodItems.any((item) => item.name == 'Banana'), isTrue);
    });

    testWidgets('Total persists correctly', (WidgetTester tester) async {
      // Set up initial saved food list and same-day marker.
      SharedPreferences.setMockInitialValues({
        'food_items':
            '[{"name":"Saved Item","carbs":42.5,"loggedAt":"2026-03-09T10:00:00.000","category":"snack"}]',
        'last_save_date': todayKey(),
      });

      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      // Wait for async load to complete
      await tester.pump(const Duration(milliseconds: 100));

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.totalCarbs, 42.5);
    });

    testWidgets('Full persistence cycle: add items, close, and reopen app',
        (WidgetTester tester) async {
      // Start with clean state
      SharedPreferences.setMockInitialValues({});

      // First app session - add items
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      // Add multiple items
      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Breakfast', carbs: 45.0));
        state.foodItems.add(FoodItem(name: 'Lunch', carbs: 60.0));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      // Manually trigger save (simulating what happens in the real app).
      final prefs = await SharedPreferences.getInstance();
      final foodItemsJson =
          '[{"name":"Breakfast","carbs":45.0,"loggedAt":"2026-03-09T08:00:00.000","category":"breakfast"},'
          '{"name":"Lunch","carbs":60.0,"loggedAt":"2026-03-09T12:00:00.000","category":"lunch"}]';
      await prefs.setString('food_items', foodItemsJson);
        await prefs.setString('last_save_date', todayKey());

      // Verify in-memory total before restart.
      expect(state.totalCarbs, 105.0);

      // Simulate closing the app by disposing the widget
      await tester.pumpWidget(Container());

      // Simulate reopening the app (new session)
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      // Wait for async load to complete
      await tester.pump(const Duration(milliseconds: 100));

      // Current app behavior: food items are persisted and reloaded.
      final restoredState = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      // Verify total was restored
      expect(restoredState.totalCarbs, 105.0);
      expect(restoredState.foodItems.length, 2);
      expect(restoredState.foodItems.any((item) => item.name == 'Breakfast'),
          isTrue);
      expect(
          restoredState.foodItems.any((item) => item.name == 'Lunch'), isTrue);
    });

    testWidgets('resume after the day changed starts a new day',
        (WidgetTester tester) async {
      // The new-day path writes the widget's App Group data.
      stubHomeWidget();

      // The app starts with today's items...
      SharedPreferences.setMockInitialValues({
        'food_items':
            '[{"name":"Saved Item","carbs":42.5,"loggedAt":"2026-03-09T10:00:00.000","category":"snack"}]',
        'last_save_date': todayKey(),
      });

      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.foodItems, isNotEmpty);

      // ...then stays suspended past the day boundary, so what it saved is
      // now yesterday's.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_save_date', yesterdayKey());

      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(state.foodItems, isEmpty);
    });

    testWidgets(
        'resume after the day changed, with iCloud sync, imports Siri items into the new day',
        (WidgetTester tester) async {
      final appGroup = stubHomeWidget();
      stubCloudSync();

      SharedPreferences.setMockInitialValues({
        'food_items':
            '[{"name":"Pasta","carbs":60.0,"loggedAt":"2026-03-09T19:00:00.000","category":"dinner"},'
                '{"name":"Apple","carbs":25.0,"loggedAt":"2026-03-09T10:00:00.000","category":"snack"}]',
        'last_save_date': todayKey(),
      });

      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.foodItems, hasLength(2));

      // Overnight the saved list becomes yesterday's, and Siri logs a food.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_save_date', yesterdayKey());
      appGroup['siriLoggedItems'] = jsonEncode([
        {
          'name': 'Toast',
          'carbs': 15,
          'loggedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      // Resume starts both the day reload and an iCloud pull, whose
      // _applyCloudData reloads again while the first reload is in flight.
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(state.foodItems.map((f) => f.name), ['Toast']);

      // Let the 2-second "synced" badge timer from the iCloud push finish.
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('Edge Cases', () {
    testWidgets('Adding zero carb item', (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Water', carbs: 0.0));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 0.0);
      expect(state.foodItems.any((item) => item.name == 'Water'), isTrue);
    });

    testWidgets('Large carb values', (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Large Meal', carbs: 150.5));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 150.5);
    });

    testWidgets('Remove all items returns to zero',
        (WidgetTester tester) async {
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      // Add items
      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
        state.showingDailyTotal = true;
      });
      await tester.pumpAndSettle();

      // Remove all items
      state.removeItem(1); // Remove Banana
      await tester.pumpAndSettle();
      state.removeItem(0); // Remove Apple
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 0.0);
      expect(state.foodItems, isEmpty);
    });
  });

  group('iCloud sync', () {
    /// Three items today, of which the cloud says two were deleted on the
    /// other device.
    void seedThreeItemsToday() {
      SharedPreferences.setMockInitialValues({
        'food_items': jsonEncode([
          {
            'id': 'a',
            'name': 'Apple',
            'carbs': 25.0,
            'loggedAt': '2026-03-09T10:00:00.000',
            'category': 'snack'
          },
          {
            'id': 'b',
            'name': 'Bagel',
            'carbs': 48.0,
            'loggedAt': '2026-03-09T09:00:00.000',
            'category': 'breakfast'
          },
          {
            'id': 'c',
            'name': 'Cereal',
            'carbs': 30.0,
            'loggedAt': '2026-03-09T08:00:00.000',
            'category': 'breakfast'
          },
        ]),
        'last_save_date': todayKey(),
      });
    }

    Map<String, Object?> cloudPayloadDeleting(List<String> ids) => {
          'food_items': jsonEncode([
            {
              'id': 'a',
              'name': 'Apple',
              'carbs': 25.0,
              'loggedAt': '2026-03-09T10:00:00.000',
              'category': 'snack'
            },
            {
              'id': 'b',
              'name': 'Bagel',
              'carbs': 48.0,
              'loggedAt': '2026-03-09T09:00:00.000',
              'category': 'breakfast'
            },
            {
              'id': 'c',
              'name': 'Cereal',
              'carbs': 30.0,
              'loggedAt': '2026-03-09T08:00:00.000',
              'category': 'breakfast'
            },
          ]),
          'food_items_deleted': jsonEncode(ids),
          'last_save_date': todayKey(),
          'cloud_last_modified': DateTime.now().toIso8601String(),
        };

    /// Answers pulls with [payload]; pushes report failure, which the app
    /// shows as a failed sync and is not what these tests are about.
    void stubCloudSyncReturning(Map<String, Object?>? payload) {
      const channel = MethodChannel('com.carpecarb/cloudsync');
      messenger().setMockMethodCallHandler(channel,
          (call) async => call.method == 'pullFromCloud' ? payload : false);
      addTearDown(() => messenger().setMockMethodCallHandler(channel, null));
    }

    /// Delivers a remote change the way the native observer does, so the app
    /// merges it while the list is on screen.
    Future<void> sendRemoteChange(
        WidgetTester tester, Map<String, Object?> payload) async {
      await messenger().handlePlatformMessage(
        'com.carpecarb/cloudsync',
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('onRemoteChange', payload)),
        (_) {},
      );
      // The service debounces remote changes by 300ms.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'a remote delete shortens the list on screen without a range error',
        (WidgetTester tester) async {
      stubHomeWidget();
      seedThreeItemsToday();
      // Nothing in the cloud at launch, so all three items render first —
      // which is what leaves the AnimatedList counting them.
      stubCloudSyncReturning(null);

      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.foodItems, hasLength(3));
      expect(find.text('Bagel'), findsOneWidget);

      await sendRemoteChange(tester, cloudPayloadDeleting(['b', 'c']));

      expect(state.foodItems.map((f) => f.name), ['Apple']);
      expect(find.text('Bagel'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a remote delete survives the next merge',
        (WidgetTester tester) async {
      stubHomeWidget();
      seedThreeItemsToday();
      stubCloudSyncReturning(cloudPayloadDeleting(['b', 'c']));

      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.foodItems, hasLength(1));

      // A second pull of the same payload — the deleted items are still gone
      // rather than merging back in.
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(state.foodItems.map((f) => f.name), ['Apple']);
      expect(tester.takeException(), isNull);
    });
  });
}
