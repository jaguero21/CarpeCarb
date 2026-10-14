import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/rating_prompt.dart';
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

  Future<void> logLookup(WidgetTester tester, CarbTrackerHomeState state,
      LookupResult result) async {
    await state.applyLookupResultForTest(result);
    // Let the prefs write finish so the delay timer exists, then run it out.
    await tester.pump();
    await tester.pump(RatingPrompt.askDelay);
    await tester.pumpAndSettle();
  }

  testWidgets('the 5th lookup that logs food asks for a rating, once',
      (tester) async {
    final (state, prompt) = await start(tester);
    for (var i = 0; i < 4; i++) {
      await logLookup(tester, state, LookupResult(items: [apple()]));
    }
    expect(prompt.requests, 0);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);
  });

  testWidgets('a lookup that found no carbs does not count', (tester) async {
    final (state, prompt) = await start(tester);
    for (var i = 0; i < 4; i++) {
      await logLookup(tester, state, LookupResult(items: [apple()]));
    }
    await logLookup(
        tester, state, const LookupResult(items: [], unknownCarbs: ['mystery stew']));
    expect(prompt.requests, 0);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);
  });
}
