import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/widgets/settings_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  });

  // The 44 pt minimum height of each tab, found by its constraint: the tabs'
  // own content is already about 48 pt tall at normal text size, so a height
  // check there can't tell whether the minimum is still set.
  Finder minHeightBoxes() => find.descendant(
        of: find.byType(SettingsTabBar),
        matching: find.byWidgetPredicate(
            (w) => w is ConstrainedBox && w.constraints.minHeight > 0),
      );

  testWidgets('every tab keeps a 44 pt tap target, even at small text',
      (tester) async {
    for (final scale in [1.0, 0.5]) {
      await pump(tester, textScale: scale);
      final boxes = tester.widgetList<ConstrainedBox>(minHeightBoxes()).toList();
      expect(boxes, hasLength(_tabs.length), reason: 'text scale $scale');
      for (final box in boxes) {
        expect(box.constraints.minHeight, 44, reason: 'text scale $scale');
      }
      // At half-size text the content alone is about 40 pt, so reaching 44
      // takes the minimum.
      for (var i = 0; i < _tabs.length; i++) {
        expect(tester.getSize(minHeightBoxes().at(i)).height,
            greaterThanOrEqualTo(44),
            reason: '${_tabs[i].label} at text scale $scale');
      }
    }
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

    // "Features" is too wide for its tab here, so it must stay on one line
    // and end in an ellipsis. Without that it wraps onto extra lines, which a
    // tall enough bar would absorb without any overflow error.
    final label = tester.widget<Text>(find.text('Features'));
    expect(label.maxLines, 1);
    expect(label.overflow, TextOverflow.ellipsis);

    final paragraph = tester.renderObject<RenderParagraph>(find.text('Features'));
    expect(paragraph.didExceedMaxLines, isTrue,
        reason: 'the label should be too wide for its tab at this size');
    final oneLine = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
    )..layout();
    addTearDown(oneLine.dispose);
    expect(paragraph.size.height, oneLine.height);
    expect(tester.getSize(find.text('Features')).height,
        tester.getSize(find.text('Goals')).height);
  });
}
