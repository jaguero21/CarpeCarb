import 'package:carb_tracker/models/clear_today.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = FoodItem(id: 'a', name: 'A', carbs: 1);
  final b = FoodItem(id: 'b', name: 'B', carbs: 2);
  final c = FoodItem(id: 'c', name: 'C', carbs: 3);

  test('nothing back yet: all of them, in order', () {
    expect(restoreCleared([], [a, b, c]).map((f) => f.id), ['a', 'b', 'c']);
  });

  test('foods already on the list are not put back twice', () {
    final logged = FoodItem(id: 'new', name: 'New', carbs: 9);
    expect(restoreCleared([logged, b], [a, b, c]).map((f) => f.id), ['a', 'c']);
  });

  test('nothing cleared, nothing back', () {
    expect(restoreCleared([a], []), isEmpty);
  });

  test('Undo only applies on the day it cleared', () {
    expect(undoApplies(clearedOn: '2026-10-15', today: '2026-10-15'), isTrue);
    expect(undoApplies(clearedOn: '2026-10-15', today: '2026-10-16'), isFalse);
  });
}
