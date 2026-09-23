import 'dart:ui';
import 'package:flutter/material.dart';

import '../config/app_colors.dart';

/// A frosted-glass container inspired by Apple's Liquid Glass design language.
///
/// Uses [BackdropFilter] with [ImageFilter.blur] to create a translucent,
/// frosted appearance. Adapts automatically to light and dark themes.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 10.0,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.padding,
    this.margin,
  });

  final Widget child;

  /// Blur sigma for the frosted effect. Higher = more frosted.
  final double blur;

  /// Corner radius of the glass container.
  final BorderRadius borderRadius;

  /// Inner padding applied to the child.
  final EdgeInsetsGeometry? padding;

  /// Outer margin around the glass container.
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isLight = brightness == Brightness.light;

    final fillColor = isLight
        ? Colors.white.withValues(alpha: 0.6)
        : AppColors.darkSurface.withValues(alpha: 0.4);
    final borderColor = isLight
        ? Colors.white.withValues(alpha: 0.2)
        : AppColors.lightInk.withValues(alpha: 0.08);

    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: borderRadius,
              border: Border.all(color: borderColor, width: 0.5),
            ),
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}
