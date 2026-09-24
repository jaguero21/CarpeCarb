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

  /// StoreKit's `finishTransaction` is not guaranteed to succeed.
  bool completeThrows = false;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => controller.stream;

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    if (completeThrows) {
      throw Exception('could not finish the transaction');
    }
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

/// Storing premium can fail for real: a SharedPreferences write on a full
/// disk, or under iOS data protection while the device is locked.
class ThrowingPremiumService extends PremiumService {
  @override
  Future<void> setPremiumEnabled(bool value, {String? plan}) async {
    throw Exception('could not write premium state');
  }
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
    Duration? restoreTimeout,
    PremiumService? premiumService,
  }) {
    auth.signedIn = signedIn;
    final service = PurchaseService(
      iap: iap,
      premiumService: premiumService ?? premium,
      auth: auth,
      validator: validator ??
          (p, {required idToken, expectedProductId}) async => p.productID,
      purchaseTimeout: purchaseTimeout,
      restoreTimeout: restoreTimeout,
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

  test('a grant that cannot be stored keeps the transaction', () async {
    // Completing before storing premium means a failed write leaves the user
    // charged, un-upgraded, and with the transaction gone from the queue.
    final service = build(premiumService: ThrowingPremiumService());
    final outcomes = <PurchaseOutcome>[];
    service.outcomes.listen(outcomes.add);

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();

    expect(iap.completed, isEmpty,
        reason: 'the purchase is still owed to the user');
    expect(await isPremiumStored(), isFalse);
    expect(outcomes, isNotEmpty,
        reason: 'the failure must be reported, not thrown into the void');
    expect(outcomes.first.isGranted, isFalse);
  });

  test('a transaction is validated against its own product', () async {
    // The waiter's product is global state belonging to whichever purchase is
    // in flight. Asking the server about the wrong product manufactures a
    // mismatch, and that bogus rejection discards a good transaction.
    final expectations = <String?>[];
    final service = build(
      validator: (p, {required idToken, expectedProductId}) async {
        expectations.add(expectedProductId);
        return p.productID;
      },
    );

    final pending = service.purchasePlan(PremiumService.monthlyPlan);
    await pumpEventQueue();

    iap.controller.add([
      purchase(
        PurchaseService.yearlyProductId,
        status: PurchaseStatus.restored,
        id: 'tx-yearly',
      )
    ]);
    await pumpEventQueue();

    expect(expectations, [PurchaseService.yearlyProductId]);

    iap.controller
        .add([purchase(PurchaseService.monthlyProductId, id: 'tx-monthly')]);
    expect(await pending, isTrue);
  });

  test("a failure for one product does not answer another's waiter", () async {
    // Every failure outcome has a null plan, so matching on the plan let any
    // failure complete any waiter.
    final service = build();
    final pending = service.purchasePlan(PremiumService.monthlyPlan);
    await pumpEventQueue();

    iap.controller.add([
      purchase(
        PurchaseService.yearlyProductId,
        status: PurchaseStatus.error,
        id: 'tx-yearly',
        error: IAPError(
          source: 'app_store',
          code: 'failed',
          message: 'Yearly failed.',
        ),
      )
    ]);
    await pumpEventQueue();

    iap.controller
        .add([purchase(PurchaseService.monthlyProductId, id: 'tx-monthly')]);

    expect(await pending, isTrue,
        reason: "an unrelated yearly error must not answer the monthly buyer");
  });

  test('a transaction whose completion throws is still reported', () async {
    // Otherwise a declined card looks like a 90-second App Store stall.
    iap.completeThrows = true;
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

    expect(outcomes, isNotEmpty);
    expect(outcomes.first.isGranted, isFalse);
    expect(outcomes.first.message, 'Your card was declined.');
    // Exactly once. A `finally` that let the exception escape into the
    // listener's catch reported a second, generic failure on top of the real
    // reason, so a UI that toasts failures showed two for one declined card.
    expect(outcomes, hasLength(1));
    // And nothing is held: this transaction was never a purchase.
    expect(iap.completed, isEmpty);
  });

  test('a valid receipt with no usable product is kept, not finished',
      () async {
    // A response we cannot interpret is not the server rejecting the receipt,
    // so the transaction stays in the queue.
    final service = build(
      validator: (p, {required idToken, expectedProductId}) async => null,
    );
    final outcomes = <PurchaseOutcome>[];
    service.outcomes.listen(outcomes.add);

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();

    expect(iap.completed, isEmpty);
    expect(await isPremiumStored(), isFalse);
    expect(outcomes, isNotEmpty);
    expect(outcomes.first.isGranted, isFalse);
  });

  test('a held transaction that later succeeds is not granted again',
      () async {
    // The transaction is held while the validator is unreachable, then
    // succeeds through the ordinary listener path. Nothing pruned it from the
    // held list, so the next auth event granted it a second time — a second
    // completePurchase on a finished transaction, and a second "your purchase
    // went through" for something the user already saw confirmed.
    var reachable = false;
    final service = build(
      validator: (p, {required idToken, expectedProductId}) async {
        if (!reachable) throw Exception('connection failed');
        return p.productID;
      },
    );
    final outcomes = <PurchaseOutcome>[];
    service.outcomes.listen(outcomes.add);

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();
    expect(iap.completed, isEmpty, reason: 'held while unreachable');

    reachable = true;
    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();
    expect(iap.completed, hasLength(1));

    // Any later sign-in drains the held list.
    auth.signIn();
    await pumpEventQueue();

    expect(iap.completed, hasLength(1),
        reason: 'the finished transaction must not be completed twice');
    expect(outcomes.where((o) => o.isGranted), hasLength(1),
        reason: 'and must not be granted twice');
  });

  test('the same transaction arriving twice at once is handled once', () async {
    // `listen` does not await its handler, so two events overlap freely. The
    // same transaction in both means two validations of one receipt against a
    // rate-limited endpoint, and two grants.
    var calls = 0;
    final service = build(
      validator: (p, {required idToken, expectedProductId}) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return p.productID;
      },
    );
    final outcomes = <PurchaseOutcome>[];
    service.outcomes.listen(outcomes.add);

    final tx = purchase(PurchaseService.monthlyProductId);
    iap.controller.add([tx]);
    iap.controller.add([tx]);
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();

    expect(calls, 1, reason: 'one receipt, one validation');
    expect(iap.completed, hasLength(1));
    expect(outcomes.where((o) => o.isGranted), hasLength(1));
  });

  test('a held transaction is retried when the app comes back', () async {
    // Held while the validator was unreachable. Before, the only retries were
    // a sign-in or a relaunch, so a user who paid during a network blip and
    // simply returned to the app stayed without premium.
    var reachable = false;
    final service = build(
      validator: (p, {required idToken, expectedProductId}) async {
        if (!reachable) throw Exception('connection failed');
        return p.productID;
      },
    );

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();
    expect(iap.completed, isEmpty, reason: 'held while unreachable');

    // The network is back and the user returns to the app.
    reachable = true;
    await service.retryHeldTransactions();

    expect(await isPremiumStored(), isTrue);
    expect(iap.completed, hasLength(1));
  });

  test('retrying with nothing held does nothing', () async {
    final service = build();
    await service.retryHeldTransactions();
    expect(iap.completed, isEmpty);
  });

  test('one expired transaction does not fail a restore that finds a live one',
      () async {
    // Restore re-delivers every past transaction. An old, expired one can be
    // processed first; its rejection used to answer the whole restore with
    // "no active subscription", and then the live one granted premium anyway —
    // two contradictory messages, the first of them wrong.
    final service = build(
      validator: (p, {required idToken, expectedProductId}) async {
        if (p.purchaseID == 'old') {
          throw ReceiptRejected('No active subscription.');
        }
        return p.productID;
      },
    );

    final restoring = service.restorePremiumPlan();
    iap.controller.add([
      purchase(PurchaseService.monthlyProductId,
          status: PurchaseStatus.restored, id: 'old'),
      purchase(PurchaseService.yearlyProductId,
          status: PurchaseStatus.restored, id: 'current'),
    ]);

    expect(await restoring, PremiumService.yearlyPlan);
  });

  test('a restore that finds only expired transactions reports none found',
      () async {
    // Now that a rejection no longer answers a restore, "nothing active" is
    // reported by the timeout — null, which Settings shows as "No active
    // subscription found to restore."
    final service = build(
      restoreTimeout: const Duration(milliseconds: 50),
      validator: (p, {required idToken, expectedProductId}) async =>
          throw ReceiptRejected('No active subscription.'),
    );

    final restoring = service.restorePremiumPlan();
    iap.controller.add([
      purchase(PurchaseService.monthlyProductId,
          status: PurchaseStatus.restored, id: 'old'),
    ]);

    expect(await restoring, isNull);
    expect(iap.restoreCalls, 1);
  });

  test('a purchase the App Store will not start fails and frees the lock',
      () async {
    // If the lock stayed held, every later purchase would be refused with
    // "a purchase is already in progress" until the app was restarted.
    iap.buyStarts = false;
    final service = build();

    await expectLater(
      service.purchasePlan(PremiumService.monthlyPlan),
      throwsA(isA<Exception>()),
    );

    iap.buyStarts = true;
    final retrying = service.purchasePlan(PremiumService.monthlyPlan);
    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    expect(await retrying, isTrue);
  });

  test('a restore that cannot reach the validator says so, not "none found"',
      () async {
    // A paying user whose premium didn't unlock taps Restore while still
    // offline. Only a grant answers a restore, so this used to wait out the
    // timeout and report no subscription — false, and an invitation to buy
    // again or ask for a refund.
    final service = build(
      restoreTimeout: const Duration(milliseconds: 50),
      validator: (p, {required idToken, expectedProductId}) async =>
          throw Exception('connection failed'),
    );

    final restoring = service.restorePremiumPlan();
    iap.controller.add([
      purchase(PurchaseService.monthlyProductId,
          status: PurchaseStatus.restored),
    ]);

    await expectLater(restoring, throwsA(isA<Exception>()));
    expect(iap.completed, isEmpty, reason: 'held, not finished');
  });

  test('a retry does not process a transaction the listener already has',
      () async {
    // Resume retries held transactions while a restore's re-delivery of the
    // same one may still be validating. Two copies meant two validations
    // against a rate-limited endpoint and two "purchase went through" notices.
    var calls = 0;
    var reachable = false;
    final gate = Completer<void>();
    final service = build(
      validator: (p, {required idToken, expectedProductId}) async {
        calls++;
        if (!reachable) throw Exception('connection failed');
        await gate.future;
        return p.productID;
      },
    );
    final tx = purchase(PurchaseService.monthlyProductId);

    iap.controller.add([tx]);
    await pumpEventQueue();
    expect(calls, 1, reason: 'held after the first, failed attempt');

    // The network is back; the listener is re-validating it, and is slow.
    reachable = true;
    iap.controller.add([tx]);
    await pumpEventQueue();

    // The user comes back to the app mid-validation.
    final retry = service.retryHeldTransactions();
    gate.complete();
    await retry;
    await pumpEventQueue();

    expect(calls, 2, reason: 'one failed attempt, then exactly one more');
    expect(iap.completed, hasLength(1));
  });

  test('a retry that fails part-way keeps the transaction and does not throw',
      () async {
    // The retry used to have no catch: a failed prefs write escaped as an
    // unhandled error, and — the list having been cleared first — the rest of
    // the held transactions were dropped from the in-session retry.
    var reachable = false;
    final service = build(
      premiumService: ThrowingPremiumService(),
      validator: (p, {required idToken, expectedProductId}) async {
        if (!reachable) throw Exception('connection failed');
        return p.productID;
      },
    );

    iap.controller.add([purchase(PurchaseService.monthlyProductId)]);
    await pumpEventQueue();

    reachable = true;
    await service.retryHeldTransactions();

    expect(iap.completed, isEmpty, reason: 'grant failed, so still held');
  });
}
