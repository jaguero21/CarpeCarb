import 'dart:convert';

import '../models/food_item.dart';
import '../utils/day_key.dart';

/// Parses the `siriLoggedItems` buffer that Siri writes to the App Group
/// (`CarbDataStore.addFood` in ios/CarbShared) and splits it by day.
class SiriImport {
  SiriImport._();

  /// [today] items join today's list; [earlier] items were logged on a
  /// previous day (the app wasn't opened since) and only go to Apple Health.
  /// Items with a missing, unparseable, or future `loggedAt` count as today.
  /// Entries without a string `name` are skipped.
  ///
  /// Throws [FormatException] if [json] isn't a JSON list.
  static ({List<FoodItem> today, List<FoodItem> earlier}) parse(
      String json, DateTime now, int resetHour) {
    final decoded = jsonDecode(json);
    if (decoded is! List) {
      throw const FormatException('siriLoggedItems is not a JSON list');
    }

    final todayKey = dayKey(now, resetHour);
    final today = <FoodItem>[];
    final earlier = <FoodItem>[];

    for (final raw in decoded.whereType<Map>()) {
      final name = raw['name'];
      if (name is! String) continue;

      final loggedAtRaw = raw['loggedAt'];
      // Siri writes UTC ISO-8601; day keys are in local time.
      final loggedAt =
          loggedAtRaw is String ? DateTime.tryParse(loggedAtRaw)?.toLocal() : null;
      final details = raw['details'];
      final citations = raw['citations'];

      final item = FoodItem(
        name: name,
        carbs: _number(raw['carbs']) ?? 0.0,
        protein: _number(raw['protein']),
        fat: _number(raw['fat']),
        fiber: _number(raw['fiber']),
        calories: _number(raw['calories']),
        details: details is String ? details : null,
        citations:
            citations is List ? citations.whereType<String>().toList() : const [],
        loggedAt: loggedAt ?? now,
      );

      final isEarlier =
          loggedAt != null && dayKey(loggedAt, resetHour).compareTo(todayKey) < 0;
      (isEarlier ? earlier : today).add(item);
    }
    return (today: today, earlier: earlier);
  }

  static double? _number(Object? value) => value is num ? value.toDouble() : null;
}
