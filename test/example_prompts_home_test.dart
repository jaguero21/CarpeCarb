import 'dart:async';
import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/perplexity_firebase_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

class _CountingLookup extends PerplexityFirebaseService {
  int calls = 0;
  @override
  Future<LookupResult> getMultipleCarbCounts(String input) {
    calls++;
    return Completer<LookupResult>().future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CarbTrackerHomeState> start(WidgetTester tester,
      {List<FoodItem> saved = const []}) async {
    // The default 800x600 screen puts the examples under the bottom bar.
    tester.view.physicalSize = const Size(2400, 3600); // 800x1200 at 3x
    addTearDown(tester.view.reset);
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const [], extra: {
      'saved_foods': jsonEncode([for (final f in saved) f.toJson()]),
    }));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
  }

  testWidgets('a new user with an empty day sees the examples', (tester) async {
    await start(tester);
    expect(find.text('Try something like:'), findsOneWidget);
    expect(find.text('Type a food name above to look up its carbs.'), findsNothing);
  });

  testWidgets('someone with saved foods sees the usual empty line instead',
      (tester) async {
    await start(tester, saved: [FoodItem(name: 'Oatmeal', carbs: 27)]);
    expect(find.text('Try something like:'), findsNothing);
    expect(find.text('Type a food name above to look up its carbs.'), findsOneWidget);
  });

  testWidgets('an example fills the food field and looks nothing up', (tester) async {
    final state = await start(tester);
    final lookup = _CountingLookup();
    state.perplexityService = lookup;

    await tester.tap(find.text('Enter carbs yourself'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 cup cooked white rice'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'What did you eat?'));
    expect(field.controller!.text, '1 cup cooked white rice');
    expect(field.controller!.selection.baseOffset, '1 cup cooked white rice'.length);
    expect(find.text('Look it up instead'), findsNothing); // back in lookup mode
    expect(lookup.calls, 0);
  });
}
