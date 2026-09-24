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
  ///
  /// Only touch this on a device or simulator: it builds the real
  /// `InAppPurchase`, whose platform channel is not available in host tests.
  /// Tests construct their own `PurchaseService` with fakes instead.
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
  /// launch; within a session they are retried on resume and on sign-in.
  final List<PurchaseDetails> _held = <PurchaseDetails>[];

  /// Transactions being handled right now, so overlapping stream events
  /// cannot process the same one twice.
  final Set<String> _inFlight = <String>{};

  Completer<String>? _waiter;
  String? _waitingForProductId;
  bool _flowInProgress = false;
  bool _retrying = false;

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
    final error = response.error;
    if (error != null) {
      throw Exception(error.message);
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
        // Nothing granted. That only means "no active subscription" if every
        // transaction was actually checked. One held because its receipt
        // couldn't be verified — the user offline, say — means the answer is
        // unknown, and saying "none found" to someone who paid invites them to
        // buy again.
        if (_held.isNotEmpty) {
          throw Exception(
            "Couldn't reach the App Store to check your purchases. "
            'Try again when you are back online.',
          );
        }
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
      // `listen` does not await its handler, so two stream events overlap
      // freely. The same transaction in both would be validated twice against
      // a rate-limited endpoint and granted twice.
      final key = _keyFor(purchase);
      if (!_inFlight.add(key)) continue;
      try {
        await _handlePurchase(purchase);
      } catch (e) {
        // The listener must survive anything: an escaping error is unhandled,
        // and leaves whoever is waiting to time out with no explanation. Keep
        // the transaction — it has not been knowingly finished.
        _hold(purchase);
        _report(
          PurchaseOutcome.failed('Could not finish the App Store purchase.'),
          productId: purchase.productID,
        );
      } finally {
        _inFlight.remove(key);
      }
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
        // Report even if completing throws: the user is owed the real reason,
        // and a waiter left hanging turns a declined card into a 90s timeout.
        // Swallowed deliberately rather than rethrown — letting it escape put
        // a second, generic failure on top of the real one and held a
        // transaction that was never a purchase in the first place.
        try {
          await _complete(purchase);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Could not finish a failed transaction: $e');
          }
        }
        _report(
          PurchaseOutcome.failed(_messageFor(purchase)),
          productId: purchase.productID,
        );
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
        // The transaction's own product, never the waiter's: validating one
        // transaction against another's expectation manufactures a mismatch
        // and throws away a purchase that was fine.
        expectedProductId: purchase.productID,
      );
    } on ReceiptRejected catch (e) {
      // The receipt is not going to become valid, so let the transaction go.
      _unhold(purchase);
      await _complete(purchase);
      _report(PurchaseOutcome.failed(e.message), productId: purchase.productID);
      return;
    } catch (e) {
      // Could not reach the validator. Completing here would drop a
      // transaction the user may have paid for, so hold it instead.
      _hold(purchase);
      _report(
        PurchaseOutcome.failed(
          'Could not verify the App Store purchase right now.',
        ),
        productId: purchase.productID,
      );
      return;
    }

    final plan =
        validatedProductId == null ? null : planForProductId(validatedProductId);

    if (plan == null) {
      // The receipt checked out but the answer is not one we can act on — a
      // renamed field, a product we don't know. That is not the server
      // rejecting the receipt, so treat it like an unreachable validator and
      // keep the transaction rather than finishing it ungranted.
      _hold(purchase);
      _report(
        PurchaseOutcome.failed(
          'Could not read the App Store receipt. CarpeCarb will try again.',
        ),
        productId: purchase.productID,
      );
      return;
    }

    // Grant first, complete second. If completing fails, StoreKit re-delivers
    // and this runs again harmlessly; if granting fails after completing, the
    // purchase is gone with nothing to show for it.
    await _premium.setPremiumEnabled(true, plan: plan);
    // Finished: drop any earlier hold, or the next auth change would grant it
    // again and complete a transaction StoreKit has already closed.
    _unhold(purchase);
    await _complete(purchase);
    _report(PurchaseOutcome.granted(plan), productId: purchase.productID);
  }

  /// Identifies a transaction across re-deliveries of the same purchase.
  String _keyFor(PurchaseDetails purchase) =>
      '${purchase.purchaseID ?? ''}:${purchase.productID}';

  /// Keeps a transaction for a later attempt without completing it.
  void _hold(PurchaseDetails purchase) {
    final key = _keyFor(purchase);
    if (!_held.any((p) => _keyFor(p) == key)) _held.add(purchase);
  }

  /// Forgets a hold once the transaction has been finished for good.
  void _unhold(PurchaseDetails purchase) {
    final key = _keyFor(purchase);
    _held.removeWhere((p) => _keyFor(p) == key);
  }

  /// Retries anything held while its receipt couldn't be checked.
  ///
  /// Called when the app returns to the foreground. Without it the only
  /// retries were a sign-in or a relaunch, so a purchase held during a network
  /// blip stayed ungranted for a user who simply came back to the app. Safe to
  /// call on every resume: it does nothing when nothing is held, and it is not
  /// re-entrant.
  Future<void> retryHeldTransactions() => _retryHeld();

  Future<void> _retryHeld() async {
    // Not re-entrant: two auth events in quick succession would otherwise run
    // two retries at once, and the second would pick up a transaction the
    // first had re-held — validating and completing it twice. Anything held
    // again waits for the next resume, auth change, or StoreKit re-delivery.
    if (_retrying || _held.isEmpty) return;
    _retrying = true;
    try {
      final pending = List<PurchaseDetails>.from(_held);
      _held.clear();
      // Through the listener's own path, not straight to _grant. That path
      // skips a transaction the listener is already validating — a restore's
      // re-delivery of it, say — and catches a failure per transaction,
      // re-holding it. Calling _grant directly did neither: two validations
      // and two grants for one purchase, and a single failed prefs write
      // escaping as an unhandled error with the rest of the list dropped.
      await _handlePurchases(pending);
    } finally {
      _retrying = false;
    }
  }

  /// Hands the result to whoever is waiting, and tells everyone else.
  ///
  /// An outcome nobody was waiting for is the interesting one: it means the
  /// purchase landed while the user was somewhere else entirely.
  void _report(PurchaseOutcome outcome, {String? productId}) {
    final waiter = _waiter;
    final wanted = _waitingForProductId;
    // `productId` null means the outcome belongs to no particular transaction
    // — a stream-level error — and reaches whoever is waiting.
    //
    // A purchase waits for one product, so an outcome must be for that product,
    // grant or failure alike; otherwise an unrelated failure answers someone
    // else's purchase.
    //
    // A restore (`wanted == null`) waits for *any* plan, and is answered only
    // by a grant. Restore re-delivers every past transaction, so one expired
    // transaction's rejection is not the restore failing — a live one may be
    // next. If nothing grants, the restore times out and reports that no
    // active subscription was found, which is then true.
    final isRestore = wanted == null;
    final matches = waiter != null &&
        !waiter.isCompleted &&
        (productId == null ||
            (isRestore ? outcome.isGranted : wanted == productId));

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
      if (kDebugMode) debugPrint('Could not get an ID token for validation: $e');
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

      return interpretValidation(response.statusCode, responseBody);
    } finally {
      client.close();
    }
  }

  /// Reads the validator's answer.
  ///
  /// This is where a transaction's fate is decided, so it is pure and tested
  /// on its own. Throws [ReceiptRejected] only for a verdict the server
  /// actually reached — the listener then finishes the transaction, which
  /// cannot be undone. Everything else throws a plain exception, including a
  /// body that isn't the JSON expected, and the listener holds the transaction
  /// for another try. When unsure, this must not produce a rejection.
  ///
  /// Returns the validated product id, or null when the server named none —
  /// which the listener also treats as a reason to hold.
  @visibleForTesting
  static String? interpretValidation(int statusCode, String body) {
    if (statusCode == 401 || statusCode == 403) {
      throw Exception(
        'Receipt verification blocked. Check Cloud Function permissions.',
      );
    }

    // Includes 503 'unavailable': the server could not reach Apple's
    // certificate check, so nothing is known about this receipt yet.
    if (statusCode != 200) {
      throw Exception('Could not verify App Store purchase right now.');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final data = (json['result'] ?? json['data']) as Map<String, dynamic>?;

    if (data == null) {
      throw Exception('Could not verify App Store purchase right now.');
    }

    final isValid = data['isValid'];

    // Only a boolean is a verdict. Anything else — the field missing, a
    // string "false", a proxy's own JSON — is not something the server
    // decided, so it must hold rather than finish the transaction.
    if (isValid != true && isValid != false) {
      throw Exception('Could not verify App Store purchase right now.');
    }

    if (isValid == false) {
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
      if (reason == 'unverifiable') {
        // Not "try Restore": restore re-delivers this same unreadable record
        // and gets the same answer. The server only says this for a purchase
        // record too malformed to read, so a person has to look at it.
        throw ReceiptRejected(
          "The App Store sent a purchase record CarpeCarb couldn't read. If "
          'you were charged, please contact support.',
        );
      }
      throw ReceiptRejected(
        'Receipt validation failed (${reason ?? 'unknown'}).',
      );
    }

    final productId = data['productId']?.toString();
    if (productId == null || productId.isEmpty) return null;
    return productId;
  }
}
