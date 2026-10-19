// integration_test/store_screenshots_test.dart
//
// Drives the app through the App Store screenshot screens with a seeded sample
// day, pausing at each one so a host script can capture the simulator with
// `xcrun simctl io <device> screenshot`. Not part of the regular test run.
//
// Run on a booted simulator:
//   flutter test integration_test/store_screenshots_test.dart -d <udid>
// At each screen the test prints `SHOT_READY:<name>` and waits for the file
// `<systemTemp>/shot_<name>.go` (it prints `SHOT_TMP:<path>` first), which the
// host creates after taking the capture.

import 'dart:convert';
import 'dart:io';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/serving_info.dart';
import 'package:carb_tracker/services/recent_foods.dart';
import 'package:carb_tracker/utils/day_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DateTime _today(int hour, int minute) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

List<FoodItem> _sampleDay() {
  final bowlServing = ServingInfo.usda(
    fdcId: 2709842,
    portions: const [
      ServingPortion(id: 'p1', label: '1 bowl', grams: 368),
      ServingPortion(id: 'p2', label: '1 cup', grams: 245),
      ServingPortion(id: '100g', label: '100 g', grams: 100),
    ],
    per100g: const Nutrients(
        carbs: 14.1, protein: 9.2, fat: 4.9, fiber: 2.4, calories: 140),
    portionId: 'p1',
    count: 1,
  );
  final bowl = bowlServing.nutrients();
  final yogurt =
      const Nutrients(carbs: 24, protein: 17, fat: 4, fiber: 2, calories: 196);
  return [
    FoodItem(
      name: 'Chicken burrito bowl',
      carbs: bowl.carbs,
      protein: bowl.protein,
      fat: bowl.fat,
      fiber: bowl.fiber,
      calories: bowl.calories,
      details: 'USDA FoodData Central (Survey (FNDDS)): Burrito bowl, chicken, '
          '1 bowl (368 g).',
      serving: bowlServing,
      loggedAt: _today(18, 40),
      category: FoodCategory.dinner,
    ),
    FoodItem(
      name: 'Banana',
      carbs: 27,
      protein: 1.3,
      fat: 0.4,
      fiber: 3.1,
      calories: 105,
      details: 'USDA FoodData Central (Survey (FNDDS)): Banana, raw, '
          '1 medium (118 g).',
      loggedAt: _today(15, 30),
      category: FoodCategory.snack,
    ),
    FoodItem(
      name: 'Turkey sandwich on wheat',
      carbs: 38,
      protein: 24,
      fat: 9,
      fiber: 5,
      calories: 330,
      details: 'USDA FoodData Central (Survey (FNDDS)): Turkey sandwich on '
          'whole wheat bread, 1 sandwich (182 g).',
      loggedAt: _today(12, 20),
      category: FoodCategory.lunch,
    ),
    FoodItem(
      name: 'Oat milk latte',
      carbs: 14,
      isManualEntry: true,
      loggedAt: _today(8, 10),
      category: FoodCategory.breakfast,
    ),
    FoodItem(
      name: 'Greek yogurt with berries',
      carbs: yogurt.carbs,
      protein: yogurt.protein,
      fat: yogurt.fat,
      fiber: yogurt.fiber,
      calories: yogurt.calories,
      details: 'Web source, not USDA. One 170 g cup of plain Greek yogurt with '
          'half a cup of mixed berries.',
      serving: ServingInfo.web(base: yogurt),
      loggedAt: _today(7, 45),
      category: FoodCategory.breakfast,
    ),
  ];
}

