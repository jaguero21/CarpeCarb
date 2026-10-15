import 'package:flutter/material.dart';
import '../config/app_colors.dart';
import '../models/food_item.dart';
import '../models/food_source.dart';
import 'source_tag.dart';

class FoodItemCard extends StatelessWidget {
  final String name;
  final String subtitle;
  final double carbs;
  final FoodCategory? category;
  final FoodSource? source;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showMacros;
  final double? protein;
  final double? fat;
  final double? fiber;
  final double? calories;

  const FoodItemCard({
    super.key,
    required this.name,
    required this.subtitle,
    required this.carbs,
    this.category,
    this.source,
    this.onTap,
    this.onLongPress,
    this.showMacros = false,
    this.protein,
    this.fat,
    this.fiber,
    this.calories,
  });

  String? _macroString() {
    final parts = <String>[];
    if (protein != null) parts.add('P ${protein!.toStringAsFixed(1)}g');
    if (fat != null) parts.add('F ${fat!.toStringAsFixed(1)}g');
    if (fiber != null) parts.add('Fiber ${fiber!.toStringAsFixed(1)}g');
    if (calories != null) parts.add('${calories!.toStringAsFixed(0)} kcal');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final categoryColor = category?.color ?? AppColors.sage;
    final macroLine = showMacros ? _macroString() : null;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: categoryColor.withValues(alpha: 0.15),
              ),
              child: Center(
                child: Icon(
                  category?.icon ?? Icons.restaurant,
                  size: 20,
                  color: categoryColor,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(children: [
                      if (source != null) ...[
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          // WidgetSpan already scales its child with the text; do not scale twice.
                          child: MediaQuery.withNoTextScaling(
                              child: SourceTag(source!)),
                        ),
                        const TextSpan(text: ' '),
                      ],
                      TextSpan(text: subtitle),
                    ]),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (macroLine != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        macroLine,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant
                              .withValues(alpha: 0.7),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: carbs.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  TextSpan(
                    text: 'g',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
