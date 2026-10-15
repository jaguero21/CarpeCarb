import 'package:flutter/material.dart';

import '../config/app_colors.dart';
import '../utils/lookup_progress.dart';

typedef SettingsTab = ({IconData icon, String label});

/// The selected tab's fill: sage darkened so white text on it reads at 4.5:1
/// (plain sage is about 2.7:1).
Color settingsTabSelectedFill() =>
    Color.lerp(AppColors.sage, Colors.black, 0.35)!;

/// Unselected tabs' icon and name: the same readable grey as other small
/// secondary text.
Color settingsTabUnselected({required bool dark}) => lookupStatusColor(dark: dark);

/// Settings' tabs, each named under its icon so none is a bare icon.
class SettingsTabBar extends StatelessWidget {
  const SettingsTabBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final List<SettingsTab> tabs;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        for (var i = 0; i < tabs.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Semantics(
                button: true,
                selected: i == selected,
                label: tabs[i].label,
                onTap: () => onSelected(i),
                excludeSemantics: true,
                // The fill sits outside the Material so it can fade between
                // tabs (Material's own colour changes instantly) and the
                // ripple still draws on top of it.
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: i == selected
                        ? settingsTabSelectedFill()
                        : settingsTabSelectedFill().withValues(alpha: 0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onSelected(i),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                tabs[i].icon,
                                size: 20,
                                color: i == selected
                                    ? Colors.white
                                    : settingsTabUnselected(dark: dark),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                tabs[i].label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: i == selected
                                      ? Colors.white
                                      : settingsTabUnselected(dark: dark),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
