import 'package:flutter/material.dart';

import '../models/serving_info.dart';
import '../utils/a11y_labels.dart';

/// Chooses a logged food's serving. Controlled: [value] is shown, every change
/// goes to [onChanged], and nothing is saved here.
class ServingPicker extends StatelessWidget {
  const ServingPicker({super.key, required this.value, required this.onChanged});

  final ServingInfo value;
  final ValueChanged<ServingInfo> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Serving', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (value.isUsda)
          DropdownButton<String>(
            isExpanded: true,
            value: value.portionId,
            items: [
              for (final p in value.portions)
                DropdownMenuItem(
                  value: p.id,
                  child: Text(portionOptionLabel(p.label, p.grams)),
                ),
            ],
            onChanged: (id) {
              if (id != null && id != value.portionId) {
                onChanged(value.copyWith(portionId: id));
              }
            },
          ),
        Row(
          children: [
            IconButton(
              tooltip: 'Fewer servings',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: value.canDecrease ? () => onChanged(value.decreased()) : null,
            ),
            Semantics(
              value: servingsValue(value.count),
              excludeSemantics: true,
              child: Text(formatCount(value.count), style: theme.textTheme.titleMedium),
            ),
            IconButton(
              tooltip: 'More servings',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: value.canIncrease ? () => onChanged(value.increased()) : null,
            ),
            if (!value.isUsda) ...[
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  'servings of what was looked up',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
