import 'package:carb_tracker/models/food_source.dart';
import 'package:carb_tracker/widgets/food_item_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The height glyphs of [needle] really paint at inside the first paragraph
  /// under [text]: the glyph box height times the scale its ancestors apply.
  /// (`.first` is the outer paragraph; the subtitle's also contains the pill's.
  /// A WidgetSpan child is scaled by the text scaler through a transform, which
  /// is not part of the child's own size.)
  double paintedGlyphHeight(WidgetTester tester, Finder text, String needle) {
    final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)).first);
    final start = paragraph.text.toPlainText().indexOf(needle);
    final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + needle.length));
    expect(boxes, isNotEmpty);
    return boxes.first.toRect().height *
        paragraph.getTransformTo(null).getMaxScaleOnAxis();
  }

  // The pill is 10 pt next to 12 pt text, so at any text scale it should be
  // 10/12 of the subtitle. Scaled twice, it would outgrow the subtitle.
  for (final scale in [1.0, 2.0]) {
    testWidgets('the source tag stays in proportion to the subtitle at ${scale}x text',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const Scaffold(
            body: FoodItemCard(
              name: 'Pho',
              subtitle: '12:05 PM',
              carbs: 41.2,
              source: FoodSource.usda,
            ),
          ),
        ),
      ));

      final pill = paintedGlyphHeight(tester, find.text('USDA'), 'USDA');
      final subtitle =
          paintedGlyphHeight(tester, find.textContaining('12:05 PM'), '12:05 PM');

      expect(pill, lessThanOrEqualTo(subtitle));
      expect(pill / subtitle, closeTo(10 / 12, 0.02));
    });
  }
}
