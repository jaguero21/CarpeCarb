# Source Tags and Lookup Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each food row gets a USDA, Web or Manual tag that shows where its carb number came from. A lookup shows "Looking up…" plus a status line that changes over time.

**Architecture:**
- **Pure helpers:** `lib/models/food_source.dart` works out a food's source, and
  `lib/utils/lookup_progress.dart` picks the status message for an elapsed time.
- **Drawing the tag:** a small `SourceTag` widget draws the pill. `FoodItemCard` puts it inline
  at the start of the subtitle, and `foodRowLabel` speaks it.
- **Tracking time:** `main.dart` counts seconds with a `Timer.periodic` while a lookup runs. It
  counts ticks instead of reading the clock, so tests can drive it.

**Tech Stack:** Flutter/Dart and `flutter_test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-14-source-tags-lookup-progress-design.md`

## Global Constraints

- **Working out a food's source.** `foodSourceOf(FoodItem)` returns the first match:
  1. `isManualEntry` → `FoodSource.manual`.
  2. `serving?.source == 'usda'` → `usda`, or `== 'web'` → `web`.
  3. `details` starts with `USDA FoodData Central` → `usda`.
  4. `details` starts with `Web source, not USDA.` → `web`.
  5. Otherwise `null`, and the food gets no tag.
- **Tag text.** Labels are `USDA` / `Web` / `Manual`. Spoken forms are `from USDA` / `from the web` / `entered manually`.
- **Pill style.** 10 pt, weight 600, letter spacing 0.3, radius 4, inline at the start of the row subtitle, followed by a space.
- **Base colours.** USDA `AppColors.sage`, Web `AppColors.honey`, Manual `AppColors.muted` (light) or `AppColors.darkMuted` (dark), which are the theme's `onSurfaceVariant`.
- **Tag colours.**
  - Background: the base colour at 15% opacity.
  - Text: `Color.lerp(base, Colors.black, 0.45)` in light mode and `Color.lerp(base, Colors.white, 0.35)` in dark mode.
  - The text must have at least 4.5:1 contrast against the background blended over the card (`Colors.white` light, `AppColors.darkSurface` dark).
- **Row VoiceOver label.** Parts in this order, joined by ", ": name, "N grams of carbs", source (spoken form, if any), serving (if any), "logged TIME".
- **Progress messages.** By elapsed time:
  - under 5 s: `Checking nutrition sources…`
  - 5 s to under 12 s: `Still checking — some foods need a second source`
  - 12 s to under 20 s: `Almost there…`
  - 20 s and over: `Taking longer than usual…`
- **While a lookup runs.**
  - The Add Food button shows the spinner and then `Looking up…`, in white, 16 pt, weight 500.
  - The status line sits under the button: 13 pt, `onSurfaceVariant`, centred, `Semantics(liveRegion: true)`. It is shown only while `isLoading`.
- **The seconds timer.** A 1-second `Timer.periodic` counts seconds. It starts with the lookup and is cancelled in a `finally` around the lookup, and in `dispose()`.
- **Unchanged.** The server, Siri, the details dialog, saved foods, chips and History.
- **Commits.**
  - Use `git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit ...`.
  - NO `Co-Authored-By` trailer and no Claude/Claude Code attribution of any kind.
  - Explicit `git add` paths only. Never commit `iap_review_screenshot.png`.
- **Checks.**
  - Before each commit: `flutter analyze lib test` must report no issues, and the task's tests must pass.
  - At the end of every task: run the full `flutter test`. It was 375 passing before this plan.

---

### Task 1: Source and progress helpers, with VoiceOver wording

**Files:**
- Create: `lib/models/food_source.dart`
- Create: `lib/utils/lookup_progress.dart`
- Modify: `lib/utils/a11y_labels.dart` (`foodRowLabel`)
- Test: `test/food_source_test.dart`, `test/lookup_progress_test.dart`, `test/a11y_labels_test.dart` (append)

**Interfaces:**
- Produces:
  - `enum FoodSource { usda, web, manual }`, with getters `String label` and `String spoken`.
  - `FoodSource? foodSourceOf(FoodItem item)`.
  - `String lookupProgressMessage(Duration elapsed)`.
  - `foodRowLabel({required String name, required double carbs, required String time, String? serving, String? source})`.

