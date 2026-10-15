import 'package:carb_tracker/widgets/appear_once.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(String label, {bool animate = false}) => MaterialApp(
        home: AppearOnce(animate: animate, child: Text(label)),
      );

  Animation<double> opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(find.descendant(
          of: find.byType(AppearOnce), matching: find.byType(FadeTransition)))
      .opacity;

  testWidgets('a rebuild reuses one animation instead of leaking a new one',
      (tester) async {
    await tester.pumpWidget(host('a'));
    final first = opacity(tester);
    await tester.pumpWidget(host('b'));
    await tester.pumpWidget(host('c'));
    expect(opacity(tester), same(first));
  });

  testWidgets('a new row fades in; an existing one is already there',
      (tester) async {
    await tester.pumpWidget(host('new', animate: true));
    expect(opacity(tester).value, 0);
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester).value, 1);

    await tester.pumpWidget(MaterialApp(
      home: AppearOnce(key: UniqueKey(), animate: false, child: const Text('old')),
    ));
    expect(opacity(tester).value, 1);
  });
}
