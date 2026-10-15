import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/widgets/settings_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/contrast.dart';

const List<SettingsTab> _tabs = [
  (icon: Icons.bookmark_border, label: 'Saved'),
  (icon: Icons.history, label: 'History'),
  (icon: Icons.adjust, label: 'Goals'),
  (icon: Icons.workspace_premium, label: 'Features'),
];

void main() {
  test('tab colours are readable', () {
    expect(contrastRatio(Colors.white, settingsTabSelectedFill()),
        greaterThanOrEqualTo(4.5));
    expect(contrastRatio(settingsTabUnselected(dark: false), AppColors.cream),
        greaterThanOrEqualTo(4.5));
    expect(contrastRatio(settingsTabUnselected(dark: true), AppColors.darkBackground),
        greaterThanOrEqualTo(4.5));
  });

  Future<List<int>> pump(WidgetTester tester,
      {int selected = 0, double width = 400, double textScale = 1}) async {
    final taps = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            size: Size(width, 800), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: width - 48,
              child: SettingsTabBar(tabs: _tabs, selected: selected, onSelected: taps.add),
            ),
          ),
        ),
      ),
    ));
    return taps;
  }

  testWidgets('every tab shows its name; a tap selects it', (tester) async {
    final taps = await pump(tester);
    for (final t in _tabs) {
      expect(find.text(t.label), findsOneWidget);
    }
    await tester.tap(find.text('History'));
    expect(taps, [1]);
    expect(tester.getSize(find.ancestor(
            of: find.text('Goals'), matching: find.byType(ConstrainedBox)).first).height,
        greaterThanOrEqualTo(44));
  });

  testWidgets('VoiceOver: buttons with names and the selected state', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await pump(tester, selected: 2);
      expect(find.semantics.byLabel('Goals').evaluate().single,
          isSemantics(isButton: true, isSelected: true, hasTapAction: true));
      expect(find.semantics.byLabel('Saved').evaluate().single,
          isSemantics(isButton: true, isSelected: false, hasTapAction: true));
    } finally {
      handle.dispose();
    }
  });

  testWidgets('no overflow at double text on a small phone', (tester) async {
    await pump(tester, width: 320, textScale: 2);
    expect(tester.takeException(), isNull);
  });
}