- [ ] **Step 1: Write the failing tests**

Create `test/food_source_test.dart`:

```dart
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/models/food_source.dart';
import 'package:carb_tracker/models/serving_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ServingInfo web() =>
      ServingInfo.fromServerItem({'source': 'web'}, const Nutrients(carbs: 10))!;
  ServingInfo usda() => ServingInfo.fromServerItem({
        'source': 'usda',
        'fdcId': 1,
        'serving': {'portionId': 'p1', 'label': '1 cup', 'grams': 245, 'count': 1},
        'portions': [
          {'id': 'p1', 'label': '1 cup', 'grams': 245},
        ],
        'per100g': {'carbs': 5.6},
      }, const Nutrients(carbs: 13.7))!;

  test('a manual entry is manual, even with a USDA serving', () {
    expect(
        foodSourceOf(FoodItem(name: 'x', carbs: 1, isManualEntry: true, serving: usda())),
        FoodSource.manual);
  });

  test('the saved serving decides', () {
    expect(foodSourceOf(FoodItem(name: 'x', carbs: 1, serving: usda())), FoodSource.usda);
    expect(foodSourceOf(FoodItem(name: 'x', carbs: 1, serving: web())), FoodSource.web);
  });

  test('without a serving, the server details decide', () {
    expect(
        foodSourceOf(FoodItem(
            name: 'x',
            carbs: 1,
            details: 'USDA FoodData Central (Survey (FNDDS)): Soup, pho, 1 cup (245 g).')),
        FoodSource.usda);
    expect(
        foodSourceOf(FoodItem(
            name: 'x', carbs: 1, details: 'Web source, not USDA. Per the label, 1 bar.')),
        FoodSource.web);
  });

  test('anything else has no known source', () {
    expect(foodSourceOf(FoodItem(name: 'x', carbs: 1)), isNull);
    expect(foodSourceOf(FoodItem(name: 'x', carbs: 1, details: 'Per Chipotle, 1 bowl.')),
        isNull);
  });

  test('labels and spoken forms', () {
    expect(FoodSource.values.map((s) => s.label), ['USDA', 'Web', 'Manual']);
    expect(FoodSource.values.map((s) => s.spoken),
        ['from USDA', 'from the web', 'entered manually']);
  });
}
```

If `ServingInfo.fromServerItem` or `Nutrients` has a different signature, check
`lib/models/serving_info.dart` and `test/serving_info_test.dart` and build equivalent USDA and web
servings. Keep the assertions.

Create `test/lookup_progress_test.dart`:

```dart
import 'package:carb_tracker/utils/lookup_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String at(int seconds) => lookupProgressMessage(Duration(seconds: seconds));

  test('the message changes at 5, 12 and 20 seconds', () {
    expect(at(0), 'Checking nutrition sources…');
    expect(at(4), 'Checking nutrition sources…');
    expect(at(5), 'Still checking — some foods need a second source');
    expect(at(11), 'Still checking — some foods need a second source');
    expect(at(12), 'Almost there…');
    expect(at(19), 'Almost there…');
    expect(at(20), 'Taking longer than usual…');
    expect(at(90), 'Taking longer than usual…');
  });
}
```

Append inside `main()` of `test/a11y_labels_test.dart`:

```dart
  group('food row source', () {
    test('the source comes after the carbs and before the serving', () {
      expect(
        foodRowLabel(
            name: 'Pho', carbs: 41.2, time: '12:05 PM', serving: '1 cup, 245 grams',
            source: 'from USDA'),
        'Pho, 41.2 grams of carbs, from USDA, 1 cup, 245 grams, logged 12:05 PM',
      );
      expect(
        foodRowLabel(name: 'Latte', carbs: 14, time: '8:10 AM', source: 'from the web'),
        'Latte, 14 grams of carbs, from the web, logged 8:10 AM',
      );
    });

    test('no source leaves the label as it was', () {
      expect(foodRowLabel(name: 'Apple', carbs: 25, time: '8:30 AM'),
          'Apple, 25 grams of carbs, logged 8:30 AM');
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/food_source_test.dart test/lookup_progress_test.dart test/a11y_labels_test.dart`
Expected: FAIL. The new files don't exist, and `foodRowLabel` has no `source` parameter.

