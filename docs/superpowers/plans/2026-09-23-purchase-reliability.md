# Purchase Reliability and Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop losing purchases that the App Store confirms when no screen is waiting, and clear four pieces of dead or mislabelled configuration.

**Architecture:** One `PurchaseService` singleton owns a single `purchaseStream` subscription started from `main()` and never cancelled. That listener is the only code that validates a receipt, completes a transaction and grants premium; `purchasePlan` and `restorePremiumPlan` become waiters on it, so their timeouts bound the wait rather than the purchase.

**Tech Stack:** Flutter 3.41.9 / Dart 3.11.5, `in_app_purchase`, `firebase_auth`, `shared_preferences`, Swift 6.4 / Xcode 27 for the iOS project.

## Global Constraints

- Commits carry NO `Co-Authored-By` or other attribution trailer, and no "Generated with Claude Code" line. Use explicit `git add` paths only. Never stage `build/`, `ios/Pods/`, `lib/firebase_options.dart`, `ios/Runner/GoogleService-Info.plist`, `analysis_options.yaml`, `pubspec.lock`, or any untracked file.
- Branch: `feature/purchase-reliability` (the spec is already committed there).
- **No visual change.** Nothing in this batch may move, resize or recolour anything on screen. The colour task in particular is a rename, not a restyle — every value must survive it.
- **Never call `completePurchase` on a transaction whose receipt was not validated.** Completing drops it from StoreKit's queue and the receipt can no longer be checked, so a paid-for purchase is gone for good. Not reaching the validator is not evidence about the receipt: hold the transaction instead. Only a `ReceiptRejected` — the server having actually looked and said no — finishes an ungranted transaction.
- Premium is granted by `PurchaseService`, never by a screen. A screen that grants cannot see the transactions that arrive when no screen is open, which is the entire problem this batch fixes.
- Checks: `flutter analyze && flutter test` from the repo root; `cd ios/CarbShared && swift test`; and the iOS build **with its own DerivedData**, so it cannot leave ad-hoc-signed frameworks in the cache Xcode uses:
  `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/purchase-dd CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- If a Flutter test fails with `Asset 'shaders/ink_sparkle.frag' manifest could not be decoded`, run `rm -rf build/unit_test_assets` and re-run. That is a stale generated asset, not your change.
- Don't run `dart format` over a whole pre-existing file; it reformats unrelated code and buries the change.

## How to apply the edits in this plan

Every code block is the exact text that was built and tested. Copy it byte-for-byte.

- **New file:** `python3 .superpowers/sdd/extract_block.py TASK_BRIEF --list`, then `extract_block.py TASK_BRIEF N path/to/file`.
- **Edit to an existing file:** each edit is a "replace / with" pair of consecutive blocks.

```bash
python3 .superpowers/sdd/extract_block.py TASK_BRIEF N /tmp/old.txt
python3 .superpowers/sdd/extract_block.py TASK_BRIEF N+1 /tmp/new.txt
python3 .superpowers/sdd/replace_block.py path/to/file /tmp/old.txt /tmp/new.txt
```

If `replace_block.py` reports 0 or 2+ occurrences, stop and report NEEDS_CONTEXT rather than hand-editing.

## File Map

| File | Task | Responsibility |
|---|---|---|
| `pubspec.yaml`, `android/app/src/main/AndroidManifest.xml` | 1 | the app's own name |
| `lib/config/app_colors.dart` | 2 | the palette gains the values that were loose in view code |
| `lib/models/food_item.dart`, `lib/widgets/glass_container.dart`, `lib/main.dart` | 2 | use the palette |
| `test/palette_test.dart` | 2 | pins every moved colour to its original value |
| `lib/services/purchase_service.dart` | 3 | the lifetime listener, the lock, validation and granting |
| `test/purchase_service_test.dart` | 3 | the ways a purchase can be lost |
| `lib/main.dart`, `lib/screens/settings_page.dart` | 4 | start the listener; use the singleton; announce late grants |
| `ios/Runner/Runner.entitlements` | 5 | drop capabilities the app does not use |

---

### Task 1: The app's own name

`pubspec.yaml` still describes the app as "biteBot", a name it no longer has, and the Android manifest labels it that too.

**Files:**
- Modify: `pubspec.yaml:2`
- Modify: `android/app/src/main/AndroidManifest.xml:3`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. No Dart code reads either value.

- [ ] **Step 1: Fix the package description**

In `pubspec.yaml`:

**Edit 1 of 1 — replace:**

```
name: carb_tracker
description: biteBot - A minimalist carb tracking app using Perplexity API
publish_to: 'none'
version: 1.0.2+4

environment:
  sdk: '>=3.0.0 <4.0.0'
```

**with:**

```
name: carb_tracker
description: CarpeCarb - A minimalist carb tracker with AI-powered nutrition lookup
publish_to: 'none'
version: 1.0.2+4

environment:
  sdk: '>=3.0.0 <4.0.0'
```


- [ ] **Step 2: Fix the Android label**

In `android/app/src/main/AndroidManifest.xml`:

**Edit 1 of 1 — replace:**

```
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="biteBot"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
```

**with:**

```
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="CarpeCarb"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
```


- [ ] **Step 3: Check nothing broke**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml android/app/src/main/AndroidManifest.xml
git commit -m "chore: call the app by its name"
```

---

### Task 2: Colours live in the palette

Eight `Color(0x…)` literals sit in view code next to a comprehensive palette. Four are exactly a constant that already exists; four are values the palette has never named. **Three of those four are near-misses of brand colours with confusingly similar names** — `0xFF7D9B76` is not `sage` (`0xFF8FA088`), `0xFFB07CC6` is not `plum` (`0xFF7B4F72`), `0xFF5B9BD5` is not `sky` (`0xFF5B8DB8`). Reaching for the namesake instead of the new constant would repaint the category dots, so the test goes in first and pins each value.

**Files:**
- Modify: `lib/config/app_colors.dart`
- Modify: `lib/models/food_item.dart`, `lib/widgets/glass_container.dart`, `lib/main.dart`
- Test: `test/palette_test.dart`

**Interfaces:**
- Consumes: `AppColors` (`lib/config/app_colors.dart`), `FoodCategory.color` (`lib/models/food_item.dart`).
- Produces: `AppColors.categoryHoney`, `categorySage`, `categoryTerracotta`, `categoryPlum`, `categorySky`, `progressTrack` — all `Color`.

- [ ] **Step 1: Add the constants**

