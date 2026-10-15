import 'package:flutter/material.dart';

import '../config/app_colors.dart';

/// The link's text colour on the input card: sage darkened in light mode and
/// lightened in dark mode, since sage itself is too pale for 14 pt text.
Color entryLinkColor({required bool dark}) => dark
    ? Color.lerp(AppColors.sage, Colors.white, 0.35)!
    : Color.lerp(AppColors.sage, Colors.black, 0.45)!;

/// Under the food field: switches between looking a food up and typing its
/// carbs. Replaces the old Auto/Manual switch, so there's no mode to choose
/// before every entry.
class EntryModeLink extends StatelessWidget {
  const EntryModeLink({super.key, required this.manual, required this.onPressed});

  /// Whether the carbs field is showing.
  final bool manual;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: entryLinkColor(dark: dark),
        ),
        onPressed: onPressed,
        child: Text(
          manual ? 'Look it up instead' : 'Enter carbs yourself',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
