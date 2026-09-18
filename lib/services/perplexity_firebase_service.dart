import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../config/storage_keys.dart';
import '../utils/input_validation.dart';
import '../utils/user_facing_exception.dart';
import 'lookup_api.dart';

class PerplexityFirebaseService {
  static const _tokenChannel = MethodChannel(StorageKeys.tokenStorageChannel);
  // Rate limiting to prevent UI-level spamming
  static DateTime? _lastRequestTime;
  static const Duration _minRequestInterval = Duration(milliseconds: 1500);

  static const String _functionUrl =
      'https://us-central1-carpecarb.cloudfunctions.net/getMultipleCarbCounts';

  /// Looks up one or more food items via the Firebase Cloud Function.
  /// Throws [DailyLimitReachedException] when the server refuses a free
  /// user's lookup for today, and [UserFacingException] for other failures.
  /// Uses direct HTTPS REST call to avoid Firebase Functions SDK AOT crash
  /// (swift_task_switch in HTTPSCallable.call on iOS 12.9.x SDK).
  Future<LookupResult> getMultipleCarbCounts(String input) async {
    await _enforceRateLimit();

    final validationError = InputValidation.validateFoodInput(input);
    if (validationError != null) {
      throw UserFacingException(validationError);
    }

    // Normalize Unicode (curly apostrophes, smart quotes, etc.) before sending
    // to the API so the Cloud Function receives clean ASCII-safe text.
    final sanitizedInput = InputValidation.sanitizeForApi(input);

    // Get the current user's ID token for authentication
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw UserFacingException('Authentication error. Please restart the app.');
    }

    String idToken;
    try {
      idToken = await user.getIdToken() ?? '';
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to get ID token: $e');
      throw UserFacingException('Authentication error. Please restart the app.');
    }

    if (idToken.isEmpty) {
      throw UserFacingException('Authentication error. Please restart the app.');
    }

    // Keep the shared token fresh so Siri/Watch extensions can auth.
    // Stored in Keychain (secure) + App Group UserDefaults (backward compat).
    try {
      await _tokenChannel.invokeMethod<void>('saveToken', idToken);
    } catch (_) {
      // Non-fatal — token sharing is best-effort.
    }

    final body = jsonEncode({
      'data': {
        'input': sanitizedInput,
        // Lets the server count the free quota per local calendar day.
        'tzOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
      }
    });

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 60);
      try {
        final request = await client.postUrl(Uri.parse(_functionUrl));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('Authorization', 'Bearer $idToken');
        request.write(body);

        final response = await request.close().timeout(const Duration(seconds: 60));
        final responseBody = await response.transform(utf8.decoder).join();

        if (kDebugMode) debugPrint('Cloud Function HTTP ${response.statusCode}');

        if (response.statusCode != 200) {
          if (kDebugMode) debugPrint('Cloud Function error body: $responseBody');
          throw parseCallableError(response.statusCode, responseBody);
        }

        return parseLookupResponse(responseBody);
      } finally {
        client.close();
      }
    } on UserFacingException {
      rethrow;
    } on SocketException {
      throw UserFacingException('Network error. Please check your connection.');
    } catch (e) {
      if (kDebugMode) debugPrint('PerplexityFirebaseService error: $e');
      throw UserFacingException('Network error. Please check your connection.');
    }
  }

  /// Enforces rate limiting between API requests
  Future<void> _enforceRateLimit() async {
    if (_lastRequestTime != null) {
      final timeSinceLastRequest = DateTime.now().difference(_lastRequestTime!);
      if (timeSinceLastRequest < _minRequestInterval) {
        final waitTime = _minRequestInterval - timeSinceLastRequest;
        await Future.delayed(waitTime);
      }
    }
    _lastRequestTime = DateTime.now();
  }
}