In `lib/config/app_colors.dart`:

**Edit 1 of 1 — replace:**

```dart
  // Glass effect colors (Liquid Glass-inspired)
  static const Color glassLight = Color(0x99FFFFFF);       // white 60%
  static const Color glassDark = Color(0x66252019);        // dark surface 40%
  static const Color glassBorderLight = Color(0x33FFFFFF); // white 20%
  static const Color glassBorderDark = Color(0x14F5EFE8);  // light 8%

  // Semantic Colors
  static const Color success = sage;
  static const Color warning = honey;
  static const Color error = terracotta;
  static const Color info = sky;
```

**with:**

```dart
  // Glass effect colors (Liquid Glass-inspired)
  static const Color glassLight = Color(0x99FFFFFF);       // white 60%
  static const Color glassDark = Color(0x66252019);        // dark surface 40%
  static const Color glassBorderLight = Color(0x33FFFFFF); // white 20%
  static const Color glassBorderDark = Color(0x14F5EFE8);  // light 8%

  // Food category colors. Three of these are close to, but deliberately not,
  // the brand colors above — categorySage is not `sage`, categoryPlum is not
  // `plum`, categorySky is not `sky`. They are named here at their original
  // values so the dots on screen stay exactly as they were.
  static const Color categoryHoney = honey;
  static const Color categorySage = Color(0xFF7D9B76);
  static const Color categoryTerracotta = terracotta;
  static const Color categoryPlum = Color(0xFFB07CC6);
  static const Color categorySky = Color(0xFF5B9BD5);

  // Track behind the daily progress bar in light mode.
  static const Color progressTrack = Color(0xFFE5E7EB);

  // Semantic Colors
  static const Color success = sage;
  static const Color warning = honey;
  static const Color error = terracotta;
  static const Color info = sky;
```


- [ ] **Step 2: Write the pinning test**

Create `test/palette_test.dart`:

```dart
import 'package:carb_tracker/config/app_colors.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the colors that moved out of view code and into the palette.
///
/// Naming a value is only a refactor if the value survives it, and three of
/// the category colors are near-misses of brand colors with the same name —
/// `categorySage` is not `sage`. Reaching for the wrong constant would repaint
/// the app, so each one is asserted against the literal it replaced.
void main() {
  test('every food category keeps the color it had', () {
    expect(FoodCategory.breakfast.color, const Color(0xFFE8A93C));
    expect(FoodCategory.lunch.color, const Color(0xFF7D9B76));
    expect(FoodCategory.dinner.color, const Color(0xFFD4714E));
    expect(FoodCategory.snack.color, const Color(0xFFB07CC6));
    expect(FoodCategory.drink.color, const Color(0xFF5B9BD5));
  });

  test('the near-miss category colors are not their brand namesakes', () {
    // If these ever become equal, the pinning test above stops being able to
    // tell `categorySage` from `sage` and the guard quietly weakens.
    expect(AppColors.categorySage, isNot(AppColors.sage));
    expect(AppColors.categoryPlum, isNot(AppColors.plum));
    expect(AppColors.categorySky, isNot(AppColors.sky));
  });

  test('the constants named after existing brand colors still equal them', () {
    expect(AppColors.categoryHoney, AppColors.honey);
    expect(AppColors.categoryTerracotta, AppColors.terracotta);
  });

  test('the progress track keeps its light-mode grey', () {
    expect(AppColors.progressTrack, const Color(0xFFE5E7EB));
  });
}
```

- [ ] **Step 3: Run it — it passes before the change**

Run: `flutter test test/palette_test.dart`
Expected: PASS, 4 tests. A pinning test is green before and after; its job is to *stay* green. If it fails now, a constant was mistyped in Step 1.

- [ ] **Step 4: Use the palette in the category colours**

In `lib/models/food_item.dart`:

**Edit 1 of 2 — replace:**

```dart
import 'dart:math';

import 'package:flutter/material.dart';

enum FoodCategory {
  breakfast,
  lunch,
  dinner,
  snack,
  drink;
```

**with:**

```dart
import 'dart:math';

import 'package:flutter/material.dart';

import '../config/app_colors.dart';

enum FoodCategory {
  breakfast,
  lunch,
  dinner,
  snack,
  drink;
```

**Edit 2 of 2 — replace:**

```dart
    }
  }

  Color get color {
    switch (this) {
      case FoodCategory.breakfast:
        return const Color(0xFFE8A93C); // warm yellow
      case FoodCategory.lunch:
        return const Color(0xFF7D9B76); // sage green
      case FoodCategory.dinner:
        return const Color(0xFFD4714E); // terracotta
      case FoodCategory.snack:
        return const Color(0xFFB07CC6); // purple
      case FoodCategory.drink:
        return const Color(0xFF5B9BD5); // blue
    }
  }

  /// Assign category based on time of day
  static FoodCategory fromTime(DateTime time) {
    final hour = time.hour;
```

**with:**

```dart
    }
  }

  Color get color {
    switch (this) {
      case FoodCategory.breakfast:
        return AppColors.categoryHoney;
      case FoodCategory.lunch:
        return AppColors.categorySage;
      case FoodCategory.dinner:
        return AppColors.categoryTerracotta;
      case FoodCategory.snack:
        return AppColors.categoryPlum;
      case FoodCategory.drink:
        return AppColors.categorySky;
    }
  }

  /// Assign category based on time of day
  static FoodCategory fromTime(DateTime time) {
    final hour = time.hour;
```


- [ ] **Step 5: Use the palette in the glass container**

In `lib/widgets/glass_container.dart`:

**Edit 1 of 2 — replace:**

```dart
import 'dart:ui';
import 'package:flutter/material.dart';

/// A frosted-glass container inspired by Apple's Liquid Glass design language.
///
/// Uses [BackdropFilter] with [ImageFilter.blur] to create a translucent,
/// frosted appearance. Adapts automatically to light and dark themes.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
```

**with:**

```dart
import 'dart:ui';
import 'package:flutter/material.dart';

import '../config/app_colors.dart';

/// A frosted-glass container inspired by Apple's Liquid Glass design language.
///
/// Uses [BackdropFilter] with [ImageFilter.blur] to create a translucent,
/// frosted appearance. Adapts automatically to light and dark themes.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
```

**Edit 2 of 2 — replace:**

