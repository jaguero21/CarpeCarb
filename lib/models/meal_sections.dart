import 'food_item.dart';

/// One meal in today's list: its foods, newest first, and their carb total.
class MealSection {
  const MealSection({required this.category, required this.items});

  final FoodCategory category;
  final List<FoodItem> items;

  double get totalCarbs => items.fold(0.0, (sum, item) => sum + item.carbs);
}

/// Today's foods grouped by meal, for dosing per meal instead of adding a
/// meal up by hand. The meal with the newest food comes first, and foods
/// inside a meal are newest first. Equal times keep [items]' order.
List<MealSection> mealSections(List<FoodItem> items) {
  final ordered = [for (var i = 0; i < items.length; i++) (i, items[i])]
    ..sort((a, b) {
      final byTime = b.$2.loggedAt.compareTo(a.$2.loggedAt);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  // A map literal keeps insertion order, and each meal is inserted at its
  // newest food, so the sections come out newest first.
  final byMeal = <FoodCategory, List<FoodItem>>{};
  for (final (_, item) in ordered) {
    byMeal.putIfAbsent(item.category, () => []).add(item);
  }
  return [
    for (final entry in byMeal.entries)
      MealSection(category: entry.key, items: entry.value),
  ];
}
