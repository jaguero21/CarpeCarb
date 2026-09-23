import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A guardrail for the one guideline the app actually meets.
///
/// Two others are deliberately not asserted, because the app fails them today
/// and fixing either changes how it looks, which this batch does not:
///  - text contrast, on the disclaimer dialog's body text;
///  - tap target size, on the Auto/Manual toggle, whose pills are 37pt high
///    against a 44pt minimum. Giving them button semantics is what made the
///    guideline notice them; the two header icons were also below the minimum
///    and are fixed, since their hit area could grow without moving anything
///    on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
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
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'disclaimer_accepted': true,
      'daily_carb_goal': 100.0,
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
  });

  tearDown(() {
    messenger()
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), null);
  });

  testWidgets('every tappable thing has a label', (WidgetTester tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

    handle.dispose();
  });
}