```dart
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isLight = brightness == Brightness.light;

    final fillColor = isLight
        ? Colors.white.withValues(alpha: 0.6)
        : const Color(0xFF252019).withValues(alpha: 0.4);
    final borderColor = isLight
        ? Colors.white.withValues(alpha: 0.2)
        : const Color(0xFFF5EFE8).withValues(alpha: 0.08);

    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
```

**with:**

```dart
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isLight = brightness == Brightness.light;

    final fillColor = isLight
        ? Colors.white.withValues(alpha: 0.6)
        : AppColors.darkSurface.withValues(alpha: 0.4);
    final borderColor = isLight
        ? Colors.white.withValues(alpha: 0.2)
        : AppColors.lightInk.withValues(alpha: 0.08);

    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
```


- [ ] **Step 6: Use the palette for the progress track**

In `lib/main.dart`:

**Edit 1 of 1 — replace:**

```dart
                              child: LinearProgressIndicator(
                                value: (totalCarbs / dailyCarbGoal!)
                                    .clamp(0.0, 1.0),
                                minHeight: 8,
                                backgroundColor: isDark
                                    ? AppColors.darkBorderMedium
                                    : const Color(0xFFE5E7EB),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  totalCarbs > dailyCarbGoal!
                                      ? AppColors.terracotta
                                      : AppColors.sage,
                                ),
                              ),
```

**with:**

```dart
                              child: LinearProgressIndicator(
                                value: (totalCarbs / dailyCarbGoal!)
                                    .clamp(0.0, 1.0),
                                minHeight: 8,
                                backgroundColor: isDark
                                    ? AppColors.darkBorderMedium
                                    : AppColors.progressTrack,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  totalCarbs > dailyCarbGoal!
                                      ? AppColors.terracotta
                                      : AppColors.sage,
                                ),
                              ),
```


- [ ] **Step 7: Prove the guard bites**

Temporarily change `AppColors.categorySage` to `AppColors.sage` in `lib/models/food_item.dart` and run `flutter test test/palette_test.dart`.
Expected: FAIL on `every food category keeps the color it had` — the two colours differ. Change it back and re-run: PASS.

- [ ] **Step 8: Check no literals are left**

Run: `grep -rnE "Color\(0x[0-9A-Fa-f]{8}\)" lib/ | grep -v "lib/config/app_colors.dart" | wc -l`
Expected: `0`

- [ ] **Step 9: Run everything**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` and all tests pass (182 at this point).

- [ ] **Step 10: Commit**

```bash
git add lib/config/app_colors.dart lib/models/food_item.dart lib/main.dart lib/widgets/glass_container.dart test/palette_test.dart
git commit -m "refactor: name the colours that were loose in view code"
```

---

### Task 3: A purchase listener that outlives the screen

This is the substance of the batch. Read the spec's Part 1 before starting: `docs/superpowers/specs/2026-09-23-purchase-reliability-design.md`.

Today the only two `purchaseStream` listeners are created inside `purchasePlan` and `restorePremiumPlan` and cancelled when those return, so a transaction arriving outside those windows is seen by nobody and never completed — while the user has been charged. The 90-second timeout, Ask to Buy approval, and StoreKit re-delivery after a crash all land in that gap.

The file is replaced wholesale. The parts that already worked — `_validateReceipt`'s HTTP call, `productIdForPlan`, `planForProductId`, `queryPremiumProducts` — are carried over unchanged except that validation failures now distinguish *rejected* from *unreachable*.

**Files:**
- Replace: `lib/services/purchase_service.dart`
- Test: `test/purchase_service_test.dart`

**Interfaces:**
- Consumes: `PremiumService.setPremiumEnabled(bool, {String? plan})`, `PremiumService.monthlyPlan`, `PremiumService.yearlyPlan`.
- Produces:
  - `PurchaseService.instance` — the singleton everything must use.
  - `void PurchaseService.start()` — begins listening; safe to call twice.
  - `Stream<PurchaseOutcome> get outcomes`.
  - `class PurchaseOutcome` with `plan`, `message`, `isGranted`, `unattended`.
  - `class ReceiptRejected implements Exception` with `message`.
  - `typedef ReceiptValidator`.
  - `Future<bool> purchasePlan(String plan)` and `Future<String?> restorePremiumPlan()`, unchanged signatures.

- [ ] **Step 1: Write the failing tests**

Create `test/purchase_service_test.dart`:

```dart
import 'dart:async';

import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/services/premium_service.dart';
import 'package:carb_tracker/services/purchase_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the purchase stream by hand. Only the three members the service
/// uses are implemented; anything else would be a test asserting on a stub.
class FakeIap implements InAppPurchase {
  final StreamController<List<PurchaseDetails>> controller =
      StreamController<List<PurchaseDetails>>.broadcast();
  final List<PurchaseDetails> completed = <PurchaseDetails>[];
  int restoreCalls = 0;
  bool buyStarts = true;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => controller.stream;

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase);
  }

  @override
  Future<void> restorePurchases({String? applicationUserName}) async {
    restoreCalls++;
  }

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async {
    return ProductDetailsResponse(
      productDetails: [
        for (final id in ids)
          ProductDetails(
            id: id,
            title: id,
            description: id,
            price: '\$1.00',
            rawPrice: 1,
            currencyCode: 'USD',
          ),
      ],
      notFoundIDs: const <String>[],
    );
  }

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    return buyStarts;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

/// Emits auth states on demand. `currentUser` is a flag rather than a real
/// User because the service only ever asks whether a token can be had.
class FakeAuth implements FirebaseAuth {
  final StreamController<User?> controller =
      StreamController<User?>.broadcast();
  bool signedIn = false;

  @override
  Stream<User?> authStateChanges() => controller.stream;

  @override
  User? get currentUser => signedIn ? _StubUser() : null;

  void signIn() {
    signedIn = true;
    controller.add(_StubUser());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

class _StubUser implements User {
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'token';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

PurchaseDetails purchase(
  String productId, {
  PurchaseStatus status = PurchaseStatus.purchased,
  String id = 'tx-1',
  bool pendingComplete = true,
  IAPError? error,
}) {
  final details = PurchaseDetails(
    purchaseID: id,
    productID: productId,
    verificationData: PurchaseVerificationData(
      localVerificationData: 'local',
      serverVerificationData: 'receipt',
      source: 'app_store',
    ),
    transactionDate: '0',
    status: status,
  );
  details.pendingCompletePurchase = pendingComplete;
  if (error != null) details.error = error;
  return details;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeIap iap;
  late FakeAuth auth;
  late PremiumService premium;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    iap = FakeIap();
    auth = FakeAuth();
    premium = PremiumService();
  });

  PurchaseService build({
    ReceiptValidator? validator,
    bool signedIn = true,
    Duration? purchaseTimeout,
  }) {
    auth.signedIn = signedIn;
    final service = PurchaseService(
      iap: iap,
      premiumService: premium,
      auth: auth,
      validator: validator ??
          (p, {required idToken, expectedProductId}) async => p.productID,
      purchaseTimeout: purchaseTimeout,
    );
    service.start();
    addTearDown(service.dispose);
    return service;
  }

  Future<bool> isPremiumStored() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(StorageKeys.isPremium) ?? false;
  }

