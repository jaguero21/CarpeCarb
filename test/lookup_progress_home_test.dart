import 'dart:async';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/perplexity_firebase_service.dart';
import 'package:carb_tracker/utils/user_facing_exception.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

/// A lookup that answers only when the test says so.
class _SlowLookup extends PerplexityFirebaseService {
  final answer = Completer<LookupResult>();

  @override
  Future<LookupResult> getMultipleCarbCounts(String input) => answer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The home page's food field, not whichever TextField the tree lists first.
  final foodField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField &&
        widget.decoration?.hintText == 'Enter food item...',
  );

  CarbTrackerHomeState homeState(WidgetTester tester) =>
      tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));

  Future<_SlowLookup> startLookup(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const []));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final lookup = _SlowLookup();
    homeState(tester).perplexityService = lookup;

    await tester.enterText(foodField, 'apple');
    await tester.tap(find.text('Add Food'));
    await tester.pump();
    return lookup;
  }

  testWidgets('the button and status line say what is happening, and change with time',
      (tester) async {
    final lookup = await startLookup(tester);
    expect(find.text('Looking up…'), findsOneWidget);
    expect(find.text('Checking nutrition sources…'), findsOneWidget);
    expect(homeState(tester).lookupTickerActive, isTrue);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Checking nutrition sources…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Still checking — some foods need a second source'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    expect(find.text('Almost there…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('Taking longer than usual…'), findsOneWidget);

    lookup.answer.complete(LookupResult(items: [FoodItem(name: 'apple', carbs: 25)]));
    await tester.pumpAndSettle();
    expect(find.text('Taking longer than usual…'), findsNothing);
    expect(find.text('Looking up…'), findsNothing);

    // The status line is gone once the lookup ends, so time passing can't show
    // the ticker is still running. Ask it directly.
    expect(homeState(tester).lookupTickerActive, isFalse);
  });

  testWidgets('a failed lookup clears the status line', (tester) async {
    final lookup = await startLookup(tester);
    await tester.pump(const Duration(seconds: 6));
    lookup.answer.completeError(UserFacingException('Server error. Try again later.'));
    await tester.pumpAndSettle();
    expect(find.text('Still checking — some foods need a second source'), findsNothing);
    expect(find.text('Looking up…'), findsNothing);
    expect(find.text('Server error. Try again later.'), findsOneWidget);
    expect(homeState(tester).lookupTickerActive, isFalse);
  });

  testWidgets('the button label stays inside the button at a large text size',
      (tester) async {
    // 200% text on a phone-width screen, where "Looking up…" is wider than the
    // room beside the spinner unless it can shrink.
    tester.view.physicalSize = const Size(430, 2000);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final lookup = await startLookup(tester);
    // The Today header already overflows at this size (the test font is wider
    // than the real one), which is a separate problem; this test is about the
    // button label, so it checks the label's own position instead of waiting
    // for a layout exception.
    tester.takeException();

    final label = tester.getRect(find.text('Looking up…'));
    final button = tester.getRect(find.ancestor(
      of: find.text('Looking up…'),
      matching: find.byType(ElevatedButton),
    ));
    expect(label.left, greaterThanOrEqualTo(button.left));
    expect(label.right, lessThanOrEqualTo(button.right));

    lookup.answer.complete(const LookupResult(items: []));
    await tester.pumpAndSettle();
  });

  testWidgets('the status line is a live region', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final lookup = await startLookup(tester);
      expect(
        find.semantics.byLabel('Checking nutrition sources…').evaluate().single,
        isSemantics(isLiveRegion: true),
      );

      // The next message arrives in the same live region.
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.semantics
            .byLabel('Still checking — some foods need a second source')
            .evaluate()
            .single,
        isSemantics(isLiveRegion: true),
      );
      lookup.answer.complete(const LookupResult(items: []));
      await tester.pumpAndSettle();
    } finally {
      handle.dispose();
    }
  });
}
