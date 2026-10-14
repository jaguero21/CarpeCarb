import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/quick_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FoodItem food(String name) => FoodItem(name: name, carbs: 10);

  test('nothing saved or recent, no chips', () {
    expect(quickLogChips(saved: [], recent: []), isEmpty);
  });

  test('saved foods first, in saved order, then recents', () {
    final chips = quickLogChips(
      saved: [food('Oatmeal'), food('Banana')],
      recent: [food('Pho'), food('Bagel')],
    );
    expect(chips.map((c) => c.food.name), ['Oatmeal', 'Banana', 'Pho', 'Bagel']);
    expect(chips.map((c) => c.isRecent), [false, false, true, true]);
  });

  test('a recent food already saved is skipped, ignoring case and spaces', () {
    final chips = quickLogChips(
      saved: [food('Banana')],
      recent: [food('  banana '), food('Pho')],
    );
    expect(chips.map((c) => c.food.name), ['Banana', 'Pho']);
  });

  test('at most 8 recents, newest first as given', () {
    final chips = quickLogChips(
      saved: [food('Saved')],
      recent: [for (var i = 0; i < 12; i++) food('r$i')],
    );
    expect(chips.length, 1 + maxRecentChips);
    expect(chips.last.food.name, 'r7');
  });
}
