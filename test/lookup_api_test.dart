import 'dart:convert';

import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/utils/user_facing_exception.dart';
import 'package:flutter_test/flutter_test.dart';

String callableResult(Map<String, dynamic> result) => jsonEncode({'result': result});
String callableError(String status, String message, [Map<String, dynamic>? details]) =>
    jsonEncode({
      'error': {'status': status, 'message': message, if (details != null) 'details': details},
    });

void main() {
  group('parseLookupResponse', () {
    test('parses items, citations, and a free-tier quota', () {
      final result = parseLookupResponse(callableResult({
        'items': [
          {'name': 'Apple', 'carbs': 25, 'protein': 0.5, 'details': 'USDA [1]'},
        ],
        'citations': ['https://fdc.nal.usda.gov'],
        'quota': {'premium': false, 'used': 2, 'limit': 4, 'dayKey': '2026-09-18'},
      }));

      expect(result.items.single.name, 'Apple');
      expect(result.items.single.carbs, 25.0);
      expect(result.items.single.protein, 0.5);
      expect(result.items.single.citations, ['https://fdc.nal.usda.gov']);
      expect(result.quota!.premium, isFalse);
      expect(result.quota!.used, 2);
      expect(result.quota!.limit, 4);
      expect(result.quota!.dayKey, '2026-09-18');
    });

    test('parses a premium quota with null counts', () {
      final result = parseLookupResponse(callableResult({
        'items': [{'name': 'Rice', 'carbs': 45}],
        'quota': {'premium': true, 'used': null, 'limit': null, 'dayKey': null},
      }));

      expect(result.quota!.premium, isTrue);
      expect(result.quota!.used, isNull);
      expect(result.quota!.dayKey, isNull);
    });

    test('tolerates a response without quota', () {
      final result = parseLookupResponse(callableResult({
        'items': [{'name': 'Rice', 'carbs': '45'}],
      }));

      expect(result.quota, isNull);
      expect(result.items.single.carbs, 45.0);
    });

    test('throws a user-facing error for empty or malformed bodies', () {
      expect(() => parseLookupResponse(callableResult({'items': []})),
          throwsA(isA<UserFacingException>()));
      expect(() => parseLookupResponse('{}'), throwsA(isA<UserFacingException>()));
      expect(() => parseLookupResponse('not json'), throwsA(isA<UserFacingException>()));
    });
  });

  group('parseCallableError', () {
    test('daily-quota 429 becomes DailyLimitReachedException', () {
      final e = parseCallableError(
        429,
        callableError('RESOURCE_EXHAUSTED', "You've used today's 4 free lookups.",
            {'reason': 'daily-quota', 'used': 4, 'limit': 4, 'dayKey': '2026-09-18'}),
      );

      expect(e, isA<DailyLimitReachedException>());
      final limitError = e as DailyLimitReachedException;
      expect(limitError.used, 4);
      expect(limitError.limit, 4);
      expect(limitError.dayKey, '2026-09-18');
      expect(limitError.message, "You've used all 4 free AI lookups for today.");
    });

    test('per-minute 429 keeps the rate-limit message', () {
      final e = parseCallableError(
          429, callableError('RESOURCE_EXHAUSTED', 'Rate limit exceeded. Try again in 12 second(s).'));

      expect(e, isNot(isA<DailyLimitReachedException>()));
      expect(e.message, 'Rate limit exceeded. Please try again later.');
    });

    test('auth failures ask the user to restart', () {
      expect(parseCallableError(401, '').message, 'Authentication error. Please restart the app.');
      expect(parseCallableError(403, '').message, 'Authentication error. Please restart the app.');
    });

    test('other errors surface the server message, or a fallback', () {
      expect(parseCallableError(400, callableError('INVALID_ARGUMENT', 'input must be 2-100 characters')).message,
          'input must be 2-100 characters');
      expect(parseCallableError(500, '<html>oops</html>').message,
          'Failed to get carb count. Please try again.');
    });
  });
}
