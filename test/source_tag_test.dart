import 'dart:math' as math;

import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/models/food_source.dart';
import 'package:carb_tracker/widgets/source_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final dark in [false, true]) {
    for (final source in FoodSource.values) {
      test('${source.label} tag text is readable in ${dark ? 'dark' : 'light'} mode', () {
        final colors = sourceTagColors(source, dark: dark);
        final card = dark ? AppColors.darkSurface : Colors.white;
        final background = Color.alphaBlend(colors.background, card);
        expect(_contrast(colors.text, background), greaterThanOrEqualTo(4.5));
      });
    }
  }

  testWidgets('the tag shows its label', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: SourceTag(FoodSource.usda)))));
    expect(find.text('USDA'), findsOneWidget);
  });
}
