import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/meal_sections.dart';
import 'package:carb_tracker/widgets/meal_section_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final section = MealSection(
    category: FoodCategory.breakfast,
    items: [FoodItem(name: 'Toast', carbs: 14.5, category: FoodCategory.breakfast)],
  );

  Future<void> pump(WidgetTester tester, {double width = 360, double textScale = 1}) {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: MealSectionHeader(section: section)),
      ),
    ));
  }

  testWidgets('the meal name gets all the free space, not half of it', (tester) async {
    // Room for the name and the total, but not for the name if it only got
    // half of what is left after the total.
    await pump(tester, width: 300);
    final name = tester.renderObject<RenderParagraph>(find.text('Breakfast'));
    expect(tester.getSize(find.text('Breakfast')).width,
        greaterThanOrEqualTo(name.getMaxIntrinsicWidth(double.infinity)));
    expect(name.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('at large text the name is cut off and the total stays in view',
      (tester) async {
    await pump(tester, width: 400, textScale: 3);
    expect(tester.renderObject<RenderParagraph>(find.text('Breakfast')).didExceedMaxLines,
        isTrue);
    expect(find.text('14.5 g'), findsOneWidget);
    expect(tester.getRect(find.text('14.5 g')).right, lessThanOrEqualTo(400 - 16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the total lines up with the carbs of the rows below', (tester) async {
    await pump(tester);
    // Rows are cards padded 16 pt, so their carbs end 16 pt in from the edge.
    expect(tester.getRect(find.text('14.5 g')).right, 360 - 16);
  });
}
