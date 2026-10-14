import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/rating_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records asks instead of calling StoreKit.
class _RecordingPrompt extends RatingPrompt {
  int requests = 0;

  @override
  Future<void> requestReview() async => requests++;
}

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
    // Logging or deleting saves and pushes; an unstubbed channel never answers.
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
    messenger().setMockMethodCallHandler(
        const MethodChannel('com.carpecarb/siribuffer'), (call) async => null);
    addTearDown(() {
      for (final name in const [
        'home_widget',
        'com.carpecarb/cloudsync',
        'com.carpecarb/siribuffer',
        'flutter_health',
      ]) {
        messenger().setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
  }

  FoodItem apple() => FoodItem(name: 'apple', carbs: 25, loggedAt: DateTime.now());

  Future<(CarbTrackerHomeState, _RecordingPrompt)> start(WidgetTester tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues({'disclaimer_accepted': true});
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final prompt = _RecordingPrompt();
    state.ratingPrompt = prompt;
    return (state, prompt);
  }

  /// Applies a lookup result and lets the count be saved, so the ask's delay
  /// timer is running when this returns.
  Future<void> startLookup(WidgetTester tester, CarbTrackerHomeState state,
      LookupResult result) async {
    await state.applyLookupResultForTest(result);
    await tester.pump();
  }

  Future<void> logLookup(WidgetTester tester, CarbTrackerHomeState state,
      LookupResult result) async {
    await startLookup(tester, state, result);
    await tester.pump(RatingPrompt.askDelay);
    await tester.pumpAndSettle();
  }

  Future<void> logCleanLookups(WidgetTester tester, CarbTrackerHomeState state,
      int count) async {
    for (var i = 0; i < count; i++) {
      await logLookup(tester, state, LookupResult(items: [apple()]));
    }
  }

  testWidgets('the 5th lookup that logs food asks for a rating, once',
      (tester) async {
    final (state, prompt) = await start(tester);
    await logCleanLookups(tester, state, 4);
    expect(prompt.requests, 0);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);
  });

  testWidgets('a lookup that found no carbs does not count', (tester) async {
    final (state, prompt) = await start(tester);
    await logCleanLookups(tester, state, 4);
    await logLookup(
        tester, state, const LookupResult(items: [], unknownCarbs: ['mystery stew']));
    expect(prompt.requests, 0);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);
  });

  testWidgets(
      'a lookup that sent a food to Manual entry counts but does not ask; '
      'the next clean one does', (tester) async {
    final (state, prompt) = await start(tester);
    await logCleanLookups(tester, state, 4);

    await logLookup(
        tester,
        state,
        LookupResult(items: [apple()], unknownCarbs: const ['mystery stew']));
    expect(prompt.requests, 0);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);
  });

  testWidgets('does not ask while the app is in the background; the next '
      'lookup in the foreground does', (tester) async {
    final (state, prompt) = await start(tester);
    await logCleanLookups(tester, state, 4);

    await startLookup(tester, state, LookupResult(items: [apple()]));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(RatingPrompt.askDelay);
    expect(prompt.requests, 0);

    // Flutter asserts on a jump from paused to resumed; go back up in steps.
    for (final step in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(step);
    }
    await tester.pumpAndSettle();
    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);
  });

  testWidgets('asks one second after the food appears, not before',
      (tester) async {
    final (state, prompt) = await start(tester);
    await logCleanLookups(tester, state, 4);

    await state.applyLookupResultForTest(LookupResult(items: [apple()]));
    await tester.pump(Duration.zero);
    await tester.pump(RatingPrompt.askDelay - const Duration(milliseconds: 1));
    expect(prompt.requests, 0);

    await tester.pump(const Duration(milliseconds: 1));
    expect(prompt.requests, 1);
  });
}
