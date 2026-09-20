import 'dart:convert';

import '../models/food_item.dart';

/// The key a favourite is tracked under: its name, trimmed and lower-cased
/// (the same rule the app already uses to dedupe favourites).
String favoriteKey(String name) => name.trim().toLowerCase();

/// A favourite's most recent add or delete, so devices can agree on which
/// happened last instead of unioning their lists (which resurrected deletes).
class FavoriteChange {
  const FavoriteChange({required this.updatedAt, required this.deleted});

  final DateTime updatedAt;
  final bool deleted;

  /// Favourites saved before this existed count as added long ago, so any
  /// real change on either device beats them.
  static final FavoriteChange legacyAdd = FavoriteChange(
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0), deleted: false);

  /// True when this change should win over [other]. A delete wins a tie so a
  /// deletion is never lost, and both devices decide the same way.
  bool beats(FavoriteChange other) {
    if (updatedAt.isAfter(other.updatedAt)) return true;
    if (other.updatedAt.isAfter(updatedAt)) return false;
    return deleted && !other.deleted;
  }

  Map<String, dynamic> toJson() =>
      {'updatedAt': updatedAt.millisecondsSinceEpoch, 'deleted': deleted};

  static FavoriteChange? fromJson(Object? json) {
    if (json is! Map) return null;
    final updatedAt = json['updatedAt'];
    if (updatedAt is! int) return null;
    return FavoriteChange(
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt),
      deleted: json['deleted'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FavoriteChange &&
      other.updatedAt == updatedAt &&
      other.deleted == deleted;

  @override
  int get hashCode => Object.hash(updatedAt, deleted);
}

/// Goals and the daily reset hour, with when the user last changed them on
/// this device. [updatedAt] is null when they have never been changed here.
class SyncSettings {
  const SyncSettings({
    this.dailyCarbGoal,
    this.proteinGoal,
    this.fatGoal,
    this.fiberGoal,
    this.caloriesGoal,
    this.resetHour = 0,
    this.updatedAt,
  });

  final double? dailyCarbGoal;
  final double? proteinGoal;
  final double? fatGoal;
  final double? fiberGoal;
  final double? caloriesGoal;
  final int resetHour;
  final DateTime? updatedAt;

  SyncSettings copyWith({DateTime? updatedAt}) => SyncSettings(
        dailyCarbGoal: dailyCarbGoal,
        proteinGoal: proteinGoal,
        fatGoal: fatGoal,
        fiberGoal: fiberGoal,
        caloriesGoal: caloriesGoal,
        resetHour: resetHour,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is SyncSettings &&
      other.dailyCarbGoal == dailyCarbGoal &&
      other.proteinGoal == proteinGoal &&
      other.fatGoal == fatGoal &&
      other.fiberGoal == fiberGoal &&
      other.caloriesGoal == caloriesGoal &&
      other.resetHour == resetHour &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(dailyCarbGoal, proteinGoal, fatGoal,
      fiberGoal, caloriesGoal, resetHour, updatedAt);
}

/// Everything that syncs between devices.
class SyncState {
  const SyncState({
    required this.dayKey,
    this.items = const [],
    this.deletedItemIds = const {},
    this.favorites = const [],
    this.favoriteChanges = const {},
    this.settings = const SyncSettings(),
  });

  /// The day [items] belong to (`last_save_date`).
  final String dayKey;
  final List<FoodItem> items;
  final Set<String> deletedItemIds;
  final List<FoodItem> favorites;

  /// Favourite key → its most recent add or delete.
  final Map<String, FavoriteChange> favoriteChanges;
  final SyncSettings settings;

  SyncState copyWith({
    List<FoodItem>? items,
    Set<String>? deletedItemIds,
    List<FoodItem>? favorites,
    Map<String, FavoriteChange>? favoriteChanges,
    SyncSettings? settings,
  }) =>
      SyncState(
        dayKey: dayKey,
        items: items ?? this.items,
        deletedItemIds: deletedItemIds ?? this.deletedItemIds,
        favorites: favorites ?? this.favorites,
        favoriteChanges: favoriteChanges ?? this.favoriteChanges,
        settings: settings ?? this.settings,
      );
}

/// Merges what this device has with what came from iCloud.
///
/// Food items and favourites merge (so neither device loses an entry made
/// while they were apart) but respect deletions; goals and the reset hour are
/// whole-value, newest-change-wins.
SyncState mergeSyncState({
  required SyncState local,
  required SyncState cloud,
  required DateTime now,
  Duration tombstoneTtl = const Duration(days: 60),
}) {
  // ── Today's food items ──
  // A cloud payload about another day says nothing about today, so it is
  // ignored here: both its items and its deleted ids belong to that day.
  var items = local.items;
  var deletedItemIds = local.deletedItemIds;
  if (cloud.dayKey == local.dayKey) {
    deletedItemIds = {...local.deletedItemIds, ...cloud.deletedItemIds};
    final seen = <String>{};
    final merged = <FoodItem>[];
    for (final item in [...cloud.items, ...local.items]) {
      if (deletedItemIds.contains(item.id)) continue;
      if (seen.add(item.id)) merged.add(item);
    }
    // Newest first, with the id as a tie-break so both devices agree on the
    // order (an order that differed would push back and forth forever).
    merged.sort((a, b) {
      final byTime = b.loggedAt.compareTo(a.loggedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    items = merged;
  }

  // ── Favourites ──
  final localItems = {for (final f in local.favorites) favoriteKey(f.name): f};
  final cloudItems = {for (final f in cloud.favorites) favoriteKey(f.name): f};
  final changes = <String, FavoriteChange>{};
  final favorites = <FoodItem>[];
  final keys = <String>{
    ...local.favoriteChanges.keys,
    ...cloud.favoriteChanges.keys,
    ...localItems.keys,
    ...cloudItems.keys,
  }.toList()
    ..sort();

  for (final key in keys) {
    final localChange = local.favoriteChanges[key] ??
        (localItems.containsKey(key) ? FavoriteChange.legacyAdd : null);
    final cloudChange = cloud.favoriteChanges[key] ??
        (cloudItems.containsKey(key) ? FavoriteChange.legacyAdd : null);
    final FavoriteChange winner;
    if (localChange == null) {
      if (cloudChange == null) continue;
      winner = cloudChange;
    } else if (cloudChange == null) {
      winner = localChange;
    } else {
      winner = cloudChange.beats(localChange) ? cloudChange : localChange;
    }

    if (winner.deleted) {
      // Keep the delete around long enough for a device that has been away to
      // see it, then forget it.
      if (now.difference(winner.updatedAt) < tombstoneTtl) {
        changes[key] = winner;
      }
      continue;
    }
    final item = (winner == cloudChange ? cloudItems[key] : localItems[key]) ??
        localItems[key] ??
        cloudItems[key];
    if (item == null) continue;
    favorites.add(item);
    if (winner.updatedAt.millisecondsSinceEpoch > 0) changes[key] = winner;
  }

  // ── Goals and reset hour: newest change wins ──
  final localAt = local.settings.updatedAt;
  final cloudAt = cloud.settings.updatedAt;
  final takeCloud =
      cloudAt != null && (localAt == null || cloudAt.isAfter(localAt));

  return SyncState(
    dayKey: local.dayKey,
    items: items,
    deletedItemIds: deletedItemIds,
    favorites: favorites,
    favoriteChanges: changes,
    settings: takeCloud ? cloud.settings : local.settings,
  );
}

/// What two states must agree on for a device to stop pushing. Deliberately
/// excludes `cloud_last_modified`, which changes on every push.
String canonicalSyncJson(SyncState state) {
  String itemsJson(List<FoodItem> list) =>
      jsonEncode(list.map((f) => f.toJson()).toList());
  final changeKeys = state.favoriteChanges.keys.toList()..sort();
  return jsonEncode({
    'day': state.dayKey,
    'items': itemsJson(state.items),
    'deleted': state.deletedItemIds.toList()..sort(),
    'favorites': itemsJson(state.favorites),
    'changes': {
      for (final k in changeKeys) k: state.favoriteChanges[k]!.toJson()
    },
    'settings': {
      'carbs': state.settings.dailyCarbGoal,
      'protein': state.settings.proteinGoal,
      'fat': state.settings.fatGoal,
      'fiber': state.settings.fiberGoal,
      'calories': state.settings.caloriesGoal,
      'resetHour': state.settings.resetHour,
      'updatedAt': state.settings.updatedAt?.millisecondsSinceEpoch,
    },
  });
}

/// True when [a] holds anything [b] doesn't (so the merge is worth pushing).
bool syncStateDiffers(SyncState a, SyncState b) =>
    canonicalSyncJson(a) != canonicalSyncJson(b);