- [ ] **Step 3: Implement**

Create `lib/models/food_source.dart`:

```dart
import 'food_item.dart';

/// Where a logged food's carb number came from, shown as a tag on its row so
/// someone deciding a dose can see how much to trust it.
enum FoodSource {
  usda,
  web,
  manual;

  String get label => switch (this) {
        FoodSource.usda => 'USDA',
        FoodSource.web => 'Web',
        FoodSource.manual => 'Manual',
      };

  /// As VoiceOver reads it in the row's label.
  String get spoken => switch (this) {
        FoodSource.usda => 'from USDA',
        FoodSource.web => 'from the web',
        FoodSource.manual => 'entered manually',
      };
}

/// The food's source, or null when it can't be told (foods looked up before
/// the USDA chain existed). Never guessed.
FoodSource? foodSourceOf(FoodItem item) {
  if (item.isManualEntry) return FoodSource.manual;
  switch (item.serving?.source) {
    case 'usda':
      return FoodSource.usda;
    case 'web':
      return FoodSource.web;
  }
  final details = item.details ?? '';
  // The prefixes the lookup server writes (functions/src/lookup.js).
  if (details.startsWith('USDA FoodData Central')) return FoodSource.usda;
  if (details.startsWith('Web source, not USDA.')) return FoodSource.web;
  return null;
}
```

Create `lib/utils/lookup_progress.dart`:

```dart
/// The status line under the Add Food button while a lookup runs. The app
/// sends one request and gets one answer, so it can't see the server's steps;
/// these messages only ever describe the wait, never a step.
String lookupProgressMessage(Duration elapsed) {
  if (elapsed < const Duration(seconds: 5)) return 'Checking nutrition sources…';
  if (elapsed < const Duration(seconds: 12)) {
    return 'Still checking — some foods need a second source';
  }
  if (elapsed < const Duration(seconds: 20)) return 'Almost there…';
  return 'Taking longer than usual…';
}
```

In `lib/utils/a11y_labels.dart`, replace `foodRowLabel` with:

```dart
/// One food in today's list, as a sentence rather than separate stops:
/// "Apple, 25 grams of carbs, from USDA, logged 8:30 AM". [source] is the
/// spoken form of where the number came from ([FoodSource.spoken]).
String foodRowLabel({
  required String name,
  required double carbs,
  required String time,
  String? serving,
  String? source,
}) =>
    [
      name,
      '${spokenGrams(carbs)} of carbs',
      if (source != null) source,
      if (serving != null) serving,
      'logged $time',
    ].join(', ');
```

Keep the existing doc comment's content if it says more than this. The old function's output must
not change for callers that pass no `source`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/food_source_test.dart test/lookup_progress_test.dart test/a11y_labels_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

- [ ] **Step 5: Commit**

```bash
git add lib/models/food_source.dart lib/utils/lookup_progress.dart lib/utils/a11y_labels.dart test/food_source_test.dart test/lookup_progress_test.dart test/a11y_labels_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): tell where a food's carbs came from and how a lookup is going"
```

---

### Task 2: Source tag on each row

**Files:**
- Create: `lib/widgets/source_tag.dart`
- Modify: `lib/widgets/food_item_card.dart`
- Modify: `lib/main.dart` (`_buildFoodTile`)
- Test: `test/source_tag_test.dart`, `test/source_tag_home_test.dart`

**Interfaces:**
- Consumes: from Task 1, `FoodSource`, `foodSourceOf` and `foodRowLabel(..., source:)`.
- Produces:
  - `({Color background, Color text}) sourceTagColors(FoodSource source, {required bool dark})`
  - `SourceTag(FoodSource source)`
  - `FoodItemCard(..., FoodSource? source)`

- [ ] **Step 1: Write the failing tests**

Create `test/source_tag_test.dart`:

