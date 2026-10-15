import 'package:flutter/material.dart';

import '../config/app_colors.dart';
import '../models/food_item.dart';
import '../utils/a11y_labels.dart';
import '../utils/date_format.dart';

/// The error under the row, on the dialog. Terracotta itself is too pale
/// for 12 pt text in light mode, so it is darkened there.
Color timeErrorColor({required bool dark}) => dark
    ? AppColors.terracotta
    : Color.lerp(AppColors.terracotta, Colors.black, 0.25)!;

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
    // At large text sizes the dropdown keeps its width and would squeeze the
    // time off the row, so the two stack instead.
    final stacked = MediaQuery.textScalerOf(context).scale(10) / 10 > 1.3;
    final timeButton = Semantics(
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
    );
    final mealDropdown = Semantics(
      label: mealDropdownLabel(meal.label),
      child: DropdownButton<FoodCategory>(
        value: meal,
        isExpanded: stacked,
        underline: const SizedBox.shrink(),
        // The label above already names the meal; the visible selection
        // would make VoiceOver read it twice. The open menu's items keep
        // their own semantics.
        selectedItemBuilder: (context) => [
          for (final category in FoodCategory.values)
            ExcludeSemantics(child: _mealLabel(category, fit: stacked)),
        ],
        items: [
          for (final category in FoodCategory.values)
            DropdownMenuItem(
              value: category,
              child: _mealLabel(category, fit: stacked),
            ),
        ],
        onChanged: (category) {
          if (category != null) onMealChanged(category);
        },
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (stacked) ...[
          timeButton,
          mealDropdown,
        ] else
          Row(
            children: [
              Expanded(child: timeButton),
              const SizedBox(width: 8),
              mealDropdown,
            ],
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error!,
              style: TextStyle(
                  fontSize: 12,
                  color: timeErrorColor(
                      dark: Theme.of(context).brightness == Brightness.dark)),
            ),
          ),
      ],
    );
  }

  /// A meal's icon and name. With [fit], a name too long for the width ends
  /// in an ellipsis instead of overflowing; only a bounded width allows that.
  static Widget _mealLabel(FoodCategory category, {required bool fit}) {
    final name = Text(category.label, overflow: TextOverflow.ellipsis);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(category.icon, size: 18, color: category.color),
        const SizedBox(width: 6),
        if (fit) Flexible(child: name) else name,
      ],
    );
  }
}
