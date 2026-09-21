import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_keys.dart';
import '../models/food_item.dart';
import 'sync_merge.dart';
import 'sync_payload.dart';

/// Reads and writes the synced state in SharedPreferences, and records the
/// local changes that merging needs to know about (what was deleted, when
/// favourites changed, when settings changed).
class SyncStore {
  SyncStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// This device's state for [dayKey]. Food items are only today's: a stored
  /// list from an earlier day is ignored, the same way the app does on launch.
  Future<SyncState> read(String dayKey) async {
    final prefs = await _prefs;
    final storedDay = prefs.getString(StorageKeys.lastSaveDate);
    final isToday = storedDay == dayKey;
    return SyncState(
      dayKey: dayKey,
      items: isToday
          ? parseFoodItems(prefs.getString(StorageKeys.foodItems))
          : const [],
      deletedItemIds: isToday
          ? parseIdList(prefs.getString(StorageKeys.foodItemsDeleted))
          : const {},
      favorites: parseFoodItems(prefs.getString(StorageKeys.savedFoods)),
      favoriteChanges:
          parseFavoriteChanges(prefs.getString(StorageKeys.savedFoodsChanges)),
      settings: SyncSettings(
        dailyCarbGoal: prefs.getDouble(StorageKeys.dailyCarbGoal),
        proteinGoal: prefs.getDouble(StorageKeys.proteinGoal),
        fatGoal: prefs.getDouble(StorageKeys.fatGoal),
        fiberGoal: prefs.getDouble(StorageKeys.fiberGoal),
        caloriesGoal: prefs.getDouble(StorageKeys.caloriesGoal),
        resetHour: prefs.getInt(StorageKeys.dailyResetHour) ?? 0,
        // Absent means this device has never changed its settings, so the
        // cloud's win however old they are.
        updatedAt: _readSettingsUpdatedAt(prefs),
      ),
    );
  }

  /// Saves a merged state: items and favourites, what was deleted, and the
  /// settings that won.
  Future<void> write(SyncState state) async {
    final prefs = await _prefs;
    await prefs.setString(StorageKeys.foodItems,
        jsonEncode(state.items.map((f) => f.toJson()).toList()));
    await prefs.setString(StorageKeys.lastSaveDate, state.dayKey);
    await _writeIds(prefs, state.deletedItemIds);
    await prefs.setString(StorageKeys.savedFoods,
        jsonEncode(state.favorites.map((f) => f.toJson()).toList()));
    await _writeChanges(prefs, state.favoriteChanges);
    await _writeGoal(
        prefs, StorageKeys.dailyCarbGoal, state.settings.dailyCarbGoal);
    await _writeGoal(
        prefs, StorageKeys.proteinGoal, state.settings.proteinGoal);
    await _writeGoal(prefs, StorageKeys.fatGoal, state.settings.fatGoal);
    await _writeGoal(prefs, StorageKeys.fiberGoal, state.settings.fiberGoal);
    await _writeGoal(
        prefs, StorageKeys.caloriesGoal, state.settings.caloriesGoal);
    await prefs.setInt(StorageKeys.dailyResetHour, state.settings.resetHour);
    final updatedAt = state.settings.updatedAt;
    if (updatedAt != null) {
      await prefs.setInt(
          StorageKeys.settingsUpdatedAt, updatedAt.millisecondsSinceEpoch);
    }
  }

  /// Marks items as deleted today so another device's copy doesn't restore them.
  Future<void> recordItemsDeleted(Iterable<String> ids) async {
    final prefs = await _prefs;
    await _writeIds(prefs, {
      ...parseIdList(prefs.getString(StorageKeys.foodItemsDeleted)),
      ...ids
    });
  }

  /// Undo: the item is wanted again, so drop its delete marker.
  Future<void> recordItemRestored(String id) async {
    final prefs = await _prefs;
    await _writeIds(prefs,
        parseIdList(prefs.getString(StorageKeys.foodItemsDeleted))..remove(id));
  }

  /// Clears today's items and their delete markers (a new day starts fresh).
  Future<void> clearDay() async {
    final prefs = await _prefs;
    await prefs.remove(StorageKeys.foodItems);
    await prefs.remove(StorageKeys.foodItemsDeleted);
  }

  Future<void> recordFavoriteAdded(String name) =>
      _recordFavorite(name, deleted: false);

  Future<void> recordFavoriteRemoved(String name) =>
      _recordFavorite(name, deleted: true);

  Future<void> recordFavoritesCleared(Iterable<FoodItem> favorites) async {
    for (final favorite in favorites) {
      await _recordFavorite(favorite.name, deleted: true);
    }
  }

  /// Records that the user changed goals or the reset hour here, so this
  /// device's settings win over older ones from another device.
  Future<void> markSettingsChanged() async {
    final prefs = await _prefs;
    await prefs.setInt(
        StorageKeys.settingsUpdatedAt, _clock().millisecondsSinceEpoch);
  }

  Future<void> _recordFavorite(String name, {required bool deleted}) async {
    final prefs = await _prefs;
    final changes = {
      ...parseFavoriteChanges(prefs.getString(StorageKeys.savedFoodsChanges)),
      favoriteKey(name): FavoriteChange(updatedAt: _clock(), deleted: deleted),
    };
    await _writeChanges(prefs, changes);
  }

  DateTime? _readSettingsUpdatedAt(SharedPreferences prefs) {
    final ms = prefs.getInt(StorageKeys.settingsUpdatedAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> _writeIds(SharedPreferences prefs, Set<String> ids) =>
      prefs.setString(
          StorageKeys.foodItemsDeleted, jsonEncode(ids.toList()..sort()));

  Future<void> _writeChanges(
          SharedPreferences prefs, Map<String, FavoriteChange> changes) =>
      prefs.setString(
          StorageKeys.savedFoodsChanges,
          jsonEncode(
              {for (final e in changes.entries) e.key: e.value.toJson()}));

  Future<void> _writeGoal(SharedPreferences prefs, String key, double? value) =>
      value == null ? prefs.remove(key) : prefs.setDouble(key, value);
}
