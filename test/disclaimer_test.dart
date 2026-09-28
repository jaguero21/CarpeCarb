import 'package:carb_tracker/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The screen every user must agree to before first use.
///
/// It carries two things that are requirements, not copy: the health
/// disclaimer, and the disclosure that food lookups go to a third-party AI.
/// App Review asks for explicit permission before personal data reaches a
/// third-party AI, and this dialog is where that permission is given — so
/// removing the sentence, or the agreement, is a review problem and should
/// fail here first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in const [
      'home_widget',
      'com.carpecarb/cloudsync',
      'com.carpecarb/siribuffer',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (call) async => null);
    }
  });

  testWidgets('first launch discloses the AI lookup and asks for agreement',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(find.text('Before You Start'), findsOneWidget);
    expect(find.textContaining('Perplexity, a third-party AI service'),
        findsOneWidget);
    expect(find.textContaining('never your name, your contact details, or '
        'your Apple Health data'), findsOneWidget);
    expect(find.textContaining('not medical advice'), findsOneWidget);

    await tester.tap(find.text('I Agree'));
    await tester.pumpAndSettle();

    expect(find.text('Before You Start'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('disclaimer_accepted'), isTrue);
  });

  testWidgets('once agreed, it is not shown again', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'disclaimer_accepted': true,
    });

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(find.text('Before You Start'), findsNothing);
  });

  testWidgets('can be agreed to on a small phone at large text sizes',
      (tester) async {
    // Nobody can use the app without agreeing here, so at the text sizes
    // people who need them actually use, the button has to stay reachable.
    // Before the dialog scrolled and its title wrapped, the title overflowed
    // by several hundred pixels at 2x.
    //
    // The home screen behind the dialog has its own large-text overflows
    // (the header and the Add button), which predate this test and are
    // tracked separately; they are tolerated here so this test is about the
    // gate alone.
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.toString().contains('overflowed')) previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    tester.view.physicalSize = const Size(375 * 3, 667 * 3); // iPhone SE
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    // Measured, not inferred from the absence of an error: the overflow
    // filter above would also swallow an overflow in the dialog's own title,
    // so check that the title really fits inside the dialog.
    final dialog = tester.getRect(find.byType(AlertDialog));
    final title = tester.getRect(find.text('Before You Start'));
    expect(title.right, lessThanOrEqualTo(dialog.right),
        reason: 'the title runs past the edge of the dialog');

    await tester.ensureVisible(find.text('I Agree'));
    await tester.tap(find.text('I Agree'));
    await tester.pumpAndSettle();

    expect(find.text('Before You Start'), findsNothing);
  });
}
