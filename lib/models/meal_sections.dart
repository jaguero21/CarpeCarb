import 'food_item.dart';

/// One meal in today's list: its foods, newest first, and their carb total.
class MealSection {
  const MealSection({required this.category, required this.items});

  final FoodCategory category;
  final List<FoodItem> items;

  /// The id of the section's oldest food. It stays the same as newer foods
  /// join, so it keys the section's header.
  String get id => items.last.id;

  double get totalCarbs => items.fold(0.0, (sum, item) => sum + item.carbs);
}

/// Today's foods split into eating occasions, for dosing per meal instead of
/// adding a meal up by hand. Foods are newest first, and a new section starts
/// whenever the meal changes from the previous food, so an afternoon snack and
/// a bedtime snack are two sections. Equal times keep [items]' order.
List<MealSection> mealSections(List<FoodItem> items) {
  final ordered = [for (var i = 0; i < items.length; i++) (i, items[i])]
    ..sort((a, b) {
      final byTime = b.$2.loggedAt.compareTo(a.$2.loggedAt);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  final sections = <MealSection>[];
  for (final (_, item) in ordered) {
    if (sections.isNotEmpty && sections.last.category == item.category) {
      sections.last.items.add(item);
    } else {
      sections.add(MealSection(category: item.category, items: [item]));
    }
  }
  return sections;
}
