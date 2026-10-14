import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/storage_keys.dart';

/// Successful lookups before the app asks for a rating, and again after each ask.
const int askAfterLookups = 5;

/// The shortest gap between two asks. Apple separately limits its popup to
/// three times a year and may not show it at all.
const int minDaysBetweenAsks = 120;

/// Whether to ask now, given [count] counted lookups since the last ask (or
/// since install) and when the app last asked.
bool shouldAsk({required int count, DateTime? lastAskedAt, required DateTime now}) {
  if (count < askAfterLookups) return false;
  if (lastAskedAt == null) return true;
  return now.difference(lastAskedAt) >= const Duration(days: minDaysBetweenAsks);
}

/// Asks for an App Store rating with Apple's own popup, at a moment the user
/// has just had a lookup work.
class RatingPrompt {
  RatingPrompt({InAppReview? review}) : _review = review ?? InAppReview.instance;

  final InAppReview _review;

  /// How long after the food appears to ask, so the popup doesn't cover it.
  static const Duration askDelay = Duration(seconds: 1);

  static const String reviewUrl =
      'https://apps.apple.com/app/id6759311106?action=write-review';

  static Future<bool> defaultLauncher(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  @visibleForTesting
  static Future<bool> Function(Uri url) launcher = defaultLauncher;

  /// Counts one lookup that logged food. Returns true when it's time to ask.
  /// Never resets anything: the count only resets in [ask], so a skipped ask
  /// leaves the count where it is and the next lookup that fits asks instead.
  Future<bool> recordLookup(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(StorageKeys.ratingLookupCount) ?? 0) + 1;
    await prefs.setInt(StorageKeys.ratingLookupCount, count);
    final saved = prefs.getString(StorageKeys.ratingLastAskedAt);
    final lastAskedAt = saved == null ? null : DateTime.tryParse(saved);
    return shouldAsk(count: count, lastAskedAt: lastAskedAt, now: now);
  }

  /// Records an ask (count back to 0, time saved in UTC) and requests the
  /// popup. Call it only when the popup is really about to be requested.
  Future<void> ask(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.ratingLookupCount, 0);
    await prefs.setString(
        StorageKeys.ratingLastAskedAt, now.toUtc().toIso8601String());
    await requestReview();
  }

  /// Asks StoreKit for the popup. Apple decides whether it appears; a failure
  /// is ignored, because nothing the user did depends on it.
  Future<void> requestReview() async {
    try {
      if (await _review.isAvailable()) await _review.requestReview();
    } catch (e) {
      if (kDebugMode) debugPrint('Review request failed: $e');
    }
  }

  /// Opens CarpeCarb's App Store page at "Write a Review".
  static Future<void> openStoreReview() async {
    try {
      await launcher(Uri.parse(reviewUrl));
    } catch (e) {
      if (kDebugMode) debugPrint('Opening the App Store failed: $e');
    }
  }
}
