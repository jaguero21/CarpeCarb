import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/models/food_source.dart';
import 'package:carb_tracker/widgets/source_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/contrast.dart';

void main() {
  for (final dark in [false, true]) {
    for (final source in FoodSource.values) {
      test('${source.label} tag text is readable in ${dark ? 'dark' : 'light'} mode', () {
        final colors = sourceTagColors(source, dark: dark);
        final card = dark ? AppColors.darkSurface : Colors.white;
        final background = Color.alphaBlend(colors.background, card);
        expect(contrastRatio(colors.text, background), greaterThanOrEqualTo(4.5));
      });
    }
  }

  testWidgets('the tag shows its label', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: SourceTag(FoodSource.usda)))));
    expect(find.text('USDA'), findsOneWidget);
  });
}