  test('a purchase nobody is waiting for still unlocks premium', () async {
    // Ask to Buy approved hours later, or re-delivered at the next launch.
    // Before the lifetime listener there was nothing subscribed at this
    // moment, so the user stayed charged and un-upgraded.
    final service = build();
    final outcomes = <PurchaseOutcome>[];
    service.outcomes.listen(outcomes.add);

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();

    expect(await isPremiumStored(), isTrue);
    expect(premium.premiumPlan, PremiumService.monthlyPlan);
    expect(iap.completed, hasLength(1));
    expect(outcomes.single.isGranted, isTrue);
    expect(outcomes.single.unattended, isTrue,
        reason: 'no waiter, so the app should announce it');
  });

  test('a purchase that cannot be validated yet is kept, not completed',
      () async {
    // Completing here would drop the transaction from StoreKit's queue with
    // the receipt unchecked — the one unrecoverable mistake in this file.
    final service = build(signedIn: false);
    final outcomes = <PurchaseOutcome>[];
    service.outcomes.listen(outcomes.add);

    iap.controller.add([purchase(PurchaseService.yearlyProductId)]);
    await pumpEventQueue();

    expect(iap.completed, isEmpty);
    expect(await isPremiumStored(), isFalse);
    expect(outcomes, isEmpty);

    auth.signIn();
    await pumpEventQueue();

    expect(await isPremiumStored(), isTrue);
    expect(premium.premiumPlan, PremiumService.yearlyPlan);
    expect(iap.completed, hasLength(1));
  });

  test('an unreachable validator keeps the transaction too', () async {
    // A network blip is not evidence about the receipt.
    build(
      validator: (p, {required idToken, expectedProductId}) async =>
          throw Exception('connection failed'),
    );

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();

    expect(iap.completed, isEmpty);
    expect(await isPremiumStored(), isFalse);
  });

  test('a receipt the server rejects finishes the transaction', () async {
    // Unlike a network failure, this will never become valid, so leaving it
    // in the queue would re-deliver it forever.
    build(
      validator: (p, {required idToken, expectedProductId}) async =>
          throw ReceiptRejected('No active subscription.'),
    );

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();

    expect(iap.completed, hasLength(1));
    expect(await isPremiumStored(), isFalse);
  });

  test('a confirmation after the waiter gave up still unlocks premium',
      () async {
    // The whole point of the lifetime listener: the timeout bounds the wait,
    // not the purchase. Before, `finally` cancelled the only subscription, so
    // a confirmation arriving after it was seen by nobody.
    final service = build(purchaseTimeout: const Duration(milliseconds: 50));

    await expectLater(
      service.purchasePlan(PremiumService.monthlyPlan),
      throwsA(isA<Exception>()),
    );
    expect(await isPremiumStored(), isFalse);

    // The App Store confirms late.
    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();

    expect(await isPremiumStored(), isTrue);
    expect(iap.completed, hasLength(1));
  });

  test('a restore cannot run while a purchase is in flight', () async {
    // Two flows meant two listeners on one stream, both completing the same
    // transaction. The lock now lives on the single instance.
    final service = build();
    final purchasing = service.purchasePlan(PremiumService.monthlyPlan);

    await expectLater(
      service.restorePremiumPlan(),
      throwsA(isA<Exception>()),
    );

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    expect(await purchasing, isTrue);
  });

  test('a failed transaction is completed and reported, not left hanging',
      () async {
    final service = build();
    final outcomes = <PurchaseOutcome>[];
    service.outcomes.listen(outcomes.add);

    iap.controller.add([
      purchase(
        PurchaseService.monthlyProductId,
        status: PurchaseStatus.error,
        error: IAPError(
          source: 'app_store',
          code: 'failed',
          message: 'Your card was declined.',
        ),
      )
    ]);
    await pumpEventQueue();

    expect(iap.completed, hasLength(1));
    expect(outcomes.single.isGranted, isFalse);
    expect(outcomes.single.message, 'Your card was declined.');
  });

