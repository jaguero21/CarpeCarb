import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/recent_foods.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

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

  testWidgets('a deletion that is itself an undo keeps the recent food', (tester) async {
    final state = await start(tester);
    state.addSavedFoodForTest(FoodItem(name: 'Oatmeal', carbs: 27));
    await tester.pumpAndSettle();
    state.removeItemById(state.foodItems.single.id, showUndo: false, forgetRecent: false);
    await tester.pumpAndSettle();
    expect(await recentNames(), ['Oatmeal']);
  });
}
