import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the colors that moved out of view code and into the palette.
///
/// Naming a value is only a refactor if the value survives it, and three of
/// the category colors are near-misses of brand colors with the same name —
/// `categorySage` is not `sage`. Reaching for the wrong constant would repaint
/// the app, so each one is asserted against the literal it replaced.
void main() {
  test('every food category keeps the color it had', () {
    expect(FoodCategory.breakfast.color, const Color(0xFFE8A93C));
    expect(FoodCategory.lunch.color, const Color(0xFF7D9B76));
    expect(FoodCategory.dinner.color, const Color(0xFFD4714E));
    expect(FoodCategory.snack.color, const Color(0xFFB07CC6));
    expect(FoodCategory.drink.color, const Color(0xFF5B9BD5));
  });

  test('the near-miss category colors are not their brand namesakes', () {
    // If these ever become equal, the pinning test above stops being able to
    // tell `categorySage` from `sage` and the guard quietly weakens.
    expect(AppColors.categorySage, isNot(AppColors.sage));
    expect(AppColors.categoryPlum, isNot(AppColors.plum));
    expect(AppColors.categorySky, isNot(AppColors.sky));
  });

  test('the constants named after existing brand colors still equal them', () {
    expect(AppColors.categoryHoney, AppColors.honey);
    expect(AppColors.categoryTerracotta, AppColors.terracotta);
  });

  test('the progress track keeps its light-mode grey', () {
    expect(AppColors.progressTrack, const Color(0xFFE5E7EB));
  });
}
