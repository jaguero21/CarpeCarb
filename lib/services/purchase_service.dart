import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'premium_service.dart';

class PurchaseService {
  static const String monthlyProductId = 'carpecarb_premium_monthlysub';
  static const String yearlyProductId = 'carpecarb_premium_yearly';

  static const String _validateUrl =
      'https://us-central1-carpecarb.cloudfunctions.net/validateAppStoreReceipt';

  final InAppPurchase _iap = InAppPurchase.instance;
  bool _purchaseInProgress = false;

  Set<String> get _productIds => {monthlyProductId, yearlyProductId};

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

  Future<String?> _validateReceipt(
    PurchaseDetails purchase, {
    String? expectedProductId,
  }) async {
    final receiptData = purchase.verificationData.serverVerificationData;
    if (receiptData.isEmpty) {
      throw Exception('App Store receipt data is missing.');
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Authentication error. Please restart the app.');
    }

    final idToken = await user.getIdToken() ?? '';
    if (idToken.isEmpty) {
      throw Exception('Authentication error. Please restart the app.');
    }

    try {
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

        final response = await request.close().timeout(const Duration(seconds: 30));
        final responseBody = await response.transform(utf8.decoder).join();

        if (kDebugMode) debugPrint('validateAppStoreReceipt HTTP ${response.statusCode}');

        if (response.statusCode == 401 || response.statusCode == 403) {
          throw Exception('Receipt verification blocked. Check Cloud Function permissions.');
        }

        if (response.statusCode != 200) {
          if (kDebugMode) debugPrint('validateAppStoreReceipt error: $responseBody');
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
            throw Exception('Receipt was valid but for a different product ($found).');
          }
          if (reason == 'no-active-subscription') {
            throw Exception('No active subscription was found in the App Store receipt.');
          }
          throw Exception('Receipt validation failed (${reason ?? 'unknown'}).');
        }

        final productId = data['productId']?.toString();
        if (productId == null || productId.isEmpty) return null;
        return productId;
      } finally {
        client.close();
      }
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Could not verify App Store purchase right now.');
    }
  }

  Future<bool> purchasePlan(String plan) async {
    if (_purchaseInProgress) {
      throw Exception('A purchase is already in progress.');
    }
    _purchaseInProgress = true;

    final productId = productIdForPlan(plan);
    late final ProductDetails product;
    try {
      final products = await queryPremiumProducts();
      final found = products[productId];
      if (found == null) {
        throw Exception('Product not found in App Store Connect: $productId');
      }
      product = found;
    } catch (e) {
      _purchaseInProgress = false;
      rethrow;
    }

    final completer = Completer<bool>();
    late final StreamSubscription<List<PurchaseDetails>> sub;

    sub = _iap.purchaseStream.listen(
      (purchases) async {
        for (final purchase in purchases) {
          if (purchase.productID != productId) continue;

          if (purchase.status == PurchaseStatus.purchased ||
              purchase.status == PurchaseStatus.restored) {
            try {
              final validatedProductId = await _validateReceipt(
                purchase,
                expectedProductId: productId,
              );

              if (purchase.pendingCompletePurchase) {
                await _iap.completePurchase(purchase);
              }
              if (!completer.isCompleted) {
                completer.complete(validatedProductId == productId);
              }
            } catch (e) {
              if (purchase.pendingCompletePurchase) {
                await _iap.completePurchase(purchase);
              }
              if (!completer.isCompleted) completer.completeError(e);
            }
          } else if (purchase.status == PurchaseStatus.error ||
              purchase.status == PurchaseStatus.canceled) {
            if (purchase.pendingCompletePurchase) {
              await _iap.completePurchase(purchase);
            }
            if (!completer.isCompleted) {
              if (purchase.status == PurchaseStatus.canceled) {
                completer.completeError(
                  Exception('Purchase was canceled in App Store.'),
                );
              } else {
                final purchaseError = purchase.error;
                final msg =
                    purchaseError?.message.trim();
                completer.completeError(
                  Exception(
                    msg == null || msg.isEmpty
                        ? 'App Store reported a purchase error.'
                        : msg,
                  ),
                );
              }
            }
          }
        }
      },
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(
            Exception('Purchase stream error: ${e.toString()}'),
          );
        }
      },
      cancelOnError: false,
    );

    final started = await _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: product),
    );

    if (!started) {
      await sub.cancel();
      _purchaseInProgress = false;
      throw Exception('Could not start App Store purchase flow.');
    }

    try {
      return await completer.future.timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw Exception('Timed out waiting for App Store purchase confirmation.');
    } finally {
      await sub.cancel();
      _purchaseInProgress = false;
    }
  }

  Future<String?> restorePremiumPlan() async {
    final completer = Completer<String?>();
    late final StreamSubscription<List<PurchaseDetails>> sub;

    sub = _iap.purchaseStream.listen(
      (purchases) async {
        for (final purchase in purchases) {
          final plan = planForProductId(purchase.productID);
          if (plan == null) continue;

          if (purchase.status == PurchaseStatus.purchased ||
              purchase.status == PurchaseStatus.restored) {
            try {
              final validatedProductId = await _validateReceipt(purchase);

              if (purchase.pendingCompletePurchase) {
                await _iap.completePurchase(purchase);
              }

              final validatedPlan = validatedProductId == null
                  ? null
                  : planForProductId(validatedProductId);

              if (validatedPlan == null) {
                continue;
              }

              if (!completer.isCompleted) completer.complete(validatedPlan);
            } catch (e) {
              if (purchase.pendingCompletePurchase) {
                await _iap.completePurchase(purchase);
              }
              if (!completer.isCompleted) completer.completeError(e);
            }
          }
        }
      },
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(
            Exception('Could not restore purchases. Please try again.'),
          );
        }
      },
      cancelOnError: false,
    );

    await _iap.restorePurchases();

    try {
      return await completer.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return null;
    } finally {
      await sub.cancel();
    }
  }
}