  test('a pending transaction waits without being completed', () async {
    // Ask to Buy: it comes back as purchased or error when it resolves.
    build();

    iap.controller.add([
      purchase(PurchaseService.monthlyProductId,
          status: PurchaseStatus.pending)
    ]);
    await pumpEventQueue();

    expect(iap.completed, isEmpty);
    expect(await isPremiumStored(), isFalse);
  });
}
```

- [ ] **Step 2: Run them to watch them fail**

Run: `flutter test test/purchase_service_test.dart`
Expected: FAIL to compile — `ReceiptValidator`, `PurchaseOutcome`, `ReceiptRejected`, `PurchaseService.instance` and `start()` do not exist yet.

- [ ] **Step 3: Replace the service**

Replace the whole of `lib/services/purchase_service.dart` with:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'premium_service.dart';

/// The server checked the receipt and said no.
///
/// Distinct from being unable to reach the server. A rejected receipt will
/// never become valid, so its transaction is finished; an unreachable server
/// says nothing about the receipt, so that transaction must be left alone.
class ReceiptRejected implements Exception {
  ReceiptRejected(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What became of one transaction.
///
/// [unattended] is the case this whole class exists for: a purchase that
/// finished with no screen waiting on it — approved through Ask to Buy hours
/// later, or re-delivered by StoreKit at the next launch.
class PurchaseOutcome {
  const PurchaseOutcome.granted(this.plan, {this.unattended = false})
      : message = null,
        isGranted = true;

  const PurchaseOutcome.failed(this.message, {this.unattended = false})
      : plan = null,
        isGranted = false;

  final String? plan;
  final String? message;
  final bool isGranted;
  final bool unattended;
}

/// Validates a receipt with the server. Injectable so tests can drive the
/// listener without a network.
typedef ReceiptValidator = Future<String?> Function(
  PurchaseDetails purchase, {
  required String idToken,
  String? expectedProductId,
});

class PurchaseService {
  PurchaseService({
    InAppPurchase? iap,
    PremiumService? premiumService,
    FirebaseAuth? auth,
    ReceiptValidator? validator,
    Duration? purchaseTimeout,
    Duration? restoreTimeout,
  })  : _iap = iap ?? InAppPurchase.instance,
        _premium = premiumService ?? PremiumService(),
        _authOverride = auth,
        _purchaseTimeout = purchaseTimeout ?? purchaseWaitTimeout,
        _restoreTimeout = restoreTimeout ?? restoreWaitTimeout {
    _validate = validator ?? _validateReceiptOverHttp;
  }

  /// The one instance that owns the purchase stream. Anything that needs to
  /// buy, restore, or hear about a purchase uses this — a second instance
  /// would mean a second listener completing the same transactions, and a
  /// lock that no longer guards anything.
  static final PurchaseService instance = PurchaseService();

  static const String monthlyProductId = 'premium_monthlysub';
  static const String yearlyProductId = 'premium_yearly';

  static const String _validateUrl =
      'https://us-central1-carpecarb.cloudfunctions.net/validateAppStoreReceipt';

  /// Bounds the wait for a purchase the user is watching, not the purchase
  /// itself: on timeout the waiter gives up and the listener stays, so a
  /// confirmation that arrives later still grants premium.
  static const Duration purchaseWaitTimeout = Duration(seconds: 90);
  static const Duration restoreWaitTimeout = Duration(seconds: 20);

  final InAppPurchase _iap;
  final PremiumService _premium;
  /// Resolved on use, not in the constructor: `SettingsPage` builds a
  /// service as a field initializer, and touching `FirebaseAuth.instance`
  /// there throws in any test that has not initialized Firebase.
  final FirebaseAuth? _authOverride;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  final Duration _purchaseTimeout;
  final Duration _restoreTimeout;
  late final ReceiptValidator _validate;

  final StreamController<PurchaseOutcome> _outcomes =
      StreamController<PurchaseOutcome>.broadcast();

  /// Every transaction's result, whether or not anything was waiting for it.
  Stream<PurchaseOutcome> get outcomes => _outcomes.stream;

  StreamSubscription<List<PurchaseDetails>>? _purchases;
  StreamSubscription<User?>? _authChanges;

  /// Transactions seen while the receipt could not be checked. They are not
  /// completed, so StoreKit keeps them and re-delivers them at the next
  /// launch; this list is the in-session retry.
  final List<PurchaseDetails> _held = <PurchaseDetails>[];

  Completer<String>? _waiter;
  String? _waitingForProductId;
  bool _flowInProgress = false;

  Set<String> get _productIds => {monthlyProductId, yearlyProductId};

  /// Begins listening, for the lifetime of the app. Safe to call twice.
  void start() {
    if (_purchases != null) return;

    _purchases = _iap.purchaseStream.listen(
      _handlePurchases,
      onError: (Object e) => _report(
        PurchaseOutcome.failed('Purchase stream error: $e'),
      ),
      cancelOnError: false,
    );

    // A transaction re-delivered at launch can arrive before anonymous
    // sign-in finishes, and a receipt cannot be checked without a token.
    _authChanges = _auth.authStateChanges().listen((user) {
      if (user != null) _retryHeld();
    });
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _purchases?.cancel();
    await _authChanges?.cancel();
    _purchases = null;
    _authChanges = null;
    await _outcomes.close();
  }

  Future<bool> isStoreAvailable() {
    return _iap.isAvailable();
  }

  Future<Map<String, ProductDetails>> queryPremiumProducts() async {
    final response = await _iap.queryProductDetails(_productIds);
    if (response.error != null) {
      throw Exception(response.error!.message);
    }

    return {
      for (final product in response.productDetails) product.id: product,
    };
  }

  String productIdForPlan(String plan) {
    if (plan == PremiumService.monthlyPlan) return monthlyProductId;
    if (plan == PremiumService.yearlyPlan) return yearlyProductId;
    throw ArgumentError('Unknown premium plan: $plan');
  }

  String? planForProductId(String productId) {
    if (productId == monthlyProductId) return PremiumService.monthlyPlan;
    if (productId == yearlyProductId) return PremiumService.yearlyPlan;
    return null;
  }

  Future<bool> purchasePlan(String plan) async {
    if (_flowInProgress) {
      throw Exception('A purchase is already in progress.');
    }
    _flowInProgress = true;

    try {
      final productId = productIdForPlan(plan);
      final products = await queryPremiumProducts();
      final product = products[productId];
      if (product == null) {
        throw Exception('Product not found in App Store Connect: $productId');
      }

      final waiter = Completer<String>();
      _waiter = waiter;
      _waitingForProductId = productId;

      final started = await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
      if (!started) {
        throw Exception('Could not start App Store purchase flow.');
      }

      try {
        return await waiter.future.timeout(_purchaseTimeout) == plan;
      } on TimeoutException {
        // The listener outlives this wait, so a late confirmation still
        // validates and unlocks premium without the user doing anything.
        throw Exception(
          'The App Store is taking longer than usual to confirm. If you were '
          'charged, premium unlocks as soon as it does.',
        );
      }
    } finally {
      _waiter = null;
      _waitingForProductId = null;
      _flowInProgress = false;
    }
  }

  Future<String?> restorePremiumPlan() async {
    if (_flowInProgress) {
      throw Exception('A purchase is already in progress.');
    }
    _flowInProgress = true;

    try {
      final waiter = Completer<String>();
      _waiter = waiter;
      _waitingForProductId = null;

      await _iap.restorePurchases();

      try {
        return await waiter.future.timeout(_restoreTimeout);
      } on TimeoutException {
        return null;
      }
    } finally {
      _waiter = null;
      _waitingForProductId = null;
      _flowInProgress = false;
    }
  }

  Future<void> _handlePurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      await _handlePurchase(purchase);
    }
  }

  Future<void> _handlePurchase(PurchaseDetails purchase) async {
    if (planForProductId(purchase.productID) == null) return;

    switch (purchase.status) {
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        await _grant(purchase);
      case PurchaseStatus.error:
      case PurchaseStatus.canceled:
        await _complete(purchase);
        _report(PurchaseOutcome.failed(_messageFor(purchase)));
      case PurchaseStatus.pending:
        // Awaiting approval — Ask to Buy, or a bank confirmation. It arrives
        // again as purchased or error, whenever that happens.
        break;
    }
  }

  Future<void> _grant(PurchaseDetails purchase) async {
    final idToken = await _idToken();
    if (idToken == null) {
      _hold(purchase);
      return;
    }

    final String? validatedProductId;
    try {
      validatedProductId = await _validate(
        purchase,
        idToken: idToken,
        expectedProductId: _waitingForProductId,
      );
    } on ReceiptRejected catch (e) {
      // The receipt is not going to become valid, so let the transaction go.
      await _complete(purchase);
      _report(PurchaseOutcome.failed(e.message));
      return;
    } catch (e) {
      // Could not reach the validator. Completing here would drop a
      // transaction the user may have paid for, so hold it instead.
      _hold(purchase);
      _report(PurchaseOutcome.failed(
        'Could not verify the App Store purchase right now.',
      ));
      return;
    }

    final plan =
        validatedProductId == null ? null : planForProductId(validatedProductId);
    await _complete(purchase);

    if (plan == null) {
      _report(PurchaseOutcome.failed(
        'The App Store receipt was valid but not for a CarpeCarb plan.',
      ));
      return;
    }

    await _premium.setPremiumEnabled(true, plan: plan);
    _report(PurchaseOutcome.granted(plan));
  }

  /// Keeps a transaction for a later attempt without completing it.
  void _hold(PurchaseDetails purchase) {
    final already = _held.any((p) =>
        p.purchaseID == purchase.purchaseID &&
        p.productID == purchase.productID);
    if (!already) _held.add(purchase);
  }

  Future<void> _retryHeld() async {
    if (_held.isEmpty) return;
    final pending = List<PurchaseDetails>.from(_held);
    _held.clear();
    for (final purchase in pending) {
      await _grant(purchase);
    }
  }

  /// Hands the result to whoever is waiting, and tells everyone else.
  ///
  /// An outcome nobody was waiting for is the interesting one: it means the
  /// purchase landed while the user was somewhere else entirely.
  void _report(PurchaseOutcome outcome) {
    final waiter = _waiter;
    final wanted = _waitingForProductId;
    final matches = waiter != null &&
        !waiter.isCompleted &&
        (wanted == null ||
            outcome.plan == null ||
            planForProductId(wanted) == outcome.plan);

    if (matches) {
      if (outcome.isGranted) {
        waiter.complete(outcome.plan);
      } else {
        waiter.completeError(Exception(outcome.message));
      }
      _emit(outcome);
      return;
    }

    _emit(outcome.isGranted
        ? PurchaseOutcome.granted(outcome.plan, unattended: true)
        : PurchaseOutcome.failed(outcome.message, unattended: true));
  }

  void _emit(PurchaseOutcome outcome) {
    if (!_outcomes.isClosed) _outcomes.add(outcome);
  }

  Future<void> _complete(PurchaseDetails purchase) async {
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
  }

  String _messageFor(PurchaseDetails purchase) {
    if (purchase.status == PurchaseStatus.canceled) {
      return 'Purchase was canceled in App Store.';
    }
    final message = purchase.error?.message.trim();
    return message == null || message.isEmpty
        ? 'App Store reported a purchase error.'
        : message;
  }

  Future<String?> _idToken() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return null;
      return token;
    } catch (e) {
      // Treated as "no token yet", not as a bad receipt.
      return null;
    }
  }

  Future<String?> _validateReceiptOverHttp(
    PurchaseDetails purchase, {
    required String idToken,
    String? expectedProductId,
  }) async {
    final receiptData = purchase.verificationData.serverVerificationData;
    if (receiptData.isEmpty) {
      throw ReceiptRejected('App Store receipt data is missing.');
    }

    final body = jsonEncode({
      'data': {
        'receiptData': receiptData,
        if (expectedProductId != null) 'expectedProductId': expectedProductId,
      }
    });

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.postUrl(Uri.parse(_validateUrl));
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Authorization', 'Bearer $idToken');
      request.write(body);

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final responseBody = await response.transform(utf8.decoder).join();

      if (kDebugMode) {
        debugPrint('validateAppStoreReceipt HTTP ${response.statusCode}');
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Exception(
          'Receipt verification blocked. Check Cloud Function permissions.',
        );
      }

      if (response.statusCode != 200) {
        throw Exception('Could not verify App Store purchase right now.');
      }

      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      final data = (json['result'] ?? json['data']) as Map<String, dynamic>?;

      if (data == null) {
        throw Exception('Could not verify App Store purchase right now.');
      }

      if (data['isValid'] != true) {
        final reason = data['reason']?.toString();
        if (reason == 'product-mismatch') {
          final found = data['productId']?.toString() ?? 'unknown';
          throw ReceiptRejected(
            'Receipt was valid but for a different product ($found).',
          );
        }
        if (reason == 'no-active-subscription') {
          throw ReceiptRejected(
            'No active subscription was found in the App Store receipt.',
          );
        }
        throw ReceiptRejected(
          'Receipt validation failed (${reason ?? 'unknown'}).',
        );
      }

      final productId = data['productId']?.toString();
      if (productId == null || productId.isEmpty) return null;
      return productId;
    } finally {
      client.close();
    }
  }
}
```

