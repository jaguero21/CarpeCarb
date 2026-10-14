import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_keys.dart';
import '../models/food_item.dart';

/// Foods logged lately, so the quick-add row can log them again in one tap.
///
/// One entry per name: logging a food again replaces its entry, so a changed
/// serving carries forward. Stored on this device only; saved foods are what
/// sync.
class RecentFoods {
  static const int maxEntries = 20;
  static const Duration keepFor = Duration(days: 30);

  static String _nameKey(String name) => name.trim().toLowerCase();

  /// Recent foods, newest first, without any older than [keepFor].
  Future<List<FoodItem>> load(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    return [for (final entry in _fresh(_read(prefs), now)) entry.food];
  }

  /// Records [items] as just logged.
  Future<void> record(Iterable<FoodItem> items, DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _read(prefs);
    for (final item in items) {
      entries.removeWhere((e) => _nameKey(e.food.name) == _nameKey(item.name));
      entries.add(_RecentEntry(item, sourceId: item.id, lastLoggedAt: item.loggedAt));
    }
    await _write(prefs, _fresh(entries, now).take(maxEntries).toList());
  }

  /// Forgets [name] (the quick-add row's "Remove from recents").
  Future<void> remove(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _read(prefs)
      ..removeWhere((e) => _nameKey(e.food.name) == _nameKey(name));
    await _write(prefs, entries);
  }

  /// Forgets the entry that the logged food [foodId] created. A food deleted
  /// the same day was probably a wrong lookup, not one to offer again.
  Future<void> removeSource(String foodId) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _read(prefs)..removeWhere((e) => e.sourceId == foodId);
    await _write(prefs, entries);
  }

  /// Newest first, without expired entries.
  List<_RecentEntry> _fresh(List<_RecentEntry> entries, DateTime now) {
    final cutoff = now.subtract(keepFor);
    return entries.where((e) => !e.lastLoggedAt.isBefore(cutoff)).toList()
      ..sort((a, b) => b.lastLoggedAt.compareTo(a.lastLoggedAt));
  }

  List<_RecentEntry> _read(SharedPreferences prefs) {
    final raw = prefs.getString(StorageKeys.recentFoods);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final e in decoded.whereType<Map<String, dynamic>>())
          if (_RecentEntry.tryFromJson(e) case final entry?) entry,
      ];
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to decode recent_foods: $e');
      return [];
    }
  }

  Future<void> _write(SharedPreferences prefs, List<_RecentEntry> entries) =>
      prefs.setString(StorageKeys.recentFoods,
          jsonEncode([for (final e in entries) e.toJson()]));
}

class _RecentEntry {
  _RecentEntry(this.food, {required this.sourceId, required this.lastLoggedAt});

  final FoodItem food;
  final String sourceId;
  final DateTime lastLoggedAt;

  Map<String, dynamic> toJson() => {
        'food': food.toJson(),
        'sourceId': sourceId,
        'lastLoggedAt': lastLoggedAt.toUtc().toIso8601String(),
      };

  static _RecentEntry? tryFromJson(Map<String, dynamic> json) {
    try {
      final at = DateTime.tryParse(json['lastLoggedAt'] as String? ?? '');
      final sourceId = json['sourceId'];
      if (at == null || sourceId is! String) return null;
      return _RecentEntry(
        FoodItem.fromJson(json['food'] as Map<String, dynamic>),
        sourceId: sourceId,
        lastLoggedAt: at,
      );
    } catch (_) {
      return null;
    }
  }
}
