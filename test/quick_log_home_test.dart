import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/recent_foods.dart';
import 'package:carb_tracker/widgets/food_item_card.dart';
import 'package:carb_tracker/widgets/quick_log_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/chip_finders.dart';
import 'helpers/home_harness.dart';

/// Stands in for HealthKit, which the real service only talks to on iOS.
class _Health extends HealthKitService {
  final calls = <String>[];

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.carbs}');
    return true;
  }

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    calls.add('delete ${item.carbs}');
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester,
      {List<FoodItem> saved = const [], List<FoodItem> recent = const []}) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const [], extra: {
      'saved_foods': jsonEncode([for (final f in saved) f.toJson()]),
    }));
    if (recent.isNotEmpty) await RecentFoods().record(recent, DateTime.now());
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  testWidgets('no saved or recent foods, no chip row', (tester) async {
    await start(tester);
    expect(find.byType(QuickLogChips), findsNothing);
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.quickChips, isEmpty);
  });

  testWidgets('a corrupt saved-foods list does not take the recent chips with it',
      (tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(
        todayPrefs(const [], extra: {'saved_foods': 'not json'}));
    await RecentFoods().record([FoodItem(name: 'Pho', carbs: 41.2)], DateTime.now());
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    expect(chipName('Pho'), findsOneWidget);
  });

  testWidgets('saved foods come before recent ones', (tester) async {
    await start(tester,
        saved: [FoodItem(name: 'Oatmeal', carbs: 27)],
        recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    expect(tester.getTopLeft(chipName('Oatmeal')).dx,
        lessThan(tester.getTopLeft(chipName('Pho')).dx));
  });

  testWidgets('a chip logs the food with Undo, and Undo keeps the chip', (tester) async {
    final state = await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.tap(chipName('Pho'));
    await tester.pumpAndSettle();
    expect(state.foodItems.single.name, 'Pho');
    expect(find.text('Logged Pho · 41.2 g'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(state.foodItems, isEmpty);
    expect(chipName('Pho'), findsOneWidget);
    // The Undo is not itself a delete to undo.
    expect(find.textContaining('removed'), findsNothing);
  });

  testWidgets('the chip Undo queues no "removed" snackbar of its own', (tester) async {
    final state = await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    state.healthKitService = _Health(); // the real one fails off-device and snacks
    await tester.tap(chipName('Pho'));
    await tester.pumpAndSettle();
    // Pressing a SnackBarAction also hides the current snackbar, which would
    // swallow a queued one, so call the action's handler directly.
    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    await tester.pumpAndSettle();
    expect(state.foodItems, isEmpty);
    expect(find.textContaining('removed'), findsNothing);
  });

  testWidgets('Undo takes the food back out of Health', (tester) async {
    final state = await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    final health = _Health();
    state.healthKitService = health;
    await tester.tap(chipName('Pho'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(health.calls, ['write 41.2', 'delete 41.2']);
  });

  testWidgets('chips show with the carbs field up', (tester) async {
    await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.tap(find.text('Enter carbs yourself'));
    await tester.pumpAndSettle();
    expect(find.text('Carbs (g)'), findsOneWidget); // the carbs field is showing
    expect(chipName('Pho'), findsOneWidget);
  });

  testWidgets('a chip tap announces the log for VoiceOver', (tester) async {
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
    await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.tap(chipName('Pho'));
    await tester.pump();
    expect(announcements, ['Logged Pho, 41.2 grams of carbs']);
  });

  testWidgets('a second tap on a chip within a second is ignored', (tester) async {
    final state = await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.tap(chipName('Pho'));
    await tester.tap(chipName('Pho'));
    await tester.pump();
    expect(state.foodItems, hasLength(1));

    await tester.pump(const Duration(seconds: 1));
    await tester.tap(chipName('Pho'));
    await tester.pump();
    expect(state.foodItems, hasLength(2));
  });

  testWidgets('tapping a different chip right away is not blocked', (tester) async {
    final state = await start(tester,
        saved: [FoodItem(name: 'Oatmeal', carbs: 27)],
        recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.tap(chipName('Oatmeal'));
    await tester.tap(chipName('Pho'));
    await tester.pump();
    expect(state.foodItems.map((f) => f.name), unorderedEquals(['Oatmeal', 'Pho']));
  });

  testWidgets('Remove from recents removes the chip', (tester) async {
    await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.longPress(chipName('Pho'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from recents'));
    await tester.pumpAndSettle();
    expect(chipName('Pho'), findsNothing);
  });

  testWidgets('a lookup adds a chip; deleting that food takes it away', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Mystery stew', carbs: 80)]));
    await tester.pumpAndSettle();
    expect(chipName('Mystery stew'), findsOneWidget);
    expect(chipCarbs(80), findsOneWidget);

    state.removeItemById(state.foodItems.single.id);
    await tester.pumpAndSettle();
    expect(chipName('Mystery stew'), findsNothing);
  });

  testWidgets('deleting a food that came from a chip keeps the chip', (tester) async {
    // The default 800x600 screen puts the new row under the bottom bar.
    tester.view.physicalSize = const Size(2400, 3600); // 800x1200 at 3x
    addTearDown(tester.view.reset);
    final state = await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    await tester.tap(chipName('Pho'));
    await tester.pumpAndSettle();
    expect(state.foodItems, hasLength(1));

    final phoRow = find.descendant(
        of: find.byType(FoodItemCard), matching: find.text('Pho'));
    await tester.drag(phoRow, const Offset(-600, 0)); // swipe left = delete
    await tester.pumpAndSettle();
    expect(state.foodItems, isEmpty);
    expect(chipName('Pho'), findsOneWidget);
  });

  testWidgets('a chip follows an edit of the food it made', (tester) async {
    final state = await start(tester);
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Pho', carbs: 13.7)]));
    await tester.pumpAndSettle();
    expect(chipCarbs(13.7), findsOneWidget);

    final logged = state.foodItems.single;
    state.updateFoodItemForTest(
        logged,
        FoodItem(
          id: logged.id,
          name: logged.name,
          carbs: 41.2,
          loggedAt: logged.loggedAt,
          category: logged.category,
          updatedAt: DateTime.now(),
        ));
    await tester.pumpAndSettle();
    expect(chipCarbs(41.2), findsOneWidget);
    expect(chipCarbs(13.7), findsNothing);
    expect(chipName('Pho'), findsOneWidget);
  });

  testWidgets('saving a food to the Food list moves its chip to the saved group',
      (tester) async {
    // The default 800x600 screen puts the new row under the bottom bar.
    tester.view.physicalSize = const Size(2400, 3600); // 800x1200 at 3x
    addTearDown(tester.view.reset);
    final state = await start(tester, recent: [FoodItem(name: 'Pho', carbs: 41.2)]);
    expect(state.quickChips.single.isRecent, isTrue);
    await state.applyLookupResultForTest(
        LookupResult(items: [FoodItem(name: 'Bagel', carbs: 48)]));
    await tester.pumpAndSettle();
    // The daily total card also shows the latest food's name, so scope to the row.
    final bagelRow = find.descendant(
        of: find.byType(FoodItemCard), matching: find.text('Bagel'));
    await tester.drag(bagelRow, const Offset(600, 0)); // swipe right = save
    await tester.pumpAndSettle();
    final bagel = state.quickChips.firstWhere((c) => c.food.name == 'Bagel');
    expect(bagel.isRecent, isFalse);
  });
}
