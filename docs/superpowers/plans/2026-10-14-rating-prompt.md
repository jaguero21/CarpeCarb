# Rating Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ask for an App Store rating with Apple's popup after the 5th successful lookup, and add a "Rate CarpeCarb" link in Settings.

**Architecture:** `lib/services/rating_prompt.dart` holds a pure rule (`shouldAsk`) and a small `RatingPrompt` class. The class counts lookups in `SharedPreferences`, calls the `in_app_review` package, and opens the App Store review URL. `main.dart` calls it once, where a lookup has just logged food. The Settings Premium tab gets a text link.

**Tech Stack:** Flutter/Dart, `in_app_review` ^2.0.12 (new), `shared_preferences`, `url_launcher` (existing), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-10-14-rating-prompt-design.md`

## Global Constraints

- Ask after `askAfterLookups = 5` counted lookups. Later asks need at least `minDaysBetweenAsks = 120` days since the last ask **and** 5 counted lookups since then (the count resets to 0 on each ask).
- A lookup counts only when `_applyLookupResult` logs at least one food (`items.isNotEmpty`). Siri, saved-food relogs, Manual entry, failed lookups and all-unknown lookups don't count.
- Request the popup `RatingPrompt.askDelay = Duration(seconds: 1)` after the food is logged, and only if the screen is still mounted. A failed request is swallowed: no error is shown, and logging is unaffected.
- Storage keys are device-local and not synced: `StorageKeys.ratingLookupCount = 'rating_lookup_count'` (int) and `StorageKeys.ratingLastAskedAt = 'rating_last_asked_at'` (ISO-8601 UTC string).
- Review URL: `https://apps.apple.com/app/id6759311106?action=write-review`, opened with `LaunchMode.externalApplication`.
- Settings link text: `Rate CarpeCarb`. Its VoiceOver label: `Rate CarpeCarb on the App Store`, read as a button.
- Commits: `git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit ...`. NO `Co-Authored-By` trailer and no Claude/Claude Code attribution of any kind.
- Checks before each commit: `flutter analyze lib test` (no issues) and the task's tests. Run the full `flutter test` at the end of every task.

---

### Task 1: Rating rule and service

**Files:**
- Modify: `pubspec.yaml` (add `in_app_review: ^2.0.12` under `dependencies`, after `url_launcher`)
- Modify: `lib/config/storage_keys.dart` (two keys)
- Create: `lib/services/rating_prompt.dart`
- Test: `test/rating_prompt_test.dart`

**Interfaces:**
- Produces:
  - `const int askAfterLookups`, `const int minDaysBetweenAsks`
  - `bool shouldAsk({required int count, DateTime? lastAskedAt, required DateTime now})`
  - `class RatingPrompt`:
    - constructor `RatingPrompt({InAppReview? review})`
    - `static const Duration askDelay`
    - `static const String reviewUrl`
    - `@visibleForTesting static Future<bool> Function(Uri url) launcher`
    - `Future<bool> recordLookupAndMaybeAsk(DateTime now)`
    - `Future<void> requestReview()`
    - `static Future<void> openStoreReview()`

- [ ] **Step 1: Add the dependency and keys**

In `pubspec.yaml`, under `dependencies:` after `url_launcher: ^6.2.1`:

```yaml
  # Apple's in-app rating popup (SKStoreReviewController)
  in_app_review: ^2.0.12
```

Run: `flutter pub get`. Expected: resolves without conflicts.

In `lib/config/storage_keys.dart`, after the `// Subscription keys` block:

```dart
  // Rating prompt (lib/services/rating_prompt.dart). Device-local: each
  // device counts its own lookups and asks on its own schedule.
  static const String ratingLookupCount = 'rating_lookup_count';
  static const String ratingLastAskedAt = 'rating_last_asked_at';
```

- [ ] **Step 2: Write the failing tests**

Create `test/rating_prompt_test.dart`:

```dart
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/rating_prompt_test.dart`
Expected: FAIL, because `rating_prompt.dart` doesn't exist.

- [ ] **Step 4: Implement**

Create `lib/services/rating_prompt.dart`:

