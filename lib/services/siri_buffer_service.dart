import 'dart:developer' as dev;

import 'package:flutter/services.dart';

/// Takes the food Siri logged while the app was away.
///
/// The native side (`ios/Runner/SiriBufferChannel.swift`) hands over the buffer
/// and clears it in one step, so a Siri log that arrives while the app is
/// importing isn't overwritten — reading and clearing in two calls used to
/// drop it.
class SiriBufferService {
  static const _channel = MethodChannel('com.carpecarb/siribuffer');

  /// Returns the buffered items as JSON and empties the buffer, or null when
  /// nothing is waiting (or the channel isn't there, as on Android).
  Future<String?> takeLoggedItems() async {
    try {
      return await _channel.invokeMethod<String>('takeLoggedItems');
    } catch (e) {
      dev.log('SiriBufferService.takeLoggedItems error: $e');
      return null;
    }
  }
}
