import 'package:flutter/material.dart';

import '../config/app_colors.dart';

/// The status line under the Add Food button while a lookup runs. The app
/// sends one request and gets one answer, so it can't see the server's steps;
/// these messages only ever describe the wait, never a step.
String lookupProgressMessage(Duration elapsed) {
  if (elapsed < const Duration(seconds: 5)) return 'Checking nutrition sources…';
  if (elapsed < const Duration(seconds: 12)) {
    return 'Still checking — some foods take longer';
  }
  if (elapsed < const Duration(seconds: 20)) return 'Still working on it…';
  return 'Taking longer than usual…';
}

/// The status line's text colour on the input card (white in light mode,
/// AppColors.darkSurface in dark). The theme's muted grey is 3.99:1 on white,
/// under the 4.5:1 small text needs, so light mode darkens it to about 6:1.
/// Dark mode's muted grey already passes at 5.02:1.
Color lookupStatusColor({required bool dark}) => dark
    ? AppColors.darkMuted
    : Color.lerp(AppColors.muted, Colors.black, 0.25)!;
