import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/services/rating_prompt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeReview implements InAppReview {
  bool available = true;
  bool fail = false;
  int requests = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> requestReview() async {
    if (fail) throw Exception('StoreKit said no');
    requests++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 14, 12);

  group('shouldAsk', () {
    test('waits for the 5th lookup when it has never asked', () {
      expect(shouldAsk(count: 4, now: now), isFalse);
      expect(shouldAsk(count: 5, now: now), isTrue);
    });

    test('waits 120 days after the last ask', () {
      expect(
          shouldAsk(count: 5, lastAskedAt: now.subtract(const Duration(days: 119)), now: now),
          isFalse);
      expect(
          shouldAsk(count: 5, lastAskedAt: now.subtract(const Duration(days: 120)), now: now),
          isTrue);
    });

    test('needs 5 lookups even long after the last ask', () {
      expect(
          shouldAsk(count: 4, lastAskedAt: now.subtract(const Duration(days: 400)), now: now),
          isFalse);
    });
  });

  group('RatingPrompt.recordLookupAndMaybeAsk', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('counts lookups and asks on the 5th', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      final answers = [
        for (var i = 0; i < 5; i++) await prompt.recordLookupAndMaybeAsk(now),
      ];
      expect(answers, [false, false, false, false, true]);
    });

    test('an ask resets the count and saves the time in UTC', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      for (var i = 0; i < 5; i++) {
        await prompt.recordLookupAndMaybeAsk(now.toLocal());
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(StorageKeys.ratingLookupCount), 0);
      final saved = prefs.getString(StorageKeys.ratingLastAskedAt)!;
      expect(saved.endsWith('Z'), isTrue);
      expect(DateTime.parse(saved), now);
    });

    test('does not ask again the same day', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      for (var i = 0; i < 5; i++) {
        await prompt.recordLookupAndMaybeAsk(now);
      }
      final again = [
        for (var i = 0; i < 5; i++) await prompt.recordLookupAndMaybeAsk(now),
      ];
      expect(again, everyElement(isFalse));
    });

    test('asks again after 120 days and 5 more lookups', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      for (var i = 0; i < 5; i++) {
        await prompt.recordLookupAndMaybeAsk(now);
      }
      final later = now.add(const Duration(days: 120));
      final answers = [
        for (var i = 0; i < 5; i++) await prompt.recordLookupAndMaybeAsk(later),
      ];
      expect(answers, [false, false, false, false, true]);
    });
  });

  group('RatingPrompt.requestReview', () {
    test('asks StoreKit when it is available', () async {
      final review = _FakeReview();
      await RatingPrompt(review: review).requestReview();
      expect(review.requests, 1);
    });

    test('skips when unavailable and swallows failures', () async {
      final unavailable = _FakeReview()..available = false;
      await RatingPrompt(review: unavailable).requestReview();
      expect(unavailable.requests, 0);

      final failing = _FakeReview()..fail = true;
      await expectLater(RatingPrompt(review: failing).requestReview(), completes);
    });
  });

  group('RatingPrompt.openStoreReview', () {
    tearDown(() => RatingPrompt.launcher = RatingPrompt.defaultLauncher);

    test('opens the write-review page', () async {
      Uri? opened;
      RatingPrompt.launcher = (url) async {
        opened = url;
        return true;
      };
      await RatingPrompt.openStoreReview();
      expect(opened.toString(),
          'https://apps.apple.com/app/id6759311106?action=write-review');
    });

    test('swallows a launch failure', () async {
      RatingPrompt.launcher = (url) async => throw Exception('no App Store');
      await expectLater(RatingPrompt.openStoreReview(), completes);
    });
  });
}