```dart
import 'dart:math' as math;

import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/models/food_source.dart';
import 'package:carb_tracker/widgets/source_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final dark in [false, true]) {
    for (final source in FoodSource.values) {
      test('${source.label} tag text is readable in ${dark ? 'dark' : 'light'} mode', () {
        final colors = sourceTagColors(source, dark: dark);
        final card = dark ? AppColors.darkSurface : Colors.white;
        final background = Color.alphaBlend(colors.background, card);
        expect(_contrast(colors.text, background), greaterThanOrEqualTo(4.5));
      });
    }
  }

  testWidgets('the tag shows its label', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: SourceTag(FoodSource.usda)))));
    expect(find.text('USDA'), findsOneWidget);
  });
}
```

If `Color.r/.g/.b` aren't available in this Flutter version (they were added with the wide-gamut
`Color` API), use `c.red / 255` and so on.

Create `test/source_tag_home_test.dart`:

```dart
import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/widgets/food_item_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> food(String id, String name, double carbs,
          {Map<String, Object?> extra = const {}}) =>
      {
        'id': id,
        'name': name,
        'carbs': carbs,
        'category': 'lunch',
        'loggedAt': DateTime.now().toIso8601String(),
        ...extra,
      };

  final day = [
    food('u', 'Pho', 41.2, extra: {
      'details': 'USDA FoodData Central (Survey (FNDDS)): Soup, pho, 1 cup (245 g).',
    }),
    food('w', 'Protein bar', 22, extra: {'details': 'Web source, not USDA. Per label.'}),
    food('m', 'Toast', 15, extra: {'isManualEntry': true}),
    food('o', 'Old lookup', 30, extra: {'details': 'Per Chipotle, 1 bowl.'}),
  ];

  Future<void> start(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(day));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
  }

  Finder inRow(String text) =>
      find.descendant(of: find.byType(FoodItemCard), matching: find.text(text));

  testWidgets('rows show where their carbs came from', (tester) async {
    await start(tester);
    expect(inRow('USDA'), findsOneWidget);
    expect(inRow('Web'), findsOneWidget);
    expect(inRow('Manual'), findsOneWidget);
  });

  testWidgets('VoiceOver reads the source in the row label', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await start(tester);
      expect(find.semantics.byLabel(RegExp(r'^Pho, 41\.2 grams of carbs, from USDA, ')),
          findsOneWidget);
      expect(find.semantics.byLabel(RegExp(r'^Toast, 15 grams of carbs, entered manually, ')),
          findsOneWidget);
      expect(find.semantics.byLabel(RegExp(r'^Old lookup, 30 grams of carbs, logged ')),
          findsOneWidget);
    } finally {
      handle.dispose();
    }
  });
}
```

`isManualEntry` must match the JSON key `FoodItem.fromJson` reads. Check `lib/models/food_item.dart`,
and if the key differs, use the right one in the test data.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/source_tag_test.dart test/source_tag_home_test.dart`
Expected: FAIL, because `source_tag.dart` doesn't exist and rows have no tags.

- [ ] **Step 3: Implement the tag**

Create `lib/widgets/source_tag.dart`:

```dart
import 'package:flutter/material.dart';

import '../config/app_colors.dart';
import '../models/food_source.dart';

Color _base(FoodSource source, bool dark) => switch (source) {
      FoodSource.usda => AppColors.sage,
      FoodSource.web => AppColors.honey,
      FoodSource.manual => dark ? AppColors.darkMuted : AppColors.muted,
    };

/// The pill's colours. The text is the base colour darkened (light mode) or
/// lightened (dark mode): sage and honey as they are fall below 4.5:1 at 10 pt.
({Color background, Color text}) sourceTagColors(FoodSource source,
    {required bool dark}) {
  final base = _base(source, dark);
  return (
    background: base.withValues(alpha: 0.15),
    text: Color.lerp(base, dark ? Colors.white : Colors.black, dark ? 0.35 : 0.45)!,
  );
}

/// A small pill naming where a food's carbs came from: USDA, Web or Manual.
class SourceTag extends StatelessWidget {
  const SourceTag(this.source, {super.key});

  final FoodSource source;

