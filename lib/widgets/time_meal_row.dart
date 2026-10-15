import 'package:flutter/material.dart';

import '../models/food_item.dart';
import '../utils/a11y_labels.dart';
import '../utils/date_format.dart';

/// In a food's details: when it was eaten and which meal it counts toward.
/// Controlled — the caller opens the time picker (so it can refuse times
/// outside today) and owns the draft.
class TimeMealRow extends StatelessWidget {
  const TimeMealRow({
    super.key,
    required this.time,
    required this.meal,
    required this.onPickTime,
    required this.onMealChanged,
    this.error,
  });

  final DateTime time;
  final FoodCategory meal;
  final VoidCallback onPickTime;
  final ValueChanged<FoodCategory> onMealChanged;

  /// Shown under the row, e.g. when a picked time was outside today.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: timeRowLabel(formatTime(time)),
                hint: 'Double tap to change',
                onTap: onPickTime,
                excludeSemantics: true,
                child: InkWell(
                  onTap: onPickTime,
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Row(
                      children: [
                        Icon(Icons.schedule, size: 18, color: colorScheme.onSurface),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Time · ${formatTime(time)}',
                            style: TextStyle(fontSize: 15, color: colorScheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: mealDropdownLabel(meal.label),
              child: DropdownButton<FoodCategory>(
                value: meal,
                underline: const SizedBox.shrink(),
                items: [
                  for (final category in FoodCategory.values)
                    DropdownMenuItem(
                      value: category,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(category.icon, size: 18, color: category.color),
                          const SizedBox(width: 6),
                          Text(category.label),
                        ],
                      ),
                    ),
                ],
                onChanged: (category) {
                  if (category != null) onMealChanged(category);
                },
              ),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error!,
              style: TextStyle(fontSize: 12, color: colorScheme.error),
            ),
          ),
      ],
    );
  }
}
