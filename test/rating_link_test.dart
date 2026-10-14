import 'package:carb_tracker/screens/settings_page.dart';
import 'package:carb_tracker/services/rating_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => RatingPrompt.launcher = RatingPrompt.defaultLauncher);

  Future<void> showFooter(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SettingsPage(initialTab: 3))));
    await tester.pumpAndSettle();
    // The last link: the list builds lazily, so this brings both into being.
    await tester.scrollUntilVisible(find.text('Learn more at carpecarb.app'), 200,
        scrollable: find.byType(Scrollable).last);
  }

  testWidgets('Rate CarpeCarb opens the App Store review page', (tester) async {
    final opened = <Uri>[];
    RatingPrompt.launcher = (url) async {
      opened.add(url);
      return true;
    };

    // Disposed in a finally: the end-of-test check for open semantics handles
    // runs before addTearDown callbacks, so a tear-down would be too late.
    final handle = tester.ensureSemantics();
    try {
      await showFooter(tester);
      expect(
          find.semantics.byLabel('Rate CarpeCarb on the App Store').evaluate().single,
          isSemantics(isButton: true, hasTapAction: true));

      await tester.tap(find.text('Rate CarpeCarb'));
      await tester.pumpAndSettle();
      expect(opened.map((u) => u.toString()),
          ['https://apps.apple.com/app/id6759311106?action=write-review']);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('the footer links are at least 44 pt tall', (tester) async {
    await showFooter(tester);
    for (final label in const ['Rate CarpeCarb', 'Learn more at carpecarb.app']) {
      expect(tester.getSize(find.widgetWithText(TextButton, label)).height,
          greaterThanOrEqualTo(44),
          reason: '$label is too short to tap comfortably');
    }
  });
}
