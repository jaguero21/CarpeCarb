import 'package:carb_tracker/screens/settings_page.dart';
import 'package:carb_tracker/services/rating_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => RatingPrompt.launcher = RatingPrompt.defaultLauncher);

  testWidgets('Rate CarpeCarb opens the App Store review page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final opened = <Uri>[];
    RatingPrompt.launcher = (url) async {
      opened.add(url);
      return true;
    };

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SettingsPage(initialTab: 3))));
    await tester.pumpAndSettle();

    final link = find.text('Rate CarpeCarb');
    await tester.scrollUntilVisible(link, 200,
        scrollable: find.byType(Scrollable).last);
    expect(
        find.semantics.byLabel('Rate CarpeCarb on the App Store').evaluate().single,
        isSemantics(isButton: true));

    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(opened.map((u) => u.toString()),
        ['https://apps.apple.com/app/id6759311106?action=write-review']);
    handle.dispose();
  });
}
