import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/recent_foods.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 10, 14, 12);
  FoodItem food(String name, double carbs, {DateTime? at}) =>
      FoodItem(name: name, carbs: carbs, loggedAt: at ?? now);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('starts empty', () async {
    expect(await RecentFoods().load(now), isEmpty);
  });

  test('records foods, newest first', () async {
    final recents = RecentFoods();
    await recents.record([food('Bagel', 48, at: now.subtract(const Duration(hours: 2)))], now);
    await recents.record([food('Banana', 27)], now);
    expect((await recents.load(now)).map((f) => f.name), ['Banana', 'Bagel']);
  });

  test('logging the same name again keeps only the newest copy', () async {
    final recents = RecentFoods();
    await recents.record([food('Pho', 13.7, at: now.subtract(const Duration(hours: 1)))], now);
    await recents.record([food('  pho ', 27.4)], now);
    final loaded = await recents.load(now);
    expect(loaded.length, 1);
    expect(loaded.single.carbs, 27.4);
  });

  test('keeps the logged food data', () async {
    final recents = RecentFoods();
    final logged = FoodItem(
        name: 'Toast', carbs: 14.5, protein: 3, details: 'USDA', isManualEntry: true);
    await recents.record([logged], now);
    final loaded = (await recents.load(now)).single;
    expect(loaded.protein, 3);
    expect(loaded.details, 'USDA');
    expect(loaded.isManualEntry, isTrue);
  });

  test('drops foods older than 30 days', () async {
    final recents = RecentFoods();
    await recents.record([food('Old', 10, at: now.subtract(const Duration(days: 31)))], now);
    await recents.record([food('Fresh', 10, at: now.subtract(const Duration(days: 29)))], now);
    expect((await recents.load(now)).map((f) => f.name), ['Fresh']);
  });

  test('keeps at most 20, dropping the oldest', () async {
    final recents = RecentFoods();
    for (var i = 0; i < 25; i++) {
      await recents.record([food('f$i', 1, at: now.add(Duration(minutes: i)))], now);
    }
    final loaded = await recents.load(now.add(const Duration(hours: 1)));
    expect(loaded.length, RecentFoods.maxEntries);
    expect(loaded.first.name, 'f24');
    expect(loaded.last.name, 'f5');
  });

  test('remove forgets a name', () async {
    final recents = RecentFoods();
    await recents.record([food('Bagel', 48), food('Banana', 27)], now);
    await recents.remove(' BAGEL');
    expect((await recents.load(now)).map((f) => f.name), ['Banana']);
  });

  test('removeSource forgets the entry a deleted food created', () async {
    final recents = RecentFoods();
    final wrong = food('Mystery stew', 80);
    await recents.record([wrong, food('Banana', 27)], now);
    await recents.removeSource(wrong.id);
    expect((await recents.load(now)).map((f) => f.name), ['Banana']);
  });

  test('corrupt storage loads as empty', () async {
    SharedPreferences.setMockInitialValues({StorageKeys.recentFoods: 'not json'});
    expect(await RecentFoods().load(now), isEmpty);
  });
}