```dart
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

  /// Counts one lookup that logged food. Returns true when it's time to ask,
  /// and records the ask, so the caller only has to call [requestReview].
  Future<bool> recordLookupAndMaybeAsk(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(StorageKeys.ratingLookupCount) ?? 0) + 1;
    final saved = prefs.getString(StorageKeys.ratingLastAskedAt);
    final lastAskedAt = saved == null ? null : DateTime.tryParse(saved);
    if (!shouldAsk(count: count, lastAskedAt: lastAskedAt, now: now)) {
      await prefs.setInt(StorageKeys.ratingLookupCount, count);
      return false;
    }
    await prefs.setInt(StorageKeys.ratingLookupCount, 0);
    await prefs.setString(
        StorageKeys.ratingLastAskedAt, now.toUtc().toIso8601String());
    return true;
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/rating_prompt_test.dart`
Expected: all pass. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/config/storage_keys.dart lib/services/rating_prompt.dart test/rating_prompt_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(rating): count lookups and decide when to ask for a rating"
```

If `ios/Podfile.lock` changes from `flutter pub get`, leave it out; iOS pods are updated by the controller.

---

### Task 2: Ask after a successful lookup

**Files:**
- Modify: `lib/main.dart`: the state fields near `_healthKitService` (~line 110), `_applyLookupResult` (~line 678)
- Test: `test/rating_prompt_home_test.dart`

**Interfaces:**
- Consumes: `RatingPrompt`, `RatingPrompt.askDelay`, `recordLookupAndMaybeAsk(DateTime)` and `requestReview()` from Task 1. Also the existing test hook `CarbTrackerHomeState.applyLookupResultForTest(LookupResult)` and `LookupResult({required List<FoodItem> items, List<String> unknownCarbs})` from `lib/services/lookup_api.dart`.
- Produces: `@visibleForTesting set ratingPrompt(RatingPrompt prompt)` on `CarbTrackerHomeState`.

- [ ] **Step 1: Write the failing tests**

Create `test/rating_prompt_home_test.dart`. Copy the channel-stubbing helper `stubChannels()` from `test/serving_edit_test.dart` (home_widget, com.carpecarb/cloudsync, com.carpecarb/siribuffer, with the same teardown). Then:

```dart
import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/rating_prompt.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records asks instead of calling StoreKit.
class _RecordingPrompt extends RatingPrompt {
  int requests = 0;

  @override
  Future<void> requestReview() async => requests++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // stubChannels() copied from test/serving_edit_test.dart goes here.

  FoodItem apple() => FoodItem(name: 'apple', carbs: 25, loggedAt: DateTime.now());

  Future<(CarbTrackerHomeState, _RecordingPrompt)> start(WidgetTester tester) async {
    stubChannels();
    SharedPreferences.setMockInitialValues({'disclaimer_accepted': true});
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final prompt = _RecordingPrompt();
    state.ratingPrompt = prompt;
    return (state, prompt);
  }

  Future<void> logLookup(WidgetTester tester, CarbTrackerHomeState state,
      LookupResult result) async {
    await state.applyLookupResultForTest(result);
    // Let the prefs write finish so the delay timer exists, then run it out.
    await tester.pump();
    await tester.pump(RatingPrompt.askDelay);
    await tester.pumpAndSettle();
  }

  testWidgets('the 5th lookup that logs food asks for a rating, once',
      (tester) async {
    final (state, prompt) = await start(tester);
    for (var i = 0; i < 4; i++) {
      await logLookup(tester, state, LookupResult(items: [apple()]));
    }
    expect(prompt.requests, 0);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);
  });

  testWidgets('a lookup that found no carbs does not count', (tester) async {
    final (state, prompt) = await start(tester);
    for (var i = 0; i < 4; i++) {
      await logLookup(tester, state, LookupResult(items: [apple()]));
    }
    await logLookup(
        tester, state, const LookupResult(items: [], unknownCarbs: ['mystery stew']));
    expect(prompt.requests, 0);

    await logLookup(tester, state, LookupResult(items: [apple()]));
    expect(prompt.requests, 1);
  });
}
```

If `FoodItem`'s constructor needs other required arguments, match `lib/models/food_item.dart`. A lookup that fails never reaches `_applyLookupResult` (`_addFood` catches the error first), so no separate test is needed for it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/rating_prompt_home_test.dart`
Expected: FAIL, because the `ratingPrompt` setter doesn't exist.

