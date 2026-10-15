import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/widgets/food_item_card.dart';
import 'package:carb_tracker/widgets/source_tag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> food(String id, String name, double carbs,
          {Map<String, Object?> extra = const {}}) =>
      {
        'id': id,
        'name': name,
        'carbs': carbs,
        'category': 'lunch',
        'loggedAt': DateTime.now().toIso8601String(),
        ...extra,
      };

  final day = [
    food('u', 'Pho', 41.2, extra: {
      'details': 'USDA FoodData Central (Survey (FNDDS)): Soup, pho, 1 cup (245 g).',
    }),
    food('w', 'Protein bar', 22, extra: {'details': 'Web source, not USDA. Per label.'}),
    food('m', 'Toast', 15, extra: {'isManualEntry': true}),
    food('o', 'Old lookup', 30, extra: {'details': 'Per Chipotle, 1 bowl.'}),
  ];

  Future<void> start(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(day));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
  }

  Finder inRow(String text) =>
      find.descendant(of: find.byType(FoodItemCard), matching: find.text(text));

  testWidgets('rows show where their carbs came from', (tester) async {
    await start(tester);
    expect(inRow('USDA'), findsOneWidget);
    expect(inRow('Web'), findsOneWidget);
    expect(inRow('Manual'), findsOneWidget);
    expect(find.byType(SourceTag), findsNWidgets(3));
  });

  testWidgets('VoiceOver reads the source in the row label', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester);
      expect(find.semantics.byLabel(RegExp(r'^Pho, 41\.2 grams of carbs, from USDA, ')),
          findsOneWidget);
      expect(find.semantics.byLabel(RegExp(r'^Toast, 15 grams of carbs, entered manually, ')),
          findsOneWidget);
      expect(find.semantics.byLabel(RegExp(r'^Old lookup, 30 grams of carbs, logged ')),
          findsOneWidget);
    } finally {
      handle.dispose();
    }
  });
}
