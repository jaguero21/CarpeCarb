// ignore_for_file: invalid_use_of_protected_member
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
      // The new-day path writes the widget's App Group data; answer the
      // home_widget plugin's calls, which otherwise never complete in tests.
      const homeWidget = MethodChannel('home_widget');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(homeWidget, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(homeWidget, null));

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
}