- [ ] **Step 3: Implement**

In `lib/main.dart`, add the import `import 'services/rating_prompt.dart';` with the other service imports. Then, after the `healthKitService` setter:

```dart
  RatingPrompt _ratingPrompt = RatingPrompt();

  @visibleForTesting
  set ratingPrompt(RatingPrompt prompt) => _ratingPrompt = prompt;
```

In `_applyLookupResult`, at the end of the `if (items.isNotEmpty) { ... }` block, after the HealthKit loop:

```dart
      _maybeAskForRating();
```

Add the method right after `_applyLookupResult`:

```dart
  /// Counts a lookup that logged food. On the one that reaches the threshold,
  /// asks Apple for its rating popup a moment later, so the new food is seen
  /// first. Not awaited by the caller: logging never waits on this.
  Future<void> _maybeAskForRating() async {
    if (!await _ratingPrompt.recordLookupAndMaybeAsk(DateTime.now())) return;
    await Future<void>.delayed(RatingPrompt.askDelay);
    if (!mounted) return;
    await _ratingPrompt.requestReview();
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/rating_prompt_home_test.dart`
Expected: pass. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass, with no pending-timer failures in other widget tests).

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/rating_prompt_home_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(rating): ask for a rating after the 5th successful lookup"
```

---

### Task 3: "Rate CarpeCarb" link in Settings

**Files:**
- Modify: `lib/screens/settings_page.dart`: `_buildPremiumTab`, the footer above "Learn more at carpecarb.app" (~line 1896)
- Test: `test/rating_link_test.dart`

**Interfaces:**
- Consumes: `RatingPrompt.openStoreReview()`, `RatingPrompt.launcher` and `RatingPrompt.defaultLauncher` from Task 1. Also `SettingsPage({int initialTab})`, where tab 3 is Premium.

- [ ] **Step 1: Write the failing test**

Create `test/rating_link_test.dart`:

```dart
import 'package:carb_tracker/screens/settings_page.dart';
import 'package:carb_tracker/services/rating_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => RatingPrompt.launcher = RatingPrompt.defaultLauncher);

  testWidgets('Rate CarpeCarb opens the App Store review page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final opened = <Uri>[];
    RatingPrompt.launcher = (url) async {
      opened.add(url);
      return true;
    };

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SettingsPage(initialTab: 3))));
    await tester.pumpAndSettle();

    final link = find.text('Rate CarpeCarb');
    await tester.scrollUntilVisible(link, 200,
        scrollable: find.byType(Scrollable).last);
    expect(
        find.semantics.byLabel('Rate CarpeCarb on the App Store').evaluate().single,
        isSemantics(isButton: true));

    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(opened.map((u) => u.toString()),
        ['https://apps.apple.com/app/id6759311106?action=write-review']);
    handle.dispose();
  });
}
```

If `SettingsPage` needs channel stubs or a different host to pump (check how `test/widget_test.dart` or `test/a11y_controls_test.dart` reach Settings), adapt the setup and keep the assertions. If `find.byType(Scrollable).last` is the wrong scrollable on the Premium tab, pick the tab's own `ListView`/`SingleChildScrollView`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/rating_link_test.dart`
Expected: FAIL, because there is no "Rate CarpeCarb" text.

- [ ] **Step 3: Implement**

In `lib/screens/settings_page.dart`, add the import `import '../services/rating_prompt.dart';`. In `_buildPremiumTab`, directly before the `Center(` that holds "Learn more at carpecarb.app", insert:

```dart
        Center(
          child: Semantics(
            button: true,
            label: 'Rate CarpeCarb on the App Store',
            excludeSemantics: true,
            onTap: RatingPrompt.openStoreReview,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: RatingPrompt.openStoreReview,
              child: Text(
                'Rate CarpeCarb',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/rating_link_test.dart`
Expected: pass. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/settings_page.dart test/rating_link_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(rating): Rate CarpeCarb link in Settings"
```

---

## After the tasks (controller)

- `cd ios && pod install` if `in_app_review` added a pod. Then build in the main repo: `flutter build ios --simulator --debug`. Commit `ios/Podfile.lock` if it changed.
- Device check (Xcode debug build): Apple's popup appears on the 5th counted lookup, and the Settings link opens the App Store review page.
