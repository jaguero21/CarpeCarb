import 'dart:convert';

import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/sync_merge.dart';
import 'package:carb_tracker/services/sync_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final loggedAt = DateTime(2026, 9, 20, 8, 30);
  final changedAt = DateTime(2026, 9, 20, 9);
  final pushedAt = DateTime(2026, 9, 20, 12);

  final state = SyncState(
    dayKey: '2026-09-20',
    items: [FoodItem(id: 'a', name: 'Apple', carbs: 25, loggedAt: loggedAt)],
    deletedItemIds: const {'b', 'c'},
    favorites: [
      FoodItem(id: 'f1', name: 'Bagel', carbs: 48, loggedAt: loggedAt)
    ],
    favoriteChanges: {
      'bagel': FavoriteChange(updatedAt: changedAt, deleted: false)
    },
    settings: SyncSettings(
      dailyCarbGoal: 100,
      proteinGoal: 60,
      resetHour: 4,
      updatedAt: changedAt,
    ),
  );

  test('encode then decode round-trips everything that syncs', () {
    final decoded =
        decodeSyncPayload(encodeSyncPayload(state, timestamp: pushedAt));

    expect(decoded.dayKey, '2026-09-20');
    expect(decoded.items.single.name, 'Apple');
    expect(decoded.items.single.loggedAt, loggedAt);
    expect(decoded.deletedItemIds, {'b', 'c'});
    expect(decoded.favorites.single.name, 'Bagel');
    expect(decoded.favoriteChanges['bagel']!.updatedAt, changedAt);
    expect(decoded.favoriteChanges['bagel']!.deleted, isFalse);
    expect(decoded.settings.dailyCarbGoal, 100);
    expect(decoded.settings.proteinGoal, 60);
    expect(decoded.settings.fatGoal, isNull);
    expect(decoded.settings.resetHour, 4);
    expect(decoded.settings.updatedAt, changedAt);
  });

  test('a re-encoded payload is identical, so pushing back settles', () {
    final first = encodeSyncPayload(state, timestamp: pushedAt);
    final second =
        encodeSyncPayload(decodeSyncPayload(first), timestamp: pushedAt);
    expect(second, first);
  });

  test('the payload carries the push timestamp for the native pull', () {
    final payload = encodeSyncPayload(state, timestamp: pushedAt);
    expect(payload[StorageKeys.cloudLastModified], pushedAt.toIso8601String());
  });

  test('an unset goal is sent as 0 and read back as unset', () {
    final payload = encodeSyncPayload(
      SyncState(
        dayKey: '2026-09-20',
        items: const [],
        deletedItemIds: const {},
        favorites: const [],
        favoriteChanges: const {},
        settings: const SyncSettings(),
      ),
      timestamp: pushedAt,
    );
    expect(payload[StorageKeys.dailyCarbGoal], 0.0);
    expect(decodeSyncPayload(payload).settings.dailyCarbGoal, isNull);
  });

  test(
      'a payload from an older build decodes with no deletes and stale settings',
      () {
    final decoded = decodeSyncPayload({
      StorageKeys.foodItems: jsonEncode([
        FoodItem(id: 'a', name: 'Apple', carbs: 25, loggedAt: loggedAt)
            .toJson(),
      ]),
      StorageKeys.savedFoods: jsonEncode([
        FoodItem(id: 'f1', name: 'Bagel', carbs: 48, loggedAt: loggedAt)
            .toJson(),
      ]),
      StorageKeys.dailyCarbGoal: 100.0,
      StorageKeys.dailyResetHour: 0,
      StorageKeys.lastSaveDate: '2026-09-20',
      StorageKeys.cloudLastModified: pushedAt.toIso8601String(),
    });

    expect(decoded.items.single.name, 'Apple');
    expect(decoded.deletedItemIds, isEmpty);
    expect(decoded.favorites.single.name, 'Bagel');
    expect(decoded.favoriteChanges, isEmpty);
    expect(decoded.settings.dailyCarbGoal, 100);
    // Epoch 0: any real change on this device beats the old build's settings.
    expect(decoded.settings.updatedAt, DateTime.fromMillisecondsSinceEpoch(0));
  });

  test('an empty payload decodes to an empty state rather than throwing', () {
    final decoded = decodeSyncPayload(const {});
    expect(decoded.dayKey, '');
    expect(decoded.items, isEmpty);
    expect(decoded.favorites, isEmpty);
    expect(decoded.settings.resetHour, 0);
  });

  test('a section that cannot be parsed is skipped, not fatal', () {
    final decoded = decodeSyncPayload({
      StorageKeys.foodItems: 'not json',
      StorageKeys.foodItemsDeleted: jsonEncode({'not': 'a list'}),
      StorageKeys.savedFoodsChanges: jsonEncode({'bagel': 'not a change'}),
      StorageKeys.savedFoods: jsonEncode([
        FoodItem(id: 'f1', name: 'Bagel', carbs: 48, loggedAt: loggedAt)
            .toJson(),
      ]),
      StorageKeys.lastSaveDate: '2026-09-20',
    });

    expect(decoded.items, isEmpty);
    expect(decoded.deletedItemIds, isEmpty);
    expect(decoded.favoriteChanges, isEmpty);
    expect(decoded.favorites.single.name, 'Bagel');
  });
}
