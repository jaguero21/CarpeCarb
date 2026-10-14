import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/recent_foods.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Only for the write-order test below; the package is already a dependency
// of shared_preferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'helpers/home_harness.dart';

/// An in-memory store that remembers what was written, and in what order.
class _WriteLog extends InMemorySharedPreferencesStore {
  _WriteLog(Map<String, Object> data) : super.withData(data);

  final writes = <(String, Object)>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    writes.add((key, value));
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester, {String? siriItems}) async {
    stubHomeChannels(siriItems: siriItems);
    SharedPreferences.setMockInitialValues(todayPrefs(const []));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  Future<List<String>> recentNames() async =>
      [for (final f in await RecentFoods().load(DateTime.now())) f.name];

  testWidgets('a looked-up food is remembered', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Pho', carbs: 41.2)]));
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Pho']);
  });

  testWidgets('a saved food logged again is remembered', (tester) async {
    final state = await start(tester);
    state.addSavedFoodForTest(FoodItem(name: 'Oatmeal', carbs: 27));
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Oatmeal']);
  });

  testWidgets('a food Siri logged today is remembered', (tester) async {
    await start(tester,
        siriItems: jsonEncode([
          {'name': 'Bagel', 'carbs': 48.0, 'loggedAt': DateTime.now().toUtc().toIso8601String()},
        ]));
    expect(await recentNames(), ['Bagel']);
  });

  testWidgets('Siri foods are saved before recents are written', (tester) async {
    // A merge that lands between inserting the foods and saving them would
    // reload the list from storage and drop the unsaved foods.
    stubHomeChannels(
        siriItems: jsonEncode([
      {'name': 'Bagel', 'carbs': 48.0, 'loggedAt': DateTime.now().toUtc().toIso8601String()},
    ]));
    SharedPreferences.setMockInitialValues({}); // resets the cached instance
    final log = _WriteLog({
      for (final e in todayPrefs(const []).entries) 'flutter.${e.key}': e.value,
    });
    SharedPreferencesStorePlatform.instance = log;
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    final savedWithBagel = log.writes.indexWhere(
        (w) => w.$1 == 'flutter.food_items' && (w.$2 as String).contains('Bagel'));
    final recorded = log.writes.indexWhere((w) => w.$1 == 'flutter.recent_foods');
    expect(savedWithBagel, isNonNegative);
    expect(recorded, isNonNegative);
    expect(savedWithBagel, lessThan(recorded));
  });

  testWidgets('deleting a food forgets it; Reset does not', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(LookupResult(items: [
      FoodItem(name: 'Mystery stew', carbs: 80),
      FoodItem(name: 'Banana', carbs: 27),
    ]));
    await tester.pumpAndSettle();

    state.removeItemById(state.foodItems.firstWhere((f) => f.name == 'Mystery stew').id);
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Banana']);

    state.resetTotalForTest();
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Banana']);
  });

  testWidgets('deleting a saved food that was logged again keeps it', (tester) async {
    // Settings' saved-food list logs through the same path as a chip.
    final state = await start(tester);
    state.addSavedFoodForTest(FoodItem(name: 'Oatmeal', carbs: 27));
    await tester.pumpAndSettle();
    state.removeItemById(state.foodItems.single.id);
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Oatmeal']);
  });

  testWidgets('a deletion that is itself an undo keeps the recent food', (tester) async {
    final state = await start(tester);
    state.addSavedFoodForTest(FoodItem(name: 'Oatmeal', carbs: 27));
    await tester.pumpAndSettle();
    state.removeItemById(state.foodItems.single.id, showUndo: false, forgetRecent: false);
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Oatmeal']);
  });
}
