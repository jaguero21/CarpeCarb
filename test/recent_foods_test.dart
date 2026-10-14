import 'dart:convert';

import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/serving_info.dart';
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

  test('an entry is gone on load once it is over 30 days old', () async {
    final recents = RecentFoods();
    await recents.record([food('Banana', 27, at: now.subtract(const Duration(days: 29)))], now);
    expect((await recents.load(now)).map((f) => f.name), ['Banana']);
    expect(await recents.load(now.add(const Duration(days: 2))), isEmpty);
  });

  test('citations and serving survive a round trip', () async {
    const cup = ServingPortion(id: 'p1', label: '1 cup', grams: 245);
    final logged = FoodItem(
      name: 'Pho',
      carbs: 13.7,
      citations: ['https://x'],
      serving: ServingInfo.usda(
        fdcId: 2707124,
        portions: const [cup],
        per100g: const Nutrients(carbs: 5.6, protein: 5.81),
        portionId: 'p1',
        count: 1,
      ),
    );
    final recents = RecentFoods();
    await recents.record([logged], now);
    final loaded = (await recents.load(now)).single;
    expect(loaded.citations, ['https://x']);
    expect(loaded.serving!.toJson(), logged.serving!.toJson());
    expect(loaded.serving!.rowLabel(), '1 cup (245 g)');
  });

  group('updateSource', () {
    test('replaces the food of the entry it created and keeps its place', () async {
      final recents = RecentFoods();
      final pho = food('Pho', 13.7, at: now.subtract(const Duration(hours: 2)));
      await recents.record([pho], now);
      await recents.record([food('Banana', 27, at: now.subtract(const Duration(hours: 1)))], now);

      // The edit keeps the id; its own loggedAt must not move the entry.
      final edited = FoodItem(id: pho.id, name: 'Pho', carbs: 41.2, loggedAt: now);
      await recents.updateSource(edited);

      final loaded = await recents.load(now);
      expect(loaded.map((f) => f.name), ['Banana', 'Pho']);
      expect(loaded.last.carbs, 41.2);
    });

    test('does nothing when no entry came from that food', () async {
      final recents = RecentFoods();
      await recents.record([food('Banana', 27)], now);
      await recents.updateSource(FoodItem(name: 'Banana', carbs: 99));
      expect((await recents.load(now)).single.carbs, 27);
    });

    test('never brings back a removed recent', () async {
      final recents = RecentFoods();
      final pho = food('Pho', 13.7);
      await recents.record([pho], now);
      await recents.remove('Pho');
      await recents.updateSource(FoodItem(id: pho.id, name: 'Pho', carbs: 41.2));
      expect(await recents.load(now), isEmpty);
    });
  });

  group('quick-add entries', () {
    test('removeSource keeps an entry a chip created and removes a normal one', () async {
      final recents = RecentFoods();
      final fromChip = food('Oatmeal', 27);
      final fromLookup = food('Mystery stew', 80);
      await recents.record([fromChip], now, quickAdd: true);
      await recents.record([fromLookup], now);
      await recents.removeSource(fromChip.id);
      await recents.removeSource(fromLookup.id);
      expect((await recents.load(now)).map((f) => f.name), ['Oatmeal']);
    });

    test('logging a name again takes the flag from the newest call', () async {
      final recents = RecentFoods();
      await recents.record([food('Pho', 13.7)], now, quickAdd: true);
      final again = food('Pho', 27.4);
      await recents.record([again], now);
      await recents.removeSource(again.id);
      expect(await recents.load(now), isEmpty);
    });

    test('an entry stored without the flag reads as a normal one', () async {
      final old = food('Pho', 13.7);
      SharedPreferences.setMockInitialValues({
        StorageKeys.recentFoods: jsonEncode([
          {
            'food': old.toJson(),
            'sourceId': old.id,
            'lastLoggedAt': now.toUtc().toIso8601String(),
          },
        ]),
      });
      final recents = RecentFoods();
      await recents.removeSource(old.id);
      expect(await recents.load(now), isEmpty);
    });
  });

  test('corrupt storage loads as empty', () async {
    SharedPreferences.setMockInitialValues({StorageKeys.recentFoods: 'not json'});
    expect(await RecentFoods().load(now), isEmpty);
  });
}
