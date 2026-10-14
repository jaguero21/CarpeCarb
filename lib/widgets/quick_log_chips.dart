import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../models/food_item.dart';
import '../models/quick_log.dart';
import '../utils/a11y_labels.dart';

/// A row of foods to log again in one tap: saved foods, then recent ones.
class QuickLogChips extends StatelessWidget {
  const QuickLogChips({
    super.key,
    required this.chips,
    required this.onLog,
    required this.onRemoveRecent,
  });

  final List<QuickLogChip> chips;
  final ValueChanged<FoodItem> onLog;
  final ValueChanged<FoodItem> onRemoveRecent;

  Future<void> _offerRemove(BuildContext context, FoodItem food) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.history_toggle_off),
          title: const Text('Remove from recents'),
          subtitle: Text(food.name),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (remove == true) onRemoveRecent(food);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Quick add',
      explicitChildNodes: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final chip in chips)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Semantics(
                  button: true,
                  label: quickLogChipLabel(
                      name: chip.food.name, carbs: chip.food.carbs),
                  onTap: () => onLog(chip.food),
                  customSemanticsActions: chip.isRecent
                      ? {
                          const CustomSemanticsAction(label: 'Remove from recents'):
                              () => onRemoveRecent(chip.food),
                        }
                      : null,
                  excludeSemantics: true,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200, minHeight: 44),
                    child: Material(
                      color: colorScheme.surfaceContainerHighest,
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => onLog(chip.food),
                        onLongPress: chip.isRecent
                            ? () => _offerRemove(context, chip.food)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Text(
                            '${chip.food.name} · ${chip.food.carbs.toStringAsFixed(1)} g',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14, color: colorScheme.onSurface),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
