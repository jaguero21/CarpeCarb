import 'dart:convert';

import 'package:carb_tracker/services/purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// How the client reads the validator's answer.
///
/// This decides a transaction's fate. A [ReceiptRejected] makes the listener
/// finish it, which drops it from StoreKit's queue for good; anything else
/// makes it hold and retry. So the property that matters most is the negative
/// one: nothing that isn't a verdict the server actually reached may come out
/// as a rejection. Every other test in the suite injected a fake validator, so
/// until now none of this had ever run.
void main() {
  String verdict(Map<String, Object?> data) => jsonEncode({'result': data});

  String? read(int status, String body) =>
      PurchaseService.interpretValidation(status, body);

  Matcher rejected() => throwsA(isA<ReceiptRejected>());

  /// Anything that must leave the transaction in the queue.
  Matcher heldForRetry() => throwsA(
        predicate<Object>((e) => e is Exception && e is! ReceiptRejected,
            'an exception that is not a ReceiptRejected'),
      );

  group('a valid receipt', () {
    test('yields the product the server validated', () {
      expect(
        read(200, verdict({'isValid': true, 'productId': 'premium_yearly'})),
        'premium_yearly',
      );
    });

    test('with no product named yields null, which the listener holds', () {
      expect(read(200, verdict({'isValid': true})), isNull);
      expect(read(200, verdict({'isValid': true, 'productId': ''})), isNull);
    });

    test('is read from "data" as well as "result"', () {
      final body = jsonEncode({
        'data': {'isValid': true, 'productId': 'premium_monthlysub'},
      });
      expect(read(200, body), 'premium_monthlysub');
    });
  });

  group('a verdict the server reached is a rejection', () {
    test('when Apple permanently refuses the transaction', () {
      // The bug this batch fixes: this arrived as HTTP 400, was held, and was
      // re-delivered at every launch with no way for the user to clear it.
      expect(
        () => read(200, verdict({'isValid': false, 'reason': 'unverifiable'})),
        rejected(),
      );
    });

    test('does not send the user to Restore, which cannot help', () {
      // Restore re-delivers the same unreadable record and gets the same
      // answer, so pointing there would be a dead end.
      try {
        read(200, verdict({'isValid': false, 'reason': 'unverifiable'}));
        fail('expected a rejection');
      } on ReceiptRejected catch (e) {
        expect(e.message, isNot(contains('Restore')));
        expect(e.message, contains('contact support'));
      }
    });

    test('for every reason the server gives', () {
      for (final reason in [
        'no-active-subscription',
        'product-mismatch',
        'revoked',
        'something-added-later',
      ]) {
        expect(
          () => read(200, verdict({'isValid': false, 'reason': reason})),
          rejected(),
          reason: reason,
        );
      }
    });
  });

  group('anything else holds the transaction', () {
    test('when the server could not reach Apple (503)', () {
      // The new 'unavailable' answer. Nothing is known about the receipt, so
      // calling this a rejection would finish — and lose — a paid purchase.
      expect(() => read(503, '{"error":{"status":"UNAVAILABLE"}}'),
          heldForRetry());
    });

    test('on any other failure status', () {
      for (final status in [400, 401, 403, 429, 500, 502]) {
        expect(() => read(status, '{}'), heldForRetry(), reason: '$status');
      }
    });

    test('when a 200 carries no verdict at all', () {
      expect(() => read(200, '{}'), heldForRetry());
    });

    test('when isValid is missing or not a boolean', () {
      // Only a boolean is a verdict. A string "false" — or even a string
      // "true" on an otherwise valid answer — was read as a rejection and
      // finished the transaction.
      for (final data in <Map<String, Object?>>[
        {},
        {'isValid': 'false'},
        {'isValid': 'true', 'productId': 'premium_yearly'},
        {'isValid': null},
        {'message': 'login'},
      ]) {
        expect(() => read(200, verdict(data)), heldForRetry(), reason: '$data');
      }
    });

    test('when a 200 is not the JSON expected', () {
      // A captive portal or proxy can answer 200 with an HTML page. Not a
      // verdict, so it must not be read as one.
      expect(() => read(200, '<html>Sign in to Wi-Fi</html>'),
          throwsA(isNot(isA<ReceiptRejected>())));
      expect(() => read(200, '[]'), throwsA(isNot(isA<ReceiptRejected>())));
    });
  });
}
