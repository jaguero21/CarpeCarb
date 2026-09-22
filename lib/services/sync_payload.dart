import 'dart:convert';

import '../config/storage_keys.dart';
import '../models/food_item.dart';
import 'sync_merge.dart';

/// Converts between a [SyncState] and the flat key-value payload that goes in
/// and out of iCloud (NSUbiquitousKeyValueStore, via CloudSyncStore.swift).
///
/// Payloads written by builds before delete tracking have no
/// `food_items_deleted`, `saved_foods_changes` or `settings_updated_at`; those
/// read as "nothing deleted", "no changes recorded" and "changed long ago", so
/// an updated device still merges with them sensibly.

Map<String, dynamic> encodeSyncPayload(SyncState state,
    {required DateTime timestamp}) {
  String itemsJson(List<FoodItem> items) =>
      jsonEncode(items.map((f) => f.toJson()).toList());

  return {
    StorageKeys.foodItems: itemsJson(state.items),
    StorageKeys.foodItemsDeleted:
        jsonEncode(state.deletedItemIds.toList()..sort()),
    StorageKeys.savedFoods: itemsJson(state.favorites),
    StorageKeys.savedFoodsChanges: jsonEncode({
      for (final entry in state.favoriteChanges.entries)
        entry.key: entry.value.toJson(),
    }),
    StorageKeys.dailyCarbGoal: state.settings.dailyCarbGoal ?? 0.0,
    StorageKeys.proteinGoal: state.settings.proteinGoal ?? 0.0,
    StorageKeys.fatGoal: state.settings.fatGoal ?? 0.0,
    StorageKeys.fiberGoal: state.settings.fiberGoal ?? 0.0,
    StorageKeys.caloriesGoal: state.settings.caloriesGoal ?? 0.0,
    StorageKeys.dailyResetHour: state.settings.resetHour,
    StorageKeys.settingsUpdatedAt:
        state.settings.updatedAt?.millisecondsSinceEpoch ?? 0,
    StorageKeys.lastSaveDate: state.dayKey,
    StorageKeys.cloudLastModified: timestamp.toIso8601String(),
  };
}

SyncState decodeSyncPayload(Map<String, dynamic> data) {
  final settingsAt = data[StorageKeys.settingsUpdatedAt];
  return SyncState(
    dayKey: data[StorageKeys.lastSaveDate] is String
        ? data[StorageKeys.lastSaveDate] as String
        : '',
    items: parseFoodItems(data[StorageKeys.foodItems]),
    deletedItemIds: parseIdList(data[StorageKeys.foodItemsDeleted]),
    favorites: parseFoodItems(data[StorageKeys.savedFoods]),
    favoriteChanges: parseFavoriteChanges(data[StorageKeys.savedFoodsChanges]),
    settings: SyncSettings(
      dailyCarbGoal: _goal(data[StorageKeys.dailyCarbGoal]),
      proteinGoal: _goal(data[StorageKeys.proteinGoal]),
      fatGoal: _goal(data[StorageKeys.fatGoal]),
      fiberGoal: _goal(data[StorageKeys.fiberGoal]),
      caloriesGoal: _goal(data[StorageKeys.caloriesGoal]),
      resetHour: data[StorageKeys.dailyResetHour] is num
          ? (data[StorageKeys.dailyResetHour] as num).toInt()
          : 0,
      // A payload from an older build has no timestamp: treat its settings as
      // changed long ago, so a device that never changed its own adopts them.
      updatedAt: settingsAt is num
          ? DateTime.fromMillisecondsSinceEpoch(settingsAt.toInt())
          : DateTime.fromMillisecondsSinceEpoch(0),
    ),
  );
}

/// Parses a JSON list of food items, skipping anything malformed.
List<FoodItem> parseFoodItems(Object? json) {
  if (json is! String || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => FoodItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Parses a JSON list of item ids.
Set<String> parseIdList(Object? json) {
  if (json is! String || json.isEmpty) return const {};
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const {};
    return decoded.whereType<String>().toSet();
  } catch (_) {
    return const {};
  }
}

/// Parses the favourite change map, skipping anything malformed.
Map<String, FavoriteChange> parseFavoriteChanges(Object? json) {
  if (json is! String || json.isEmpty) return const {};
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return const {};
    final changes = <String, FavoriteChange>{};
    decoded.forEach((key, value) {
      final change = FavoriteChange.fromJson(value);
      if (key is String && change != null) changes[key] = change;
    });
    return changes;
  } catch (_) {
    return const {};
  }
}

double? _goal(Object? value) {
  if (value is! num) return null;
  final goal = value.toDouble();
  return goal > 0 ? goal : null;
}
