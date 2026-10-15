import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/quick_log.dart';
import 'package:carb_tracker/widgets/quick_log_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chip_finders.dart';

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
    expect(chipName('Banana'), findsOneWidget);
    expect(chipCarbs(27), findsOneWidget);
    expect(chipName('Pho'), findsOneWidget);
    expect(chipCarbs(41.2), findsOneWidget);
    await tester.tap(chipName('Pho'));
    expect(logged, [pho]);
  });

  testWidgets('long-pressing a recent chip offers Remove from recents', (tester) async {
    final (_, removed) = await pump(tester);
    await tester.longPress(chipName('Pho'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from recents'));
    await tester.pumpAndSettle();
    expect(removed, [pho]);
  });

  testWidgets('long-pressing a saved chip does nothing', (tester) async {
    await pump(tester);
    await tester.longPress(chipName('Banana'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from recents'), findsNothing);
  });

  Future<void> pumpOne(WidgetTester tester, FoodItem food,
      {double textScale = 1}) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: QuickLogChips(
            chips: [QuickLogChip(food, isRecent: true)],
            onLog: (_) {},
            onRemoveRecent: (_) {},
          ),
        ),
      ),
    ));
  }

  Rect chipRect(WidgetTester tester) =>
      tester.getRect(find.ancestor(of: chipCarbs(27), matching: find.byType(Material)).first);

  testWidgets('a long name is cut off, never the carbs', (tester) async {
    final name = 'abcdefghij' * 4; // 40 characters
    await pumpOne(tester, FoodItem(name: name, carbs: 27));
    final chip = chipRect(tester);
    final carbs = tester.getRect(chipCarbs(27));
    expect(carbs.left, greaterThanOrEqualTo(chip.left));
    expect(carbs.right, lessThanOrEqualTo(chip.right));
    expect(tester.renderObject<RenderParagraph>(chipCarbs(27)).didExceedMaxLines,
        isFalse);
    expect(tester.renderObject<RenderParagraph>(chipName(name)).didExceedMaxLines,
        isTrue);
    expect(chip.width, lessThanOrEqualTo(200));
  });

  testWidgets('at large text the chip grows with the text and still shows the carbs',
      (tester) async {
    final name = 'abcdefghij' * 4;
    await pumpOne(tester, FoodItem(name: name, carbs: 27), textScale: 2);
    final chip = chipRect(tester);
    final carbs = tester.getRect(chipCarbs(27));
    expect(chip.width, greaterThan(200));
    expect(chip.width, lessThanOrEqualTo(400));
    expect(carbs.right, lessThanOrEqualTo(chip.right));
    expect(tester.renderObject<RenderParagraph>(chipCarbs(27)).didExceedMaxLines,
        isFalse);
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
