import 'dart:async';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/perplexity_firebase_service.dart';
import 'package:carb_tracker/utils/user_facing_exception.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

/// A lookup that answers only when the test says so. Every call gets its own
/// answer, in the order the calls came in.
class _SlowLookup extends PerplexityFirebaseService {
  final answers = <Completer<LookupResult>>[];

  /// The first call's answer.
  Completer<LookupResult> get answer => answers.first;

  /// How many lookups have been started.
  int get calls => answers.length;

  @override
  Future<LookupResult> getMultipleCarbCounts(String input) {
    final completer = Completer<LookupResult>();
    answers.add(completer);
    return completer.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The home page's food field, not whichever TextField the tree lists first.
  final foodField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField &&
        widget.decoration?.hintText == 'What did you eat?',
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
    expect(find.text('Still checking — some foods take longer'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    expect(find.text('Still working on it…'), findsOneWidget);
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
    expect(find.text('Still checking — some foods take longer'), findsNothing);
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
            .byLabel('Still checking — some foods take longer')
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

  testWidgets('a second lookup is ignored while one is running', (tester) async {
    final lookup = await startLookup(tester);

    // Return in the food field reaches _addFood without the Add button, which
    // is the only thing that checks the lookup is still running.
    await tester.enterText(foodField, 'banana');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(lookup.calls, 1);

    lookup.answer.complete(LookupResult(items: [FoodItem(name: 'apple', carbs: 25)]));
    await tester.pumpAndSettle();
    expect(lookup.calls, 1);
    expect(homeState(tester).foodItems.map((item) => item.name), ['apple']);
  });

  testWidgets('a lookup that ends late does not stop the next lookup\'s ticker',
      (tester) async {
    final lookup = await startLookup(tester);

    // Hold the first lookup in its widget update, which runs after it has
    // already let go of the button, so the user can start another meanwhile.
    final widgetUpdate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), (call) async {
      if (call.method == 'saveWidgetData') await widgetUpdate.future;
      return true;
    });

    lookup.answer.complete(LookupResult(items: [FoodItem(name: 'apple', carbs: 25)]));
    await tester.pump();
    expect(find.text('Looking up…'), findsNothing);

    await tester.enterText(foodField, 'banana');
    await tester.tap(find.text('Add Food'));
    await tester.pump();
    expect(lookup.calls, 2);
    expect(homeState(tester).lookupTickerActive, isTrue);

    widgetUpdate.complete();
    await tester.pump();
    await tester.pump();
    expect(homeState(tester).lookupTickerActive, isTrue,
        reason: 'the first lookup finishing must not stop the second one\'s ticker');
    expect(find.text('Looking up…'), findsOneWidget);

    lookup.answers.last.complete(const LookupResult(items: []));
    await tester.pumpAndSettle();
    expect(homeState(tester).lookupTickerActive, isFalse);
  });
}