Two things in here are load-bearing and easy to "simplify" into bugs:

- `_authOverride` is resolved through a getter rather than in the constructor. `SettingsPage` builds a `PurchaseService` as a field initializer, so touching `FirebaseAuth.instance` in the constructor throws `[core/no-app]` in every widget test that builds that page.
- `_hold` is used for *both* "no token yet" and "could not reach the validator". Neither says anything about whether the receipt is good, so neither may complete the transaction.

- [ ] **Step 4: Run the tests**

Run: `flutter test test/purchase_service_test.dart`
Expected: PASS, 8 tests.

- [ ] **Step 5: Prove the tests bite**

Money code earns three mutations. Apply each, run `flutter test test/purchase_service_test.dart`, then revert it.

1. In `_grant`, change the no-token branch from `_hold(purchase);` to `await _complete(purchase);`
   Expected: FAIL — `a purchase that cannot be validated yet is kept, not completed`.
2. In `_grant`'s final `catch`, replace `_hold(purchase);` with `await _complete(purchase);`
   Expected: FAIL — `an unreachable validator keeps the transaction too`.
3. In `purchasePlan`'s `finally`, add `await _purchases?.cancel(); _purchases = null;` — this reproduces the original bug.
   Expected: FAIL — `a confirmation after the waiter gave up still unlocks premium`.

