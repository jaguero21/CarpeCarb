import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/meal_sections.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = DateTime(2026, 10, 14, 12);
  FoodItem food(String name, double carbs, FoodCategory category, int minute) =>
      FoodItem(
        name: name,
        carbs: carbs,
        category: category,
        loggedAt: base.add(Duration(minutes: minute)),
      );

  test('no foods, no sections', () {
    expect(mealSections([]), isEmpty);
  });

  test('groups by meal and totals each meal', () {
    final sections = mealSections([
      food('eggs', 1.2, FoodCategory.breakfast, 0),
      food('toast', 14.5, FoodCategory.breakfast, 1),
      food('soup', 20.3, FoodCategory.lunch, 2),
    ]);
    expect(sections.map((s) => s.category),
        [FoodCategory.lunch, FoodCategory.breakfast]);
    expect(sections[1].totalCarbs, closeTo(15.7, 1e-9));
    expect(sections[0].totalCarbs, closeTo(20.3, 1e-9));
  });

  test('the meal with the newest food comes first', () {
    final sections = mealSections([
      food('soup', 20, FoodCategory.lunch, 0),
      food('latte', 14, FoodCategory.breakfast, 30),
    ]);
    expect(sections.first.category, FoodCategory.breakfast);
  });

  test('foods inside a meal are newest first', () {
    final sections = mealSections([
      food('first', 1, FoodCategory.lunch, 0),
      food('third', 3, FoodCategory.lunch, 20),
      food('second', 2, FoodCategory.lunch, 10),
    ]);
    expect(sections.single.items.map((f) => f.name), ['third', 'second', 'first']);
  });

  test('equal times keep the input order', () {
    // More than the 32 items a short insertion sort handles in order, so a
    // missing tiebreak shows up as a shuffled list.
    final sections = mealSections([
      for (var i = 0; i < 40; i++) food('f$i', 1, FoodCategory.snack, 5),
    ]);
    expect(sections.single.items.map((f) => f.name),
        [for (var i = 0; i < 40; i++) 'f$i']);
  });

  test('a meal that comes back later is its own section', () {
    final sections = mealSections([
      food('eggs', 1, FoodCategory.breakfast, 0),
      food('soup', 2, FoodCategory.lunch, 10),
      food('toast', 3, FoodCategory.breakfast, 20),
    ]);
    expect(sections.map((s) => s.category),
        [FoodCategory.breakfast, FoodCategory.lunch, FoodCategory.breakfast]);
    expect(sections.map((s) => s.items.map((f) => f.name).toList()),
        [['toast'], ['soup'], ['eggs']]);
  });

  test('an afternoon snack and a bedtime snack are two sections', () {
    final sections = mealSections([
      food('apple', 15, FoodCategory.snack, 0),
      food('soup', 20, FoodCategory.lunch, 300),
      food('cereal', 30, FoodCategory.snack, 600),
    ]);
    expect(sections.map((s) => s.category),
        [FoodCategory.snack, FoodCategory.lunch, FoodCategory.snack]);
    expect(sections.map((s) => s.totalCarbs), [30, 20, 15]);
  });

  test('foods of one meal in a row stay in one section', () {
    final sections = mealSections([
      food('a', 1, FoodCategory.snack, 0),
      food('b', 2, FoodCategory.snack, 10),
      food('c', 4, FoodCategory.snack, 20),
    ]);
    expect(sections.single.items.map((f) => f.name), ['c', 'b', 'a']);
    expect(sections.single.totalCarbs, 7);
  });

  test('a section is identified by its oldest food, which stays put as newer ones join', () {
    final first = food('first', 1, FoodCategory.lunch, 0);
    final second = food('second', 2, FoodCategory.lunch, 10);
    final third = food('third', 3, FoodCategory.lunch, 20);
    expect(mealSections([first]).single.id, first.id);
    expect(mealSections([first, second, third]).single.id, first.id);
  });
}
