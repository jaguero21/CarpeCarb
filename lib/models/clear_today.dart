import 'food_item.dart';

/// The foods an Undo of "Clear today's log" puts back: those it cleared that
/// aren't on the list now, in their original order. A food logged since the
/// clear stays, and one a merge already brought back isn't added twice.
List<FoodItem> restoreCleared(List<FoodItem> current, List<FoodItem> cleared) {
  final present = {for (final food in current) food.id};
  return [
    for (final food in cleared)
      if (!present.contains(food.id)) food,
  ];
}

/// Undo applies only on the app day it cleared; after the day rolls over,
/// those foods belong to yesterday.
bool undoApplies({required String clearedOn, required String today}) =>
    clearedOn == today;
