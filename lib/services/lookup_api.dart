import 'dart:convert';

import '../models/food_item.dart';
import '../models/server_quota.dart';
import '../utils/user_facing_exception.dart';

/// Result of one getMultipleCarbCounts call.
class LookupResult {
  const LookupResult({required this.items, this.quota});

  final List<FoodItem> items;

  /// Null when the server response has no `quota` (older deployment).
  final ServerQuota? quota;
}

/// Parses a 200 response body from the getMultipleCarbCounts callable.
/// Throws [UserFacingException] when the body has no usable items.
LookupResult parseLookupResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw const UserFacingException('No results returned. Please try again.');
  }
  final result = decoded is Map ? (decoded['result'] ?? decoded['data']) : null;
  if (result is! Map || result['items'] is! List) {
    throw const UserFacingException('No results returned. Please try again.');
  }

  final items = result['items'] as List;
  final citations = result['citations'] is List
      ? (result['citations'] as List).whereType<String>().toList()
      : <String>[];

  if (items.isEmpty) {
    throw const UserFacingException(
        'No food items found. Please try a different description.');
  }

  double? parseOptional(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  final foods = items.whereType<Map>().map((item) {
    final carbsRaw = item['carbs'];
    final carbs = carbsRaw is num
        ? carbsRaw.toDouble()
        : double.tryParse(carbsRaw.toString()) ?? 0.0;

    return FoodItem(
      name: (item['name'] as String?) ?? 'Unknown',
      carbs: carbs,
      protein: parseOptional(item['protein']),
      fat: parseOptional(item['fat']),
      fiber: parseOptional(item['fiber']),
      calories: parseOptional(item['calories']),
      details: item['details'] as String?,
      citations: citations,
    );
  }).toList();

  return LookupResult(items: foods, quota: ServerQuota.fromJson(result['quota']));
}

/// Maps a non-200 callable response to the exception the UI should show.
/// Callable errors have the body `{"error": {"message", "status", "details"}}`.
UserFacingException parseCallableError(int statusCode, String body) {
  Map? error;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['error'] is Map) error = decoded['error'] as Map;
  } on FormatException {
    error = null; // Non-JSON body (e.g. a proxy error page): use the fallbacks.
  }
  final details = error?['details'];

  if (statusCode == 429 && details is Map && details['reason'] == 'daily-quota') {
    final used = details['used'];
    final limit = details['limit'];
    final dayKey = details['dayKey'];
    return DailyLimitReachedException(
      used: used is int ? used : null,
      limit: limit is int ? limit : null,
      dayKey: dayKey is String ? dayKey : null,
    );
  }
  if (statusCode == 401 || statusCode == 403) {
    return const UserFacingException('Authentication error. Please restart the app.');
  }
  if (statusCode == 429) {
    return const UserFacingException('Rate limit exceeded. Please try again later.');
  }
  final message = error?['message'];
  if (message is String && message.isNotEmpty) return UserFacingException(message);
  return const UserFacingException('Failed to get carb count. Please try again.');
}
