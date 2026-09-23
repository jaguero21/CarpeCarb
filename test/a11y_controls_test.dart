import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void stubChannels() {
    final appGroup = <String, Object?>{};
    messenger().setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      final args = (call.arguments as Map?) ?? const {};
      if (call.method == 'saveWidgetData') {
        appGroup[args['id'] as String] = args['data'];
        return true;
      }
      if (call.method == 'getWidgetData') return appGroup[args['id'] as String];
      return null;
    });
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
    addTearDown(() {
      messenger()
          .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
      messenger().setMockMethodCallHandler(
          const MethodChannel('com.carpecarb/cloudsync'), null);
    });
  }

  setUp(() {
    // Otherwise the disclaimer dialog covers the screen and nothing below it
    // is in the accessibility tree.
    SharedPreferences.setMockInitialValues({'disclaimer_accepted': true});
  });

  testWidgets('the entry-mode toggle says which mode is selected',
      (WidgetTester tester) async {
    stubChannels();
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(
      find.semantics.byLabel('Auto').evaluate().single,
      isSemantics(
        isButton: true,
        isSelected: true,
        isInMutuallyExclusiveGroup: true,
      ),
    );
    expect(
      find.semantics.byLabel('Manual').evaluate().single,
      isSemantics(isButton: true, isSelected: false),
    );

    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();

    // The selection has to move, or VoiceOver keeps announcing the old mode.
    expect(find.semantics.byLabel('Manual').evaluate().single,
        isSemantics(isSelected: true));
    expect(find.semantics.byLabel('Auto').evaluate().single,
        isSemantics(isSelected: false));

    handle.dispose();
  });

  testWidgets('Reset announces as a button', (WidgetTester tester) async {
    stubChannels();
    // Reset only appears once something has been logged.
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'disclaimer_accepted': true,
      'food_items': jsonEncode([
        {
          'id': 'a',
          'name': 'Apple',
          'carbs': 25.0,
          'loggedAt': '2026-09-22T08:30:00.000',
          'category': 'snack'
        },
      ]),
      'last_save_date': '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}',
    });
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    expect(find.semantics.byLabel('Reset').evaluate().single,
        isSemantics(isButton: true));

    handle.dispose();
  });

  testWidgets('Clear All in Settings announces as a button',
      (WidgetTester tester) async {
    stubChannels();
    // Clear All only appears once a food has been saved.
    SharedPreferences.setMockInitialValues({
      'disclaimer_accepted': true,
      'saved_foods': jsonEncode([
        {
          'id': 'f1',
          'name': 'Bagel',
          'carbs': 48.0,
          'loggedAt': '2026-09-22T08:00:00.000',
          'category': 'breakfast'
        },
      ]),
    });
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    tester
        .state<CarbTrackerHomeState>(find.byType(CarbTrackerHome))
        .switchToSettingsForTest();
    await tester.pumpAndSettle();

    expect(find.semantics.byLabel('Clear All').evaluate().single,
        isSemantics(isButton: true));

    handle.dispose();
  });

  testWidgets('the two nav icons have a real label, not just a tooltip',
      (WidgetTester tester) async {
    // They passed `labeledTapTargetGuideline` on the tooltip alone, which
    // the guideline accepts in place of a label. The iOS engine does fold a
    // tooltip into the label, so it spoke — but nothing held it there.
    stubChannels();
    SharedPreferences.setMockInitialValues({'disclaimer_accepted': true});
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    for (final name in const ['Home', 'Settings']) {
      final data =
          find.semantics.byLabel(name).evaluate().single.getSemanticsData();
      expect(data.label, name);
      // And only once: a label beside the tooltip would say it twice.
      expect(data.tooltip, isEmpty);
    }

    handle.dispose();
  });
}
