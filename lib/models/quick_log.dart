import 'food_item.dart';

/// How many recent foods the quick-add row shows after the saved ones.
const int maxRecentChips = 8;

/// One quick-add chip. [isRecent] chips can be removed from recents; saved
/// ones are managed in Settings.
class QuickLogChip {
  const QuickLogChip(this.food, {required this.isRecent});

  final FoodItem food;
  final bool isRecent;
}

String _nameKey(String name) => name.trim().toLowerCase();

/// The quick-add row: every saved food, then up to [maxRecentChips] recent
/// foods that aren't saved already. [recent] is newest first.
List<QuickLogChip> quickLogChips({
  required List<FoodItem> saved,
  required List<FoodItem> recent,
}) {
  final savedNames = {for (final food in saved) _nameKey(food.name)};
  return [
    for (final food in saved) QuickLogChip(food, isRecent: false),
    for (final food in recent
        .where((food) => !savedNames.contains(_nameKey(food.name)))
        .take(maxRecentChips))
      QuickLogChip(food, isRecent: true),
  ];
}
