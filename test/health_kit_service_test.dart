import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('healthDeleteWindow', () {
    test('covers exactly the millisecond the food started in', () {
      // Half a millisecond in: the plugin passes whole milliseconds to
      // HealthKit, so the window must line up with what the write stored.
      final loggedAt = DateTime.fromMicrosecondsSinceEpoch(1758542400000500);

      final window = healthDeleteWindow(loggedAt);

      expect(window.start.millisecondsSinceEpoch, 1758542400000);
      expect(window.end.millisecondsSinceEpoch, 1758542400001);
    });

    test('leaves out a food from the same lookup, logged 1 ms later', () {
      final burger = DateTime(2026, 9, 22, 12, 30);
      final fries = burger.add(const Duration(milliseconds: 1));

      final window = healthDeleteWindow(burger);

      // HealthKit's strict-start window: start inclusive, end exclusive.
      bool startsIn(DateTime t) =>
          !t.isBefore(window.start) && t.isBefore(window.end);
      expect(startsIn(burger), isTrue);
      expect(startsIn(fries), isFalse,
          reason: 'the one-minute window this replaces deleted fries too');
    });
  });
}
