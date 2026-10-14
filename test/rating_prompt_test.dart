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

  group('RatingPrompt.recordLookup', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('counts lookups and says to ask on the 5th', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      final answers = [
        for (var i = 0; i < 5; i++) await prompt.recordLookup(now),
      ];
      expect(answers, [false, false, false, false, true]);
    });

    test('keeps saying to ask until the ask is made', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      for (var i = 0; i < 5; i++) {
        await prompt.recordLookup(now);
      }
      expect(await prompt.recordLookup(now), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(StorageKeys.ratingLookupCount), 6);
      expect(prefs.getString(StorageKeys.ratingLastAskedAt), isNull);
    });
  });

  group('RatingPrompt.ask', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> countFive(RatingPrompt prompt, DateTime at) async {
      for (var i = 0; i < 5; i++) {
        await prompt.recordLookup(at);
      }
    }

    test('resets the count, saves the time in UTC and requests the popup',
        () async {
      final review = _FakeReview();
      final prompt = RatingPrompt(review: review);
      await countFive(prompt, now);
      await prompt.ask(now.toLocal());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(StorageKeys.ratingLookupCount), 0);
      final saved = prefs.getString(StorageKeys.ratingLastAskedAt)!;
      expect(saved.endsWith('Z'), isTrue);
      expect(DateTime.parse(saved), now);
      expect(review.requests, 1);
    });

    test('five more lookups the same day do not ask again', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      await countFive(prompt, now);
      await prompt.ask(now);
      final again = [
        for (var i = 0; i < 5; i++) await prompt.recordLookup(now),
      ];
      expect(again, everyElement(isFalse));
    });

    test('asks again after 120 days and 5 more lookups', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      await countFive(prompt, now);
      await prompt.ask(now);
      final later = now.add(const Duration(days: 120));
      final answers = [
        for (var i = 0; i < 5; i++) await prompt.recordLookup(later),
      ];
      expect(answers, [false, false, false, false, true]);
    });

    test('lookups made during the 120-day wait still count', () async {
      final prompt = RatingPrompt(review: _FakeReview());
      await countFive(prompt, now);
      await prompt.ask(now);
      final tenDaysIn = now.add(const Duration(days: 10));
      for (var i = 0; i < 7; i++) {
        expect(await prompt.recordLookup(tenDaysIn), isFalse);
      }
      expect(await prompt.recordLookup(now.add(const Duration(days: 120))),
          isTrue);
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
