import 'dart:convert';

import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/sync_merge.dart';
import 'package:carb_tracker/services/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const today = '2026-09-20';
  final loggedAt = DateTime(2026, 9, 20, 8, 30);
  final clock = DateTime(2026, 9, 20, 12);
  final store = SyncStore(clock: () => clock);

  FoodItem item(String id, String name) =>
      FoodItem(id: id, name: name, carbs: 20, loggedAt: loggedAt);

  String itemsJson(List<FoodItem> items) =>
      jsonEncode(items.map((f) => f.toJson()).toList());

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  group('read', () {
    test('reads today\'s items, favourites and settings', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.foodItems: itemsJson([item('a', 'Apple')]),
        StorageKeys.lastSaveDate: today,
        StorageKeys.foodItemsDeleted: jsonEncode(['b']),
        StorageKeys.savedFoods: itemsJson([item('f1', 'Bagel')]),
        StorageKeys.savedFoodsChanges: jsonEncode({
          'bagel': FavoriteChange(updatedAt: loggedAt, deleted: false).toJson()
        }),
        StorageKeys.dailyCarbGoal: 100.0,
        StorageKeys.dailyResetHour: 4,
        StorageKeys.settingsUpdatedAt: loggedAt.millisecondsSinceEpoch,
      });

      final state = await store.read(today);

      expect(state.items.single.name, 'Apple');
      expect(state.deletedItemIds, {'b'});
      expect(state.favorites.single.name, 'Bagel');
      expect(state.favoriteChanges['bagel']!.updatedAt, loggedAt);
      expect(state.settings.dailyCarbGoal, 100);
      expect(state.settings.resetHour, 4);
      expect(state.settings.updatedAt, loggedAt);
    });

    test('ignores items and deletes stored for an earlier day', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.foodItems: itemsJson([item('a', 'Apple')]),
        StorageKeys.lastSaveDate: '2026-09-19',
        StorageKeys.foodItemsDeleted: jsonEncode(['b']),
        StorageKeys.savedFoods: itemsJson([item('f1', 'Bagel')]),
      });

      final state = await store.read(today);

      expect(state.items, isEmpty);
      expect(state.deletedItemIds, isEmpty);
      // Favourites aren't tied to a day.
      expect(state.favorites.single.name, 'Bagel');
    });

    test('settings never changed here read as no timestamp', () async {
      final state = await store.read(today);
      expect(state.settings.updatedAt, isNull);
    });
  });

  group('write', () {
    test('saves the merged state, and read gives it back', () async {
      await store.write(SyncState(
        dayKey: today,
        items: [item('a', 'Apple')],
        deletedItemIds: const {'b'},
        favorites: [item('f1', 'Bagel')],
        favoriteChanges: {
          'bagel': FavoriteChange(updatedAt: loggedAt, deleted: false)
        },
        settings: SyncSettings(
          dailyCarbGoal: 100,
          resetHour: 4,
          updatedAt: loggedAt,
        ),
      ));

      final state = await store.read(today);

      expect(state.items.single.name, 'Apple');
      expect(state.deletedItemIds, {'b'});
      expect(state.favorites.single.name, 'Bagel');
      expect(state.favoriteChanges['bagel']!.updatedAt, loggedAt);
      expect(state.settings.dailyCarbGoal, 100);
      expect(state.settings.resetHour, 4);
      expect((await prefs()).getString(StorageKeys.lastSaveDate), today);
    });

    test('a goal the merge cleared is removed, not stored as 0', () async {
      SharedPreferences.setMockInitialValues({StorageKeys.proteinGoal: 60.0});

      await store.write(SyncState(
        dayKey: today,
        items: const [],
        deletedItemIds: const {},
        favorites: const [],
        favoriteChanges: const {},
        settings: const SyncSettings(),
      ));

      expect((await prefs()).getDouble(StorageKeys.proteinGoal), isNull);
    });

    test('leaves the settings timestamp alone when the merge has none',
        () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.settingsUpdatedAt: loggedAt.millisecondsSinceEpoch,
      });

      await store.write(SyncState(
        dayKey: today,
        items: const [],
        deletedItemIds: const {},
        favorites: const [],
        favoriteChanges: const {},
        settings: const SyncSettings(),
      ));

      expect((await prefs()).getInt(StorageKeys.settingsUpdatedAt),
          loggedAt.millisecondsSinceEpoch);
    });
  });

  group('recording local changes', () {
    test('deleted ids accumulate and undo removes one again', () async {
      SharedPreferences.setMockInitialValues({StorageKeys.lastSaveDate: today});

      await store.recordItemsDeleted(['a']);
      await store.recordItemsDeleted(['b', 'c']);
      expect((await store.read(today)).deletedItemIds, {'a', 'b', 'c'});

      await store.recordItemRestored('b');
      expect((await store.read(today)).deletedItemIds, {'a', 'c'});
    });

    test('clearDay drops today\'s items and their delete markers', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.foodItems: itemsJson([item('a', 'Apple')]),
        StorageKeys.lastSaveDate: today,
        StorageKeys.foodItemsDeleted: jsonEncode(['b']),
      });

      await store.clearDay();

      expect((await prefs()).getString(StorageKeys.foodItems), isNull);
      expect((await prefs()).getString(StorageKeys.foodItemsDeleted), isNull);
    });

    test('a favourite add and a remove are keyed by lower-cased name',
        () async {
      await store.recordFavoriteAdded('Bagel');
      await store.recordFavoriteRemoved('Greek Yogurt');

      final changes = (await store.read(today)).favoriteChanges;
      expect(changes['bagel']!.deleted, isFalse);
      expect(changes['bagel']!.updatedAt, clock);
      expect(changes['greek yogurt']!.deleted, isTrue);
    });

    test('re-adding a removed favourite records the newer add', () async {
      await store.recordFavoriteRemoved('Bagel');
      final later =
          SyncStore(clock: () => clock.add(const Duration(minutes: 5)));
      await later.recordFavoriteAdded('Bagel');

      final change = (await store.read(today)).favoriteChanges['bagel']!;
      expect(change.deleted, isFalse);
      expect(change.updatedAt, clock.add(const Duration(minutes: 5)));
    });

    test('resetting favourites records a delete for each one', () async {
      await store
          .recordFavoritesCleared([item('f1', 'Bagel'), item('f2', 'Apple')]);

      final changes = (await store.read(today)).favoriteChanges;
      expect(changes['bagel']!.deleted, isTrue);
      expect(changes['apple']!.deleted, isTrue);
    });

    test('upgrading stamps goals this device already had', () async {
      SharedPreferences.setMockInitialValues({StorageKeys.dailyCarbGoal: 100.0});

      await store.stampExistingSettings();

      // Real, but older than any deliberate change: a device with no goals
      // can't wipe these, and a genuine change anywhere still wins.
      expect((await store.read(today)).settings.updatedAt, migratedSettingsStamp);
    });

    test('a device with no goals keeps adopting the cloud\'s', () async {
      await store.stampExistingSettings();

      expect((await store.read(today)).settings.updatedAt, isNull);
    });

    test('a real change is never overwritten by the migration', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.dailyCarbGoal: 100.0,
        StorageKeys.settingsUpdatedAt: loggedAt.millisecondsSinceEpoch,
      });

      await store.stampExistingSettings();

      expect((await store.read(today)).settings.updatedAt, loggedAt);
    });

    test('markSettingsChanged stamps now', () async {
      await store.markSettingsChanged();
      expect((await store.read(today)).settings.updatedAt, clock);
    });
  });
}
