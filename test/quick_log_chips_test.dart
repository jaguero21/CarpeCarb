import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/quick_log.dart';
import 'package:carb_tracker/widgets/quick_log_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final banana = FoodItem(name: 'Banana', carbs: 27);
  final pho = FoodItem(name: 'Pho', carbs: 41.2);

  Future<(List<FoodItem>, List<FoodItem>)> pump(WidgetTester tester) async {
    final logged = <FoodItem>[];
    final removed = <FoodItem>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QuickLogChips(
          chips: [
            QuickLogChip(banana, isRecent: false),
            QuickLogChip(pho, isRecent: true),
          ],
          onLog: logged.add,
          onRemoveRecent: removed.add,
        ),
      ),
    ));
    return (logged, removed);
  }

  testWidgets('chips show name and carbs; a tap logs that food', (tester) async {
    final (logged, _) = await pump(tester);
    expect(find.text('Banana · 27.0 g'), findsOneWidget);
    expect(find.text('Pho · 41.2 g'), findsOneWidget);
    await tester.tap(find.text('Pho · 41.2 g'));
    expect(logged, [pho]);
  });

  testWidgets('long-pressing a recent chip offers Remove from recents', (tester) async {
    final (_, removed) = await pump(tester);
    await tester.longPress(find.text('Pho · 41.2 g'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from recents'));
    await tester.pumpAndSettle();
    expect(removed, [pho]);
  });

  testWidgets('long-pressing a saved chip does nothing', (tester) async {
    await pump(tester);
    await tester.longPress(find.text('Banana · 27.0 g'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from recents'), findsNothing);
  });

  testWidgets('VoiceOver: buttons with spoken labels, and a remove action on recents',
      (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final (logged, removed) = await pump(tester);
      expect(find.semantics.byLabel('Quick add'), findsOneWidget);
      expect(
        find.semantics.byLabel('Log Banana, 27 grams of carbs').evaluate().single,
        isSemantics(isButton: true, hasTapAction: true),
      );
      final phoFinder = find.semantics.byLabel('Log Pho, 41.2 grams of carbs');
      final phoNode = phoFinder.evaluate().single;
      expect(phoNode, isSemantics(isButton: true, hasTapAction: true));
      final action = phoNode.getSemanticsData().customSemanticsActionIds!.single;
      tester.semantics
          .performAction(phoFinder, SemanticsAction.customAction, args: action);
      await tester.pumpAndSettle();
      expect(removed, [pho]);
      expect(logged, isEmpty);
    } finally {
      handle.dispose();
    }
  });
}