/// Each with a fixed meal, so its icon doesn't depend on the hour of capture.
List<FoodItem> _savedFoods() => [
      FoodItem(
          name: 'Banana',
          carbs: 27,
          details: 'USDA FoodData Central (Survey (FNDDS)): Banana, raw, '
              '1 medium (118 g).',
          category: FoodCategory.snack),
      FoodItem(
          name: 'Oatmeal',
          carbs: 27,
          details: 'USDA FoodData Central (Survey (FNDDS)): Oatmeal, cooked, '
              '1 cup (234 g).',
          category: FoodCategory.breakfast),
      FoodItem(
          name: 'Greek yogurt with berries',
          carbs: 24,
          details: 'Web source, not USDA. One 170 g cup with half a cup of '
              'mixed berries.',
          category: FoodCategory.breakfast),
      FoodItem(
          name: 'Apple',
          carbs: 25,
          details: 'USDA FoodData Central (Survey (FNDDS)): Apple, raw, '
              '1 medium (182 g).',
          category: FoodCategory.snack),
      FoodItem(
          name: 'Brown rice',
          carbs: 45,
          details: 'USDA FoodData Central (Survey (FNDDS)): Rice, brown, '
              'cooked, 1 cup (195 g).',
          category: FoodCategory.dinner),
      FoodItem(
          name: 'Whole wheat toast',
          carbs: 24,
          details: 'USDA FoodData Central (Survey (FNDDS)): Bread, whole '
              'wheat, toasted, 2 slices (56 g).',
          category: FoodCategory.breakfast),
      FoodItem(
          name: 'Orange juice',
          carbs: 26,
          details: 'USDA FoodData Central (Survey (FNDDS)): Orange juice, '
              '1 cup (249 g).',
          category: FoodCategory.drink),
    ];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App Store screenshots', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Apple Health: report access already granted, so no permission sheet
    // covers the screen; History isn't captured.
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_health'),
        (call) async {
      switch (call.method) {
        case 'getData':
        case 'getHealthDataByUUID':
          return <Object?>[];
        default:
          return true;
      }
    });
    // iCloud: off, so nothing waits on a signed-out simulator.
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/siribuffer'), (call) async => null);
    // Home Screen widget: writes succeed; nothing launched the app from it.
    messenger.setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      final m = call.method;
      return m.startsWith('save') ||
              m.startsWith('update') ||
              m.startsWith('set')
          ? true
          : null;
    });

    final day = _sampleDay();
    SharedPreferences.setMockInitialValues({
      'food_items': jsonEncode([for (final f in day) f.toJson()]),
      'last_save_date': dayKey(DateTime.now(), 0),
      'disclaimer_accepted': true,
      'daily_carb_goal': 180.0,
      'protein_goal': 100.0,
      'fat_goal': 60.0,
      'fiber_goal': 30.0,
      'calories_goal': 1800.0,
      'is_premium': true,
      'premium_plan': 'yearly',
      'saved_foods': jsonEncode([for (final f in _savedFoods()) f.toJson()]),
    });
    await RecentFoods().record(day.reversed, DateTime.now());

    final tmp = Directory.systemTemp.path;
    // ignore: avoid_print
    print('SHOT_TMP:$tmp');

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 800));
      // ignore: avoid_print
      print('SHOT_READY:$name');
      final go = File('$tmp/shot_$name.go');
      while (!go.existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pump(const Duration(seconds: 3));
    // The app focuses the food field on launch; the keyboard would cover the
    // screen.
    FocusManager.instance.primaryFocus?.unfocus();
    // The top card shows today's total, as in the 1.0.3 screenshots, not the
    // latest food.
    final home =
        tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    // ignore: invalid_use_of_protected_member
    home.setState(() => home.showingDailyTotal = true);
    await tester.pump(const Duration(seconds: 1));

    await shot('1_home');

    final vertical = find
        .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down)
        .first;
    final todayY = tester.getTopLeft(find.text('TODAY')).dy;
    if (todayY > 200) {
      await tester.drag(vertical, Offset(0, -(todayY - 140)));
      await tester.pump(const Duration(seconds: 1));
    }
    await shot('2_today');

    await tester.drag(vertical, const Offset(0, 3000));
    await tester.pump(const Duration(seconds: 1));
    final handle = tester.ensureSemantics();
    tester.semantics.performAction(
        find.semantics.byLabel(RegExp(r'^Chicken burrito bowl,')),
        SemanticsAction.tap);
    await tester.pump(const Duration(seconds: 1));
    // Two steps of half a serving: 1 bowl becomes 2.
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('More servings'));
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(seconds: 1));
    handle.dispose();
    await shot('3_details');

    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(seconds: 1));
    home.switchToSettingsForTest();
    await tester.pump(const Duration(seconds: 2));
    await shot('4_saved');

    await tester.tap(find.text('Goals'));
    await tester.pump(const Duration(seconds: 1));
    await shot('5_goals');

    await tester.tap(find.text('Features'));
    await tester.pump(const Duration(seconds: 1));
    // Scroll to the free features, Apple Health and iCloud among them: the
    // subscription card at the top shows a price, which store and social
    // images leave out.
    final basic = find.text('BASIC FEATURES');
    await tester.drag(
        find.ancestor(of: basic, matching: find.byType(Scrollable)).first,
        const Offset(0, -1000));
    await tester.pump(const Duration(seconds: 2));
    await shot('6_features');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
