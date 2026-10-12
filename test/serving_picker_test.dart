import 'package:carb_tracker/models/serving_info.dart';
import 'package:carb_tracker/widgets/serving_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final usda = ServingInfo.usda(
    fdcId: 1,
    portions: const [
      ServingPortion(id: 'p1', label: '1 cup', grams: 120),
      ServingPortion(id: 'p2', label: 'typical serving', grams: 270),
      ServingPortion(id: '100g', label: '100 g', grams: 100),
    ],
    per100g: const Nutrients(carbs: 10.58),
    portionId: 'p2',
    count: 1,
  );

  Future<List<ServingInfo>> pump(WidgetTester tester, ServingInfo value) async {
    final changes = <ServingInfo>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ServingPicker(value: value, onChanged: changes.add)),
    ));
    return changes;
  }

  testWidgets('USDA: a menu of portions with their weights, and a count', (tester) async {
    final changes = await pump(tester, usda);

    expect(find.text('typical serving · 270 g'), findsOneWidget);
    await tester.tap(find.text('typical serving · 270 g'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 cup · 120 g').last);
    await tester.pumpAndSettle();
    expect(changes.single.portionId, 'p1');
    expect(changes.single.count, 1);
  });

  testWidgets('the stepper moves by ½ and labels itself for VoiceOver', (tester) async {
    final changes = await pump(tester, usda);

    expect(find.bySemanticsLabel('More servings'), findsOneWidget);
    expect(find.bySemanticsLabel('Fewer servings'), findsOneWidget);
    expect(tester.getSemantics(find.text('1')), matchesSemantics(value: '1 serving'));
    await tester.tap(find.bySemanticsLabel('More servings'));
    expect(changes.last.count, 1.5);
    await tester.tap(find.bySemanticsLabel('Fewer servings'));
    expect(changes.last.count, 0.5);
  });

  testWidgets('at ½ the Fewer button is disabled', (tester) async {
    final changes = await pump(tester, usda.copyWith(count: 0.5));
    await tester.tap(find.bySemanticsLabel('Fewer servings'));
    expect(changes, isEmpty);
  });

  testWidgets('web: only the count, labelled as servings of what was looked up', (tester) async {
    await pump(tester, ServingInfo.web(base: const Nutrients(carbs: 27)));
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('servings of what was looked up'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('VoiceOver: each stepper node is a button with a working tap action', (tester) async {
    final handle = tester.ensureSemantics();
    final changes = await pump(tester, usda);

    expect(
      tester.getSemantics(find.bySemanticsLabel('More servings')),
      matchesSemantics(
        label: 'More servings',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    tester.semantics.tap(find.semantics.byLabel('More servings'));
    await tester.pump();
    expect(changes.single.count, 1.5);

    await tester.pumpWidget(const SizedBox());
    final low = await pump(tester, usda.copyWith(count: 0.5));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Fewer servings')),
      matchesSemantics(
        label: 'Fewer servings',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    expect(low, isEmpty);
    handle.dispose();
  });
}