- [ ] **Step 6: Run everything**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` and all tests pass (190 at this point).

- [ ] **Step 7: Commit**

```bash
git add lib/services/purchase_service.dart test/purchase_service_test.dart
git commit -m "fix(purchase): keep listening after the screen stops waiting"
```

---

### Task 4: Wire the singleton in

The listener has to be started, the screen has to stop making its own service, and a grant that arrives unattended has to be visible to the user.

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/screens/settings_page.dart`

**Interfaces:**
- Consumes: everything Task 3 produced.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Start the listener and announce late grants**

In `lib/main.dart`:

**Edit 1 of 6 — replace:**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:keyboard_actions/keyboard_actions.dart';
```

**with:**

```dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:keyboard_actions/keyboard_actions.dart';
```

**Edit 2 of 6 — replace:**

```dart
import 'dart:convert';
import 'dart:io';
import 'services/lookup_api.dart';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_buffer_service.dart';
import 'services/siri_import.dart';
import 'services/sync_merge.dart';
import 'services/sync_payload.dart';
import 'services/sync_store.dart';
```

**with:**

```dart
import 'dart:convert';
import 'dart:io';
import 'services/lookup_api.dart';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/purchase_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_buffer_service.dart';
import 'services/siri_import.dart';
import 'services/sync_merge.dart';
import 'services/sync_payload.dart';
import 'services/sync_store.dart';
```

**Edit 3 of 6 — replace:**

```dart
      // Auth failure is non-fatal — the app works without it, but Cloud
      // Functions will reject requests until this is resolved.
      if (kDebugMode) debugPrint('Anonymous sign-in failed: $e');
    }
  }

  // Initialize HomeWidget for iOS widget data sharing
  HomeWidget.setAppGroupId(StorageKeys.appGroupId);

  runApp(const CarbTrackerApp());
}
```

**with:**

```dart
      // Auth failure is non-fatal — the app works without it, but Cloud
      // Functions will reject requests until this is resolved.
      if (kDebugMode) debugPrint('Anonymous sign-in failed: $e');
    }
  }

  // Listen for App Store transactions for as long as the app runs. Started
  // here rather than from a screen because the transactions that matter most
  // are the ones that arrive when no screen is waiting: an Ask to Buy approved
  // hours later, or one StoreKit re-delivers after a crash.
  PurchaseService.instance.start();

  // Initialize HomeWidget for iOS widget data sharing
  HomeWidget.setAppGroupId(StorageKeys.appGroupId);

  runApp(const CarbTrackerApp());
}
```

**Edit 4 of 6 — replace:**

```dart
  final FocusNode _carbFocusNode = FocusNode();
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final PerplexityFirebaseService _perplexityService =
      PerplexityFirebaseService();
  final HealthKitService _healthKitService = HealthKitService();
  final PremiumService _premiumService = PremiumService();
  final CloudSyncService _cloudSyncService = CloudSyncService();
  final SyncStore _syncStore = SyncStore();

  final SiriBufferService _siriBuffer = SiriBufferService();
  bool _isManualEntryMode = false;
```

**with:**

```dart
  final FocusNode _carbFocusNode = FocusNode();
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final PerplexityFirebaseService _perplexityService =
      PerplexityFirebaseService();
  final HealthKitService _healthKitService = HealthKitService();
  final PremiumService _premiumService = PremiumService();
  StreamSubscription<PurchaseOutcome>? _purchaseOutcomes;
  final CloudSyncService _cloudSyncService = CloudSyncService();
  final SyncStore _syncStore = SyncStore();

  final SiriBufferService _siriBuffer = SiriBufferService();
  bool _isManualEntryMode = false;
```

**Edit 5 of 6 — replace:**

```dart
        _healthKitService.requestAuthorization();
      }
      _initCloudSync();
    });
    _loadSavedData();
    _checkWidgetLaunch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowDisclaimer();
    });
  }

  Future<void> _maybeShowDisclaimer() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(StorageKeys.disclaimerAccepted) == true) {
      if (mounted) _foodFocusNode.requestFocus();
      return;
    }
```

**with:**

```dart
        _healthKitService.requestAuthorization();
      }
      _initCloudSync();
    });
    _loadSavedData();
    _checkWidgetLaunch();
    _watchForLatePurchases();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowDisclaimer();
    });
  }

  /// Tells the user about a purchase that unlocked itself.
  ///
  /// A transaction can land with nothing waiting on it — Ask to Buy approved
  /// later, or StoreKit re-delivering one after a crash. PurchaseService has
  /// already granted premium by this point; without this the paywall would
  /// just silently disappear for someone who was charged days ago.
  void _watchForLatePurchases() {
    _purchaseOutcomes = PurchaseService.instance.outcomes.listen((outcome) {
      if (!outcome.isGranted || !outcome.unattended || !mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your App Store purchase went through — premium is '
              'now active.'),
          duration: Duration(seconds: 4),
        ),
      );
    });
  }

  Future<void> _maybeShowDisclaimer() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(StorageKeys.disclaimerAccepted) == true) {
      if (mounted) _foodFocusNode.requestFocus();
      return;
    }
```

**Edit 6 of 6 — replace:**

```dart
  @override
  void dispose() {
    _loadSavedDataToken++;
    _importSiriItemsToken++;
    WidgetsBinding.instance.removeObserver(this);
    _cloudSyncService.stopListening();
    _foodController.dispose();
    _carbController.dispose();
    _foodFocusNode.dispose();
    _carbFocusNode.dispose();
    super.dispose();
  }
```

**with:**

```dart
  @override
  void dispose() {
    _loadSavedDataToken++;
    _importSiriItemsToken++;
    WidgetsBinding.instance.removeObserver(this);
    _cloudSyncService.stopListening();
    _purchaseOutcomes?.cancel();
    _foodController.dispose();
    _carbController.dispose();
    _foodFocusNode.dispose();
    _carbFocusNode.dispose();
    super.dispose();
  }
```


- [ ] **Step 2: Use the singleton and stop granting from the screen**

In `lib/screens/settings_page.dart`:

**Edit 1 of 3 — replace:**

```dart

class _SettingsPageState extends State<SettingsPage> {
  late int _selectedTab;
  int _savedFoodsLoadToken = 0;
  int _historyLoadToken = 0;
  int _macroGoalsLoadToken = 0;
  final PurchaseService _purchaseService = PurchaseService();
  Map<String, dynamic> _premiumProducts = {};

