import 'dart:convert';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for HealthKit, which the real service only talks to on iOS.
class _RecordingHealth extends HealthKitService {
  _RecordingHealth({required this.deleteOk});
  final bool deleteOk;
  final calls = <String>[];

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    calls.add('delete ${item.carbs}');
    return deleteOk;
  }

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.carbs}');
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

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

  void seedPho() {
    SharedPreferences.setMockInitialValues({
      'food_items': jsonEncode([
        {
          'id': 'pho',
          'name': 'pho',
          'carbs': 13.7,
          'loggedAt': DateTime.now().toIso8601String(),
          'category': 'lunch',
          'details': 'USDA FoodData Central (Survey (FNDDS)): Soup, pho, with meat, 1 cup (245 g).',
          'serving': {
            'source': 'usda',
            'fdcId': 2707124,
            'portions': [
              {'id': 'p1', 'label': '1 cup', 'grams': 245},
              {'id': '100g', 'label': '100 g', 'grams': 100},
            ],
            'per100g': {'carbs': 5.6},
            'portionId': 'p1',
            'count': 1,
          },
        },
      ]),
      'last_save_date': todayKey(),
      'disclaimer_accepted': true,
    });
  }

  /// Activates the row the way VoiceOver does. A long press opens the same
  /// dialog, but the row's swipe recogniser swallows it in tests.
  Future<SemanticsHandle> openRow(WidgetTester tester, String name) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    tester.semantics.performAction(
        find.semantics.byLabel(RegExp('^$name,')), SemanticsAction.tap);
    await tester.pumpAndSettle();
    return handle;
  }

  testWidgets('the row shows the serving next to the time', (tester) async {
    stubChannels();
    seedPho();
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('· 1 cup (245 g)'), findsOneWidget);
  });

  testWidgets('the row reads its serving in words to VoiceOver', (tester) async {
    stubChannels();
    seedPho();
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel(RegExp(r'^pho, .*1 cup, 245 grams, logged')),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('Update appears only after a change; Close throws the change away', (tester) async {
    stubChannels();
    seedPho();
    final handle = await openRow(tester, 'pho');

    expect(find.text('Update'), findsNothing);
    expect(find.text('13.7 g carbs'), findsOneWidget);
    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    expect(find.text('Update'), findsOneWidget);
    expect(find.text('20.6 g carbs'), findsOneWidget);
    expect(find.text('was 13.7 g'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.foodItems.single.carbs, 13.7);
    handle.dispose();
  });

  testWidgets('Update saves the recalculated food and the day total follows', (tester) async {
    stubChannels();
    seedPho();
    final handle = await openRow(tester, 'pho');

    await tester.tap(find.byTooltip('More servings'));
    // Rebuild between taps: the second one steps from the new count.
    await tester.pump();
    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.foodItems.single.carbs, 27.4, reason: '2 cups: 5.6 × 490 / 100 = 27.44');
    expect(state.foodItems.single.serving!.count, 2);
    expect(state.foodItems.single.updatedAt, isNotNull);
    expect(state.foodItems.single.updatedAt!.isUtc, isTrue,
        reason: 'a local stamp serializes without a zone and syncs wrongly');
    expect(state.totalCarbs, 27.4);
    expect(find.text('Updated to 27.4 g'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('food_items')!) as List;
    expect((saved.single as Map)['carbs'], 27.4);
    handle.dispose();
  });

  testWidgets('the edit is stamped when Update is tapped, not when the dialog last drew',
      (tester) async {
    stubChannels();
    seedPho();
    final handle = await openRow(tester, 'pho');

    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    // Real time passes between the dialog's last build and the tap.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    final beforeTap = DateTime.now().toUtc();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    expect(state.foodItems.single.updatedAt!.isBefore(beforeTap), isFalse);
    handle.dispose();
  });

  testWidgets('a new serving with the same carbs and time says only Updated',
      (tester) async {
    stubChannels();
    seedPho();
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final old = state.foodItems.single;
    // 2.45 × 100 g is the same 245 g as 1 cup, so the same 13.7 g.
    final updated = old.edited(
        serving: old.serving!.copyWith(portionId: '100g', count: 2.45),
        now: DateTime.now().toUtc());
    expect(updated.carbs, old.carbs);

    state.updateFoodItemForTest(old, updated);
    await tester.pumpAndSettle();
    expect(find.text('Updated'), findsOneWidget);
    expect(find.textContaining('Moved to'), findsNothing);
  });

  testWidgets('Update does not overwrite a copy that changed meanwhile', (tester) async {
    stubChannels();
    seedPho();
    final handle = await openRow(tester, 'pho');

    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final old = state.foodItems[0];
    state.foodItems[0] = FoodItem(
      id: old.id,
      name: old.name,
      carbs: 99.0,
      loggedAt: old.loggedAt,
      category: old.category,
      details: old.details,
      serving: old.serving,
      updatedAt: DateTime(2026, 1, 1),
    );
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(state.foodItems.single.carbs, 99.0);
    expect(find.text('This food changed on another device. Open it again to edit.'),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('Update replaces the Health sample: delete first, then write the new carbs',
      (tester) async {
    stubChannels();
    seedPho();
    final health = _RecordingHealth(deleteOk: true);
    final handle = await openRow(tester, 'pho');
    tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome)).healthKitService = health;

    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(health.calls, ['delete 13.7', 'write 20.6']);
    expect(find.text('Health sync failed — check permissions in Settings'), findsNothing);
    handle.dispose();
  });

  testWidgets('a failed Health delete writes nothing and shows the Health error',
      (tester) async {
    stubChannels();
    seedPho();
    final health = _RecordingHealth(deleteOk: false);
    final handle = await openRow(tester, 'pho');
    tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome)).healthKitService = health;

    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(health.calls, ['delete 13.7']);
    // The error queues behind the "Updated to" snackbar.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Health sync failed — check permissions in Settings'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('Update on a food deleted meanwhile says so', (tester) async {
    stubChannels();
    seedPho();
    final handle = await openRow(tester, 'pho');
    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    state.foodItems.clear();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(state.foodItems, isEmpty);
    expect(find.text('This food was deleted on another device.'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('Add to Saved is hidden while a serving change is pending',
      (tester) async {
    stubChannels();
    seedPho();
    final handle = await openRow(tester, 'pho');

    expect(find.text('Add to Saved'), findsOneWidget);
    await tester.tap(find.byTooltip('More servings'));
    await tester.pumpAndSettle();
    expect(find.text('Add to Saved'), findsNothing);
    await tester.tap(find.byTooltip('Fewer servings'));
    await tester.pumpAndSettle();
    expect(find.text('Add to Saved'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a food without a serving has no picker', (tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues({
      'food_items': jsonEncode([
        {'id': 'a', 'name': 'Apple', 'carbs': 25.0,
         'loggedAt': DateTime.now().toIso8601String(), 'category': 'snack'},
      ]),
      'last_save_date': todayKey(),
      'disclaimer_accepted': true,
    });
    final handle = await openRow(tester, 'Apple');
    expect(find.text('Add to Saved'), findsOneWidget,
        reason: 'the dialog is open');
    expect(find.byTooltip('More servings'), findsNothing);
    handle.dispose();
  });
}
