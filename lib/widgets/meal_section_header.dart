import 'package:flutter/material.dart';

import '../models/meal_sections.dart';
import '../utils/a11y_labels.dart';

/// The header above one meal's foods in today's list: icon, meal name, and
/// the meal's carb total, which is what a per-meal insulin dose is based on.
class MealSectionHeader extends StatelessWidget {
  const MealSectionHeader({super.key, required this.section});

  final MealSection section;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurface,
    );
    return Semantics(
      header: true,
      label: mealHeaderLabel(
        meal: section.category.label,
        carbs: section.totalCarbs,
        foods: section.items.length,
      ),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Row(
          children: [
            Icon(section.category.icon, size: 18, color: section.category.color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(section.category.label,
                  style: style, overflow: TextOverflow.ellipsis),
            ),
            const Spacer(),
            Text('${section.totalCarbs.toStringAsFixed(1)} g', style: style),
          ],
        ),
      ),
    );
  }
}
