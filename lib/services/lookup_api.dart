import 'dart:convert';

import '../models/food_item.dart';
import '../models/server_quota.dart';
import '../utils/user_facing_exception.dart';

/// Result of one getMultipleCarbCounts call.
class LookupResult {
  const LookupResult({
    required this.items,
    this.unknownCarbs = const [],
    this.quota,
  });

  /// The foods the lookup found a carb value for, ready to log.
  final List<FoodItem> items;

  /// Names of foods the lookup couldn't find a reliable carb value for. They
  /// never become [FoodItem]s — a FoodItem always has a number, so nothing
  /// downstream can count an unknown as 0 g. The app hands them to Manual
  /// entry instead.
  final List<String> unknownCarbs;

  /// Null when the server response has no `quota` (older deployment).
  final ServerQuota? quota;
}

/// Parses a 200 response body from the getMultipleCarbCounts callable.
/// Throws [UserFacingException] when the body has no usable items.
///
/// [now] is when the foods are logged; tests pass a fixed time.
LookupResult parseLookupResponse(String body, {DateTime? now}) {
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

  // A missing, unreadable, negative or infinite value means the lookup has no
  // carb number for this food. It is never read as 0: a confident 0 g is worse
  // than no answer for someone dosing insulin.
  double? parseCarbs(dynamic v) {
    final value = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    return value != null && value.isFinite && value >= 0 ? value : null;
  }

  final base = now ?? DateTime.now();
  final foods = <FoodItem>[];
  final unknownCarbs = <String>[];
  for (final item in items.whereType<Map>()) {
    final name = (item['name'] as String?) ?? 'Unknown';
    final carbs = parseCarbs(item['carbs']);
    if (carbs == null) {
      unknownCarbs.add(name);
      continue;
    }
    foods.add(FoodItem(
      name: name,
      carbs: carbs,
      protein: parseOptional(item['protein']),
      fat: parseOptional(item['fat']),
      fiber: parseOptional(item['fiber']),
      calories: parseOptional(item['calories']),
      details: item['details'] as String?,
      citations: citations,
      // Each food from one lookup starts in its own millisecond, so deleting
      // one from Apple Health can't take the others with it: the delete
      // matches a single millisecond (HealthKitService.deleteFoodItem).
      loggedAt: base.add(Duration(milliseconds: foods.length)),
    ));
  }

  if (foods.isEmpty && unknownCarbs.isEmpty) {
    throw const UserFacingException(
        'No food items found. Please try a different description.');
  }

  return LookupResult(
    items: foods,
    unknownCarbs: unknownCarbs,
    quota: ServerQuota.fromJson(result['quota']),
  );
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
/// The `data` payload for one getMultipleCarbCounts call.
///
/// A pure function so the request can be tested: `acceptsUnknownCarbs` is what
/// tells the server this build can receive a food with no carb value, and
/// without it the server drops those foods and the user is never asked for the
/// number.
Map<String, dynamic> lookupRequestData(String input, {required int tzOffsetMinutes}) => {
      'input': input,
      // Lets the server count the free quota per local calendar day.
      'tzOffsetMinutes': tzOffsetMinutes,
      'acceptsUnknownCarbs': true,
    };
