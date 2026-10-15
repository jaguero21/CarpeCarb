import 'package:flutter/material.dart';

import '../config/app_colors.dart';
import '../models/food_source.dart';

Color _base(FoodSource source, bool dark) => switch (source) {
      FoodSource.usda => AppColors.sage,
      FoodSource.web => AppColors.honey,
      FoodSource.manual => dark ? AppColors.darkMuted : AppColors.muted,
    };

/// The pill's colours. The text is the base colour darkened (light mode) or
/// lightened (dark mode): sage and honey as they are fall below 4.5:1 at 10 pt.
({Color background, Color text}) sourceTagColors(FoodSource source,
    {required bool dark}) {
  final base = _base(source, dark);
  return (
    background: base.withValues(alpha: 0.15),
    text: Color.lerp(base, dark ? Colors.white : Colors.black, dark ? 0.35 : 0.45)!,
  );
}

/// A small pill naming where a food's carbs came from: USDA, Web or Manual.
class SourceTag extends StatelessWidget {
  const SourceTag(this.source, {super.key});

  final FoodSource source;

  @override
  Widget build(BuildContext context) {
    final colors = sourceTagColors(source,
        dark: Theme.of(context).brightness == Brightness.dark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        source.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: colors.text,
        ),
      ),
    );
  }
}