  @override
  Widget build(BuildContext context) {
    final colors = sourceTagColors(source,
        dark: Theme.of(context).brightness == Brightness.dark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        source.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: colors.text,
        ),
      ),
    );
  }
}
```

If the contrast test fails for one source/mode (most likely Manual, depending on the
`muted`/`darkMuted` values), increase that lerp amount until it passes, and report the values. Don't
lower the 4.5 threshold.

- [ ] **Step 4: Put the tag on the row**

In `lib/widgets/food_item_card.dart`:
- Import `../models/food_source.dart` and `source_tag.dart`.
- Add the field `final FoodSource? source;` and the constructor parameter `this.source`.
- Replace the subtitle `Text(subtitle, style: ...)` with:

```dart
                  Text.rich(
                    TextSpan(children: [
                      if (source != null) ...[
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: SourceTag(source!),
                        ),
                        const TextSpan(text: ' '),
                      ],
                      TextSpan(text: subtitle),
                    ]),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
```

In `lib/main.dart` `_buildFoodTile`, import `models/food_source.dart`. Compute
`final source = foodSourceOf(item);` and pass `source: source?.spoken` to `foodRowLabel(...)` and
`source: source` to `FoodItemCard(...)`.

- [ ] **Step 5: Run the tests**

Run: `flutter test test/source_tag_test.dart test/source_tag_home_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass).

Existing tests that find a row's subtitle with `find.text('<time> · <serving>')` may stop matching,
because a tagged subtitle's plain text now starts with an object-replacement character. Change
those finders to `find.textContaining(...)` and list each change in the report. Don't change what
they assert.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/source_tag.dart lib/widgets/food_item_card.dart lib/main.dart test/source_tag_test.dart test/source_tag_home_test.dart
# plus any existing tests whose finders changed in Step 5
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): tag each food with where its carbs came from"
```

---

### Task 3: Lookup progress

**Files:**
- Modify: `lib/main.dart`
- Test: `test/lookup_progress_home_test.dart`

**Interfaces:**
- Consumes: from Task 1, `lookupProgressMessage(Duration)`.
- Consumes: `LookupResult` (`lib/services/lookup_api.dart`), `PerplexityFirebaseService.getMultipleCarbCounts(String)`, and `UserFacingException` (`lib/utils/user_facing_exception.dart`).
- Produces on `CarbTrackerHomeState`:
  - `@visibleForTesting set perplexityService(PerplexityFirebaseService service)`
  - `int _lookupSeconds`
  - `Timer? _lookupTicker`
  - `_startLookupProgress()`
  - `_stopLookupProgress()`

- [ ] **Step 1: Write the failing tests**

Create `test/lookup_progress_home_test.dart`:

```dart
import 'dart:async';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';
import 'package:carb_tracker/services/perplexity_firebase_service.dart';
import 'package:carb_tracker/utils/user_facing_exception.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/home_harness.dart';

/// A lookup that answers only when the test says so.
class _SlowLookup extends PerplexityFirebaseService {
  final answer = Completer<LookupResult>();

  @override
  Future<LookupResult> getMultipleCarbCounts(String input) => answer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_SlowLookup> startLookup(WidgetTester tester) async {
    stubHomeChannels();
    SharedPreferences.setMockInitialValues(todayPrefs(const []));
    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();
    final state = tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final lookup = _SlowLookup();
    state.perplexityService = lookup;

    await tester.enterText(find.byType(TextField).first, 'apple');
    await tester.tap(find.text('Add Food'));
    await tester.pump();
    return lookup;
  }

