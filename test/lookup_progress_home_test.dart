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

  Future<_SlowLookup> startLookup(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const []));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final lookup = _SlowLookup();
    state.perplexityService = lookup;

    await tester.enterText(find.byType(TextField).first, 'apple');
    await tester.tap(find.text('Add Food'));
    await tester.pump();
    return lookup;
  }

  testWidgets('the button and status line say what is happening, and change with time',
      (tester) async {
    final lookup = await startLookup(tester);
    expect(find.text('Looking up…'), findsOneWidget);
    expect(find.text('Checking nutrition sources…'), findsOneWidget);

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

    // The ticker stopped: time passing changes nothing.
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Checking nutrition sources…'), findsNothing);
  });

  testWidgets('a failed lookup clears the status line', (tester) async {
    final lookup = await startLookup(tester);
    await tester.pump(const Duration(seconds: 6));
    lookup.answer.completeError(UserFacingException('Server error. Try again later.'));
    await tester.pumpAndSettle();
    expect(find.text('Still checking — some foods need a second source'), findsNothing);
    expect(find.text('Looking up…'), findsNothing);
    expect(find.text('Server error. Try again later.'), findsOneWidget);
  });

  testWidgets('VoiceOver hears each new status', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final lookup = await startLookup(tester);
      expect(
        find.semantics.byLabel('Checking nutrition sources…').evaluate().single,
        isSemantics(isLiveRegion: true),
      );
      lookup.answer.complete(const LookupResult(items: []));
      await tester.pumpAndSettle();
    } finally {
      handle.dispose();
    }
  });
}
