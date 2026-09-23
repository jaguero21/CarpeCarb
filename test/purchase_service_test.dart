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
