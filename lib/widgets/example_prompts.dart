import 'package:flutter/material.dart';

import '../utils/a11y_labels.dart';
import '../utils/lookup_progress.dart';

/// Foods with amounts, to show a new user what to type.
const List<String> examplePrompts = [
  '2 slices pepperoni pizza',
  'Chipotle chicken burrito bowl',
  '1 cup cooked white rice',
  'Grande oat milk latte',
];

/// The empty Today list for someone with nothing logged or saved yet. Teaches
/// that the amount is what makes a lookup accurate. A tap only fills the food
/// field, so nothing is looked up (or counted against the free quota) until
/// the user taps Add.
class ExamplePrompts extends StatelessWidget {
  const ExamplePrompts({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Semantics(
            header: true,
            child: Text(
              'Try something like:',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final example in examplePrompts)
                Semantics(
                  button: true,
                  label: exampleChipLabel(example),
                  onTap: () => onPick(example),
                  excludeSemantics: true,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Material(
                      color: colorScheme.surfaceContainerHighest,
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => onPick(example),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Text(
                            example,
                            style: TextStyle(
                                fontSize: 14, color: colorScheme.onSurface),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Include how much you had — it makes the carbs more accurate.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: lookupStatusColor(dark: dark)),
          ),
        ],
      ),
    );
  }
}
