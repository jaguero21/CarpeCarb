import 'package:carb_tracker/widgets/example_prompts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the examples and the tip; a tap reports the example',
      (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ExamplePrompts(onPick: picked.add))));
    expect(find.text('Try something like:'), findsOneWidget);
    for (final e in examplePrompts) {
      expect(find.text(e), findsOneWidget);
    }
    expect(find.text('Include how much you had — it makes the carbs more accurate.'),
        findsOneWidget);
    await tester.tap(find.text('2 slices pepperoni pizza'));
    expect(picked, ['2 slices pepperoni pizza']);
    expect(tester.getSize(find.ancestor(
            of: find.text('2 slices pepperoni pizza'),
            matching: find.byType(ConstrainedBox)).first).height,
        greaterThanOrEqualTo(44));
  });

  testWidgets('VoiceOver: a heading and example buttons', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ExamplePrompts(onPick: (_) {}))));
      expect(find.semantics.byLabel('Try something like:').evaluate().single,
          isSemantics(isHeader: true));
      expect(
          find.semantics.byLabel('Use example, 2 slices pepperoni pizza').evaluate().single,
          isSemantics(isButton: true, hasTapAction: true));
    } finally {
      handle.dispose();
    }
  });
}
