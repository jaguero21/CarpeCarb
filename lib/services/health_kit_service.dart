import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import '../models/food_item.dart';

/// Service for reading/writing carb data to Apple HealthKit.
/// iOS only — all methods no-op on other platforms.
class HealthKitService {
  final Health _health = Health();
  bool _isAuthorized = false;

  static const List<HealthDataType> _types = [HealthDataType.NUTRITION];
  static const List<HealthDataAccess> _permissions = [
    HealthDataAccess.READ_WRITE,
  ];

  /// Request HealthKit authorization. Returns true if granted.
  Future<bool> requestAuthorization() async {
    if (!Platform.isIOS) return false;

    try {
      _isAuthorized = await _health.requestAuthorization(
        _types,
        permissions: _permissions,
      );
      return _isAuthorized;
    } catch (e) {
      debugPrint('HealthKit: authorization failed: $e');
      _isAuthorized = false;
      return false;
    }
  }

  /// Check if we have HealthKit permissions without prompting.
  Future<bool> hasPermissions() async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _health.hasPermissions(
        _types,
        permissions: _permissions,
      );
      _isAuthorized = result ?? false;
      return _isAuthorized;
    } catch (e) {
      debugPrint('HealthKit: hasPermissions check failed: $e');
      return false;
    }
  }

  /// Write a food item to HealthKit as a meal entry.
  /// Writes all available macros (carbs, protein, fat, fiber, calories)
  /// so Apple Health shows complete nutritional data for premium users.
  Future<bool> writeFoodItem(FoodItem item) async {
    if (!Platform.isIOS || !_isAuthorized) return false;

    try {
      final success = await _health.writeMeal(
        mealType: MealType.UNKNOWN,
        startTime: item.loggedAt,
        endTime: item.loggedAt.add(const Duration(minutes: 1)),
        name: item.name,
        recordingMethod: RecordingMethod.manual,
        carbohydrates: item.carbs,
        protein: item.protein,
        fatTotal: item.fat,
        fiber: item.fiber,
        caloriesConsumed: item.calories,
      );
      return success;
    } catch (e) {
      debugPrint('HealthKit: writeFoodItem failed for "${item.name}": $e');
      return false;
    }
  }

  /// Delete a food item from HealthKit: only the entry that starts in the
  /// millisecond [item] was logged (see [healthDeleteWindow]).
  Future<bool> deleteFoodItem(FoodItem item) async {
    if (!Platform.isIOS || !_isAuthorized) return false;

    try {
      final window = healthDeleteWindow(item.loggedAt);
      final success = await _health.delete(
        type: HealthDataType.NUTRITION,
        startTime: window.start,
        endTime: window.end,
      );
      return success;
    } catch (e) {
      debugPrint('HealthKit: deleteFoodItem failed for "${item.name}": $e');
      return false;
    }
  }

  /// Fetch all nutrition entries from HealthKit in the given date range.
  Future<List<HealthDataPoint>> fetchNutritionData({
    required DateTime start,
    required DateTime end,
  }) async {
    if (!Platform.isIOS) return [];

    if (!_isAuthorized) {
      final granted = await requestAuthorization();
      if (!granted) return [];
    }

    try {
      final dataPoints = await _health.getHealthDataFromTypes(
        types: _types,
        startTime: start,
        endTime: end,
      );
      return _health.removeDuplicates(dataPoints);
    } catch (e) {
      debugPrint('HealthKit: fetchNutritionData failed: $e');
      return [];
    }
  }

  /// Fetch carb history grouped by day.
  /// Returns a map of date (midnight) -> list of entries for that day.
  Future<Map<DateTime, List<Map<String, dynamic>>>> fetchDailyHistory({
    required int days,
  }) async {
    final now = DateTime.now();
    final start =
        DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
    final end = now;

    final dataPoints = await fetchNutritionData(start: start, end: end);

    final Map<DateTime, List<Map<String, dynamic>>> grouped = {};

    for (final point in dataPoints) {
      final date = DateTime(
        point.dateFrom.year,
        point.dateFrom.month,
        point.dateFrom.day,
      );

      final entry = <String, dynamic>{
        'time': point.dateFrom,
      };

      if (point.value is NutritionHealthValue) {
        final nutrition = point.value as NutritionHealthValue;
        entry['name'] = nutrition.name ?? 'Unknown';
        entry['carbs'] = nutrition.carbs ?? 0.0;
        entry['protein'] = nutrition.protein;
        entry['fat'] = nutrition.fat;
        entry['fiber'] = nutrition.fiber;
        entry['calories'] = nutrition.calories;
      } else {
        entry['name'] = 'Unknown';
        entry['carbs'] = 0.0;
      }

      grouped.putIfAbsent(date, () => []);
      grouped[date]!.add(entry);
    }

    return grouped;
  }
}

/// The time range a delete searches for the Health entry of a food logged at
/// [loggedAt]: exactly the millisecond it starts in.
///
/// The plugin's delete matches this app's own entries by start time only, and
/// the end is exclusive (HealthKit's `.strictStartDate` is `startDate >= start
/// AND startDate < end`). Every entry the app writes starts in its own
/// millisecond — foods from one lookup or one Siri log are spaced 1 ms apart —
/// so this matches one entry. The one-minute range it replaces took every food
/// logged in that minute, including the rest of a "burger and fries".
({DateTime start, DateTime end}) healthDeleteWindow(DateTime loggedAt) {
  // Whole milliseconds, which is what the plugin passes to HealthKit for both
  // the write and the delete, so the two agree.
  final start =
      DateTime.fromMillisecondsSinceEpoch(loggedAt.millisecondsSinceEpoch);
  return (start: start, end: start.add(const Duration(milliseconds: 1)));
}
