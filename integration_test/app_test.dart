// integration_test/app_test.dart
//
// Integration tests for CarpeCarb.
// Run on a connected device or simulator:
//   flutter test integration_test/app_test.dart
//
// Tests exercise the full widget tree. SharedPreferences is mocked;
// network calls are not made (no food-lookup tests that hit the AI).
//
// NOTE: pumpAndSettle() is intentionally avoided for initial app boot because
// _initCloudSync() opens a MethodChannel to iCloud which may not resolve on
// a simulator without a signed-in Apple ID. pump(Duration) is used instead to
// advance time by a fixed amount without waiting for all async work to drain.

// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/server_quota.dart';
import 'package:carb_tracker/services/premium_service.dart';
import 'package:carb_tracker/firebase_options.dart';
import 'package:carb_tracker/config/storage_keys.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ── One-time setup: init Firebase + HomeWidget before any test pumps the app.
  // These mirror what main() does before runApp(), which is bypassed in tests.
  setUpAll(() async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    HomeWidget.setAppGroupId(StorageKeys.appGroupId);
  });

  // ── helpers ──────────────────────────────────────────────────────────────

  String todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// Boots the app, letting initState async work (iCloud, HealthKit) fire and
  /// forget. Uses pump(Duration) rather than pumpAndSettle() to avoid blocking
  /// indefinitely on MethodChannel calls that may not complete on a simulator.
  Future<void> pumpApp(WidgetTester tester,
      {Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pump(); // first frame
    await tester.pump(const Duration(milliseconds: 500)); // async init settles
  }

  /// Same as pumpApp but with disclaimer already accepted so it is never shown.
  Future<void> pumpAppDisclaimerAccepted(WidgetTester tester,
      {Map<String, Object> extra = const {}}) async {
    await pumpApp(tester, prefs: {'disclaimer_accepted': true, ...extra});
  }

  // ── 1. Disclaimer ─────────────────────────────────────────────────────────

  group('Disclaimer', () {
    testWidgets('shows disclaimer on first launch', (tester) async {
      await pumpApp(tester);

      expect(find.text('Health Disclaimer'), findsOneWidget);
      expect(find.text('I Understand'), findsOneWidget);
    });

    testWidgets('dismisses disclaimer and shows home screen', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('I Understand'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Health Disclaimer'), findsNothing);
      expect(find.text('CarpeCarb'), findsOneWidget);
    });

    testWidgets('skips disclaimer when already accepted', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      expect(find.text('Health Disclaimer'), findsNothing);
      expect(find.text('CarpeCarb'), findsOneWidget);
    });
  });

  // ── 2. Home Screen UI ─────────────────────────────────────────────────────

  group('Home Screen', () {
    testWidgets('renders app title', (tester) async {
      await pumpAppDisclaimerAccepted(tester);
      expect(find.text('CarpeCarb'), findsOneWidget);
    });

    testWidgets('renders food input field', (tester) async {
      await pumpAppDisclaimerAccepted(tester);
      expect(find.byType(TextField), findsAtLeastNWidgets(1));
    });

    testWidgets('shows empty state when no food logged', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.foodItems, isEmpty);
      expect(state.totalCarbs, 0.0);
    });
  });

  // ── 3. Food Item Management ───────────────────────────────────────────────

  group('Food Item Management', () {
    testWidgets('adding a food item updates total', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.showingDailyTotal = true;
      });
      await tester.pump();

      expect(state.totalCarbs, 25.0);
    });

    testWidgets('adding multiple items accumulates total correctly',
        (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
        state.foodItems.add(FoodItem(name: 'Orange', carbs: 15.0));
        state.showingDailyTotal = true;
      });
      await tester.pump();

      expect(state.totalCarbs, 67.0);
      expect(state.foodItems.length, 3);
    });

    testWidgets('removing a food item updates total', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
        state.showingDailyTotal = true;
      });
      await tester.pump();

      expect(state.totalCarbs, 52.0);

      state.removeItem(0);
      await tester.pump();

      expect(state.totalCarbs, 27.0);
      expect(state.foodItems.any((i) => i.name == 'Apple'), isFalse);
    });

    testWidgets('reset clears all items and total', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
        state.showingDailyTotal = true;
      });
      await tester.pump();

      expect(state.totalCarbs, 52.0);

      state.resetTotalForTest();
      await tester.pump();

      expect(state.totalCarbs, 0.0);
      expect(state.foodItems, isEmpty);
    });

    testWidgets('food items persist across simulated app restart',
        (tester) async {
      final today = todayKey();
      await pumpApp(tester, prefs: {
        'disclaimer_accepted': true,
        'food_items':
            '[{"name":"Breakfast","carbs":45.0,"loggedAt":"${today}T08:00:00.000","category":"breakfast"}]',
        'last_save_date': today,
      });
      await tester.pump(const Duration(milliseconds: 200));

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      expect(state.totalCarbs, 45.0);
      expect(state.foodItems.any((i) => i.name == 'Breakfast'), isTrue);
    });

    testWidgets('food items reset when date changes (new day)', (tester) async {
      await pumpApp(tester, prefs: {
        'disclaimer_accepted': true,
        'food_items':
            '[{"name":"Yesterday","carbs":60.0,"loggedAt":"2020-01-01T12:00:00.000","category":"lunch"}]',
        'last_save_date': '2020-01-01',
      });
      await tester.pump(const Duration(milliseconds: 200));

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      expect(state.totalCarbs, 0.0);
      expect(state.foodItems, isEmpty);
    });
  });

  // ── 4. Daily Carb Goal ────────────────────────────────────────────────────

  group('Daily Carb Goal', () {
    testWidgets('loads saved daily carb goal', (tester) async {
      await pumpApp(tester, prefs: {
        'disclaimer_accepted': true,
        'daily_carb_goal': 100.0,
      });
      await tester.pump(const Duration(milliseconds: 200));

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      expect(state.dailyCarbGoal, 100.0);
    });

    testWidgets('goal is null when not set', (tester) async {
      await pumpAppDisclaimerAccepted(tester);
      await tester.pump(const Duration(milliseconds: 200));

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      expect(state.dailyCarbGoal, isNull);
    });
  });

  // ── 5. Daily Lookup Limit ─────────────────────────────────────────────────

  group('Daily Lookup Limit', () {
    test('free user starts at zero lookups', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = PremiumService();
      await svc.init();

      expect(svc.dailyLookupCount, 0);
      expect(svc.hasReachedDailyLimit, isFalse);
    });

    test('free user reaches limit at ${PremiumService.freeDailyLookupLimit}',
        () async {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      SharedPreferences.setMockInitialValues({
        'daily_lookup_count': PremiumService.freeDailyLookupLimit,
        'daily_lookup_date': today,
      });
      final svc = PremiumService();
      await svc.init();

      expect(svc.hasReachedDailyLimit, isTrue);
    });

    test('subscriber is never rate-limited', () async {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      SharedPreferences.setMockInitialValues({
        'is_premium': true,
        'premium_plan': 'monthly',
        'daily_lookup_count': 999,
        'daily_lookup_date': today,
      });
      final svc = PremiumService();
      await svc.init();

      expect(svc.hasReachedDailyLimit, isFalse);
    });

    test('count resets on a new day', () async {
      SharedPreferences.setMockInitialValues({
        'daily_lookup_count': 14,
        'daily_lookup_date': '2020-01-01',
      });
      final svc = PremiumService();
      await svc.init();

      expect(svc.dailyLookupCount, 0);
      expect(svc.hasReachedDailyLimit, isFalse);
    });

    test('applyServerQuota caches the server count', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = PremiumService();
      await svc.init();

      await svc.applyServerQuota(
          const ServerQuota(premium: false, used: 2, limit: 4));

      expect(svc.dailyLookupCount, 2);
    });
  });

  // ── 6. Premium Service ────────────────────────────────────────────────────

  group('Premium Service', () {
    test('all features enabled for free users', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = PremiumService();
      await svc.init();

      expect(svc.isManualEntryEnabled, isTrue);
      expect(svc.isHealthSyncEnabled, isTrue);
      expect(svc.isCloudSyncEnabled, isTrue);
      expect(svc.isMacrosEnabled, isTrue);
    });

    test('all features enabled for subscribers too', () async {
      SharedPreferences.setMockInitialValues({
        'is_premium': true,
        'premium_plan': 'yearly',
      });
      final svc = PremiumService();
      await svc.init();

      expect(svc.isPremium, isTrue);
      expect(svc.isManualEntryEnabled, isTrue);
      expect(svc.isHealthSyncEnabled, isTrue);
      expect(svc.isCloudSyncEnabled, isTrue);
      expect(svc.isMacrosEnabled, isTrue);
    });

    test('isPremium false by default', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = PremiumService();
      await svc.init();

      expect(svc.isPremium, isFalse);
      expect(svc.premiumPlan, isNull);
    });

    test('setPremiumEnabled persists plan', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = PremiumService();
      await svc.init();
      await svc.setPremiumEnabled(true, plan: PremiumService.monthlyPlan);

      expect(svc.isPremium, isTrue);
      expect(svc.premiumPlan, PremiumService.monthlyPlan);
    });

    test('setPremiumEnabled false clears plan', () async {
      SharedPreferences.setMockInitialValues({
        'is_premium': true,
        'premium_plan': 'monthly',
      });
      final svc = PremiumService();
      await svc.init();

      await svc.setPremiumEnabled(false);

      expect(svc.isPremium, isFalse);
      expect(svc.premiumPlan, isNull);
    });
  });

  // ── 7. Settings Navigation ────────────────────────────────────────────────

  group('Settings Navigation', () {
    testWidgets('navigates to settings and shows all tabs', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.switchToSettingsForTest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Tab text is only shown for the selected tab; all tabs always show icons.
      // Default selected tab is Favorites (index 0).
      expect(find.text('Favorites'), findsOneWidget);
      expect(find.byIcon(Icons.history), findsOneWidget);
      expect(find.byIcon(Icons.adjust), findsOneWidget);
      expect(find.byIcon(Icons.workspace_premium), findsAtLeastNWidgets(1));
    });

    testWidgets('Features tab shows free-plan lookup status', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.switchToSettingsForTest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Tap the Features tab by its icon (text only shows when selected)
      await tester.tap(find.byIcon(Icons.workspace_premium).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Free Plan'), findsOneWidget);
    });
  });

  // ── 8. Input Field ────────────────────────────────────────────────────────

  group('Food Input Field', () {
    testWidgets('accepts typed text', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final field = find.byType(TextField).first;
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'apple');
      await tester.pump();

      expect(find.text('apple'), findsOneWidget);
    });

    testWidgets('clears text correctly', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final field = find.byType(TextField).first;
      await tester.enterText(field, 'banana');
      await tester.pump();

      await tester.enterText(field, '');
      await tester.pump();

      expect(find.text('banana'), findsNothing);
    });
  });

  // ── 9. Edge Cases ─────────────────────────────────────────────────────────

  group('Edge Cases', () {
    testWidgets('zero-carb item does not change total', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Water', carbs: 0.0));
      });
      await tester.pump();

      expect(state.totalCarbs, 0.0);
    });

    testWidgets('large carb value is handled correctly', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Giant Cake', carbs: 9999.9));
      });
      await tester.pump();

      expect(state.totalCarbs, closeTo(9999.9, 0.001));
    });

    testWidgets('decimal values accumulate accurately', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'A', carbs: 12.5));
        state.foodItems.add(FoodItem(name: 'B', carbs: 8.3));
        state.foodItems.add(FoodItem(name: 'C', carbs: 5.7));
      });
      await tester.pump();

      expect(state.totalCarbs, closeTo(26.5, 0.001));
    });

    testWidgets('removing all items returns total to zero', (tester) async {
      await pumpAppDisclaimerAccepted(tester);

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );

      state.setState(() {
        state.foodItems.add(FoodItem(name: 'Apple', carbs: 25.0));
        state.foodItems.add(FoodItem(name: 'Banana', carbs: 27.0));
      });
      await tester.pump();

      state.removeItem(1);
      await tester.pump();
      state.removeItem(0);
      await tester.pump();

      expect(state.totalCarbs, 0.0);
      expect(state.foodItems, isEmpty);
    });
  });
}