  testWidgets('the button and status line say what is happening, and change with time',
      (tester) async {
    final lookup = await startLookup(tester);
    expect(find.text('Looking up…'), findsOneWidget);
    expect(find.text('Checking nutrition sources…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Checking nutrition sources…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Still checking — some foods need a second source'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    expect(find.text('Almost there…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('Taking longer than usual…'), findsOneWidget);

    lookup.answer.complete(LookupResult(items: [FoodItem(name: 'apple', carbs: 25)]));
    await tester.pumpAndSettle();
    expect(find.text('Taking longer than usual…'), findsNothing);
    expect(find.text('Looking up…'), findsNothing);

    // The ticker stopped: time passing changes nothing.
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Checking nutrition sources…'), findsNothing);
  });

  testWidgets('a failed lookup clears the status line', (tester) async {
    final lookup = await startLookup(tester);
    await tester.pump(const Duration(seconds: 6));
    lookup.answer.completeError(UserFacingException('Server error. Try again later.'));
    await tester.pumpAndSettle();
    expect(find.text('Still checking — some foods need a second source'), findsNothing);
    expect(find.text('Looking up…'), findsNothing);
    expect(find.text('Server error. Try again later.'), findsOneWidget);
  });

  testWidgets('VoiceOver hears each new status', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final lookup = await startLookup(tester);
      expect(
        find.semantics.byLabel('Checking nutrition sources…').evaluate().single,
        isSemantics(isLiveRegion: true),
      );
      lookup.answer.complete(const LookupResult(items: []));
      await tester.pumpAndSettle();
    } finally {
      handle.dispose();
    }
  });
}
```

Check the details against the code:
- If `UserFacingException`'s constructor or import path differs, match it.
- The food field may not be the first `TextField` on screen. If it isn't, scope the finder to the
  home page's food field, for example by its hint text "Enter food item…".
- An empty `LookupResult` may hand off to Manual entry or show a snackbar. That's fine; the test
  only completes the lookup.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/lookup_progress_home_test.dart`
Expected: FAIL, because there is no `perplexityService` setter and no progress text.

- [ ] **Step 3: Implement**

In `lib/main.dart`:

1. Import `utils/lookup_progress.dart`.
2. Replace `final PerplexityFirebaseService _perplexityService = PerplexityFirebaseService();` with:

```dart
  PerplexityFirebaseService _perplexityService = PerplexityFirebaseService();

  @visibleForTesting
  set perplexityService(PerplexityFirebaseService service) =>
      _perplexityService = service;
```

3. Add next to `isLoading`:

```dart
  /// Seconds the current lookup has run, for the status line under the Add
  /// Food button. Counted by a timer rather than read from the clock, so the
  /// messages follow the same time the tests drive.
  int _lookupSeconds = 0;
  Timer? _lookupTicker;

  void _startLookupProgress() {
    _lookupTicker?.cancel();
    _lookupSeconds = 0;
    _lookupTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _lookupSeconds++);
    });
  }

  void _stopLookupProgress() {
    _lookupTicker?.cancel();
    _lookupTicker = null;
  }
```

4. In `_addFood`, start the ticker right after the `setState(() { isLoading = true; });`, with
   `_startLookupProgress();`. Then add `finally { _stopLookupProgress(); }` to the
   `try { ... } on DailyLimitReachedException ... catch (e) { ... }` that follows. The `finally`
   covers every way out, including the early `if (!mounted) return;`.
5. In `dispose()`, add `_lookupTicker?.cancel();` next to `_dayBoundaryTimer?.cancel();`.
6. On the Add Food `ElevatedButton`, replace the `isLoading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(...))` branch with:

```dart
                            child: isLoading
                                ? const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      ),
                                      SizedBox(width: 10),
                                      Text(
                                        'Looking up…',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  )
```

   Keep the existing `: Row(...)` non-loading branch unchanged.
7. Directly after the widget that holds the Add Food button (the `SizedBox(width: double.infinity, child: Container(... ElevatedButton ...))`), still inside the input card's `Column`, add:

```dart
                      if (isLoading) ...[
                        const SizedBox(height: 10),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            lookupProgressMessage(
                                Duration(seconds: _lookupSeconds)),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/lookup_progress_home_test.dart`
Expected: PASS. Then run `flutter analyze lib test` (no issues) and `flutter test` (all pass, with no
pending-timer failures).

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/lookup_progress_home_test.dart
git -c user.name="James Aguero" -c user.email="james.aguero@gmail.com" commit -m "feat(today): show how a lookup is going while it runs"
```

---

## After the tasks (controller)

- Run `flutter build ios --simulator --debug` in the main repo.
- Device check with an Xcode debug build:
  - The tags in light and dark mode, and at large text sizes.
  - The progress text during a real lookup.
  - VoiceOver reads the source in each row and announces each progress change.