  // Goal state
  late TextEditingController _goalController;
  late int _resetHour;
  String? _goalError;
```

**with:**

```dart

class _SettingsPageState extends State<SettingsPage> {
  late int _selectedTab;
  int _savedFoodsLoadToken = 0;
  int _historyLoadToken = 0;
  int _macroGoalsLoadToken = 0;
  // The singleton, not a new one: a second instance would mean a second
  // listener completing the same transactions, and a lock guarding nothing.
  final PurchaseService _purchaseService = PurchaseService.instance;
  Map<String, dynamic> _premiumProducts = {};

  // Goal state
  late TextEditingController _goalController;
  late int _resetHour;
  String? _goalError;
```

**Edit 2 of 3 — replace:**

```dart
          );
          setState(() {});
        }
        return;
      }

      await ps?.setPremiumEnabled(true, plan: plan);
      await widget.onCloudSyncEnabled?.call();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Welcome to CarpeCarb! ${_planLabel(plan)} is now active.'),
```

**with:**

```dart
          );
          setState(() {});
        }
        return;
      }

      // PurchaseService granted this before it answered — it is the only
      // thing that sees transactions arriving with no screen waiting.
      await widget.onCloudSyncEnabled?.call();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Welcome to CarpeCarb! ${_planLabel(plan)} is now active.'),
```

**Edit 3 of 3 — replace:**

```dart
            content: Text('No active subscription found to restore.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
      await ps?.setPremiumEnabled(true, plan: restoredPlan);
      await widget.onCloudSyncEnabled?.call();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Restored ${_planLabel(restoredPlan)} plan.'),
```

**with:**

```dart
            content: Text('No active subscription found to restore.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
      await widget.onCloudSyncEnabled?.call();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Restored ${_planLabel(restoredPlan)} plan.'),
```


The two removed `setPremiumEnabled` calls are deliberate. `PurchaseService` grants before it answers, so by the time `purchasePlan` returns the plan is already stored; granting again from the screen only re-establishes the pattern that cannot see unattended transactions.

- [ ] **Step 2b: Confirm the screen no longer grants**

Run: `grep -n "setPremiumEnabled" lib/screens/settings_page.dart`
Expected: no output.

- [ ] **Step 3: Run everything**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` and all tests pass (190).

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart lib/screens/settings_page.dart
git commit -m "fix(purchase): start the listener at launch, grant from one place"
```

---

### Task 5: Entitlements the app does not use

`Runner.entitlements` claims push notifications, CloudKit, CloudDocuments and two iCloud containers. There is no push code anywhere, and sync is `NSUbiquitousKeyValueStore` only — which needs `ubiquity-kvstore-identifier` and none of the container keys. `Runneralpha.entitlements` is referenced by no build configuration and carries a *different*, hardcoded kvstore identifier, so leaving it invites someone to wire up the wrong one.

This goes last and alone because entitlements drive provisioning and signing, and it is the item most likely to need reverting.

**Files:**
- Modify: `ios/Runner/Runner.entitlements`
- Delete: `ios/Runner/Runneralpha.entitlements`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Confirm nothing uses what you are about to remove**

```bash
grep -rniE "messaging|APNs|remoteNotification|firebase_messaging" lib/ ios/Runner/*.swift
grep -rn "CKContainer\|CloudKit\|forUbiquityContainerIdentifier" ios/ --include="*.swift"
grep -o "CODE_SIGN_ENTITLEMENTS = [^;]*" ios/Runner.xcodeproj/project.pbxproj | sort -u
```
Expected: no push hits; no CloudKit hits; and the third names only `Runner/Runner.entitlements`, the widget's and the Watch app's — confirming `Runneralpha.entitlements` is dead. If any of these come back differently, stop and report NEEDS_CONTEXT.

- [ ] **Step 2: Strip the unused keys**

In `ios/Runner/Runner.entitlements`:

**Edit 1 of 1 — replace:**

```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>production</string>
	<key>com.apple.developer.healthkit</key>
	<true/>
	<key>com.apple.developer.healthkit.access</key>
	<array/>
	<key>com.apple.developer.icloud-container-environment</key>
	<string>Production</string>
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array>
		<string>iCloud.com.jamesaguero.mycarbtracker</string>
	</array>
	<key>com.apple.developer.icloud-services</key>
	<array>
		<string>CloudKit</string>
		<string>CloudDocuments</string>
	</array>
	<key>com.apple.developer.siri</key>
	<true/>
	<key>com.apple.developer.ubiquity-container-identifiers</key>
	<array>
		<string>iCloud.com.jamesaguero.mycarbtracker</string>
	</array>
	<key>com.apple.developer.ubiquity-kvstore-identifier</key>
	<string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.carpecarb.shared</string>
	</array>
```

**with:**

```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.healthkit</key>
	<true/>
	<key>com.apple.developer.healthkit.access</key>
	<array/>
	<key>com.apple.developer.siri</key>
	<true/>
	<key>com.apple.developer.ubiquity-kvstore-identifier</key>
	<string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.carpecarb.shared</string>
	</array>
```


- [ ] **Step 3: Delete the dead file**

```bash
git rm ios/Runner/Runneralpha.entitlements
```

- [ ] **Step 4: Check the plist is still valid**

Run: `plutil -lint ios/Runner/Runner.entitlements`
Expected: `ios/Runner/Runner.entitlements: OK`

- [ ] **Step 5: Build for a device**

Run:
```bash
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/purchase-dd \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add ios/Runner/Runner.entitlements ios/Runner/Runneralpha.entitlements
git commit -m "chore(ios): drop entitlements the app doesn't use"
```

---

### Task 6: Device verification (James)

Nothing below can be checked by any test in this repo. The purchase paths need the sandbox, and the entitlements change needs two real devices.

- [ ] Buy a subscription in the StoreKit sandbox. Premium unlocks, and the transaction does not reappear at the next launch.
- [ ] Approve an **Ask to Buy** purchase after leaving the paywall. Premium unlocks on its own and the app says "Your App Store purchase went through — premium is now active." — without tapping Restore.
- [ ] Force-quit mid-purchase, then relaunch. The transaction is re-delivered, validated and granted.
- [ ] Turn off the network, buy, then turn it back on. The purchase is not lost: it is still granted once the validator is reachable.
- [ ] Restore on a second device grants premium.
- [ ] **After the entitlements change:** the app installs and runs on device, and iCloud sync still moves data between two devices.
