import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/utils/lookup_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/contrast.dart';

void main() {
  String at(int seconds) => lookupProgressMessage(Duration(seconds: seconds));

  test('the message changes at 5, 12 and 20 seconds', () {
    expect(at(0), 'Checking nutrition sources…');
    expect(at(4), 'Checking nutrition sources…');
    expect(at(5), 'Still checking — some foods take longer');
    expect(at(11), 'Still checking — some foods take longer');
    expect(at(12), 'Still working on it…');
    expect(at(19), 'Still working on it…');
    expect(at(20), 'Taking longer than usual…');
    expect(at(90), 'Taking longer than usual…');
  });

  for (final dark in [false, true]) {
    test('the status line is readable on the input card in ${dark ? 'dark' : 'light'} mode',
        () {
      final card = dark ? AppColors.darkSurface : Colors.white;
      expect(contrastRatio(lookupStatusColor(dark: dark), card),
          greaterThanOrEqualTo(4.5));
    });
  }
}
