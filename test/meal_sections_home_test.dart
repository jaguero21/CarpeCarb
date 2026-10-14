import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/widgets/food_item_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> food(String id, String name, double carbs, String meal,
          int minutesAgo) =>
      {
        'id': id,
        'name': name,
        'carbs': carbs,
        'category': meal,
        'loggedAt':
            DateTime.now().subtract(Duration(minutes: minutesAgo)).toIso8601String(),
      };

  Future<CarbTrackerHomeState> start(
      WidgetTester tester, List<Map<String, Object?>> foods) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(foods));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  final day = [
    food('b1', 'Toast', 14.5, 'breakfast', 300),
    food('l1', 'Soup', 20.0, 'lunch', 60),
    food('l2', 'Roll', 32.0, 'lunch', 50),
  ];

  testWidgets('foods are grouped under meal headers with totals, newest meal first',
      (tester) async {
    await start(tester, day);
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('Breakfast'), findsOneWidget);
    expect(find.text('52.0 g'), findsOneWidget);
    expect(find.text('14.5 g'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Lunch')).dy,
        lessThan(tester.getTopLeft(find.text('Breakfast')).dy));
    // Newest first inside a meal.
    expect(tester.getTopLeft(find.text('Roll')).dy,
        lessThan(tester.getTopLeft(find.text('Soup')).dy));
  });

  testWidgets('deleting a food updates its meal; the last one removes the meal',
      (tester) async {
    final state = await start(tester, day);
    state.removeItemById('l2');
    await tester.pumpAndSettle();
    expect(find.text('20.0 g'), findsOneWidget);

    state.removeItemById('b1');
    await tester.pumpAndSettle();
    expect(find.text('Breakfast'), findsNothing);
  });

  testWidgets('Undo puts the food back in its meal', (tester) async {
    final state = await start(tester, day);
    state.removeItemById('l1');
    await tester.pumpAndSettle();
    expect(find.text('32.0 g'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('52.0 g'), findsOneWidget);
    expect(state.foodItems.any((f) => f.id == 'l1'), isTrue);
  });

  testWidgets('swiping a row left deletes that food', (tester) async {
    final state = await start(tester, day);
    // The default 800x600 test screen cuts the list off below the fold.
    await tester.ensureVisible(find.text('Soup'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Soup'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(state.foodItems.any((f) => f.id == 'l1'), isFalse);
    expect(find.text('32.0 g'), findsOneWidget);
  });

  testWidgets('a meal header is a heading VoiceOver reads as a sentence',
      (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester, day);
      expect(
        find.semantics.byLabel('Lunch, 52 grams of carbs, 2 foods').evaluate().single,
        isSemantics(isHeader: true),
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('a food logged again appears as a new row', (tester) async {
    final state = await start(tester, day);
    state.addSavedFoodForTest(
        state.foodItems.firstWhere((f) => f.id == 'l1'));
    await tester.pumpAndSettle();
    // Logged now, so its meal comes from the current time; the total for
    // that meal includes it. Count Soup rows instead of guessing the meal.
    // (The daily total card also names the latest food, so look at rows only.)
    expect(
      find.descendant(
          of: find.byType(FoodItemCard), matching: find.text('Soup')),
      findsNWidgets(2),
    );
  });
}
