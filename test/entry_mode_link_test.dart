import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/widgets/entry_mode_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/contrast.dart';

void main() {
  test('the link is readable on the input card in both modes', () {
    expect(contrastRatio(entryLinkColor(dark: false), Colors.white),
        greaterThanOrEqualTo(4.5));
    expect(contrastRatio(entryLinkColor(dark: true), AppColors.darkSurface),
        greaterThanOrEqualTo(4.5));
  });

  testWidgets('the link names what it does and is a 44 pt button', (tester) async {
    var taps = 0;
    Future<void> pump(bool manual) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EntryModeLink(manual: manual, onPressed: () => taps++))));

    await pump(false);
    expect(find.text('Enter carbs yourself'), findsOneWidget);
    expect(tester.getSize(find.byType(TextButton)).height, greaterThanOrEqualTo(44));
    await tester.tap(find.text('Enter carbs yourself'));
    expect(taps, 1);

    await pump(true);
    expect(find.text('Look it up instead'), findsOneWidget);
  });
}
