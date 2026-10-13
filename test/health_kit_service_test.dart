import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingHealth extends HealthKitService {
  _RecordingHealth({required this.deleteOk, this.writeOk = true});
  final bool deleteOk;
  final bool writeOk;
  final calls = <String>[];

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    calls.add('delete ${item.carbs}');
    return deleteOk;
  }

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.carbs}');
    return writeOk;
  }
}

void main() {
  group('replaceFoodItem', () {
    final old = FoodItem(id: 'f', name: 'pho', carbs: 13.7, loggedAt: DateTime(2026, 10, 12, 12));
    final updated = FoodItem(id: 'f', name: 'pho', carbs: 41.2, loggedAt: DateTime(2026, 10, 12, 12));

    test('deletes the old sample, then writes the new one', () async {
      final health = _RecordingHealth(deleteOk: true);
      expect(await health.replaceFoodItem(old, updated), isTrue);
      expect(health.calls, ['delete 13.7', 'write 41.2']);
    });

    test('never writes if the delete failed, so the food cannot appear twice', () async {
      final health = _RecordingHealth(deleteOk: false);
      expect(await health.replaceFoodItem(old, updated), isFalse);
      expect(health.calls, ['delete 13.7']);
    });

    test('reports a failed write', () async {
      final health = _RecordingHealth(deleteOk: true, writeOk: false);
      expect(await health.replaceFoodItem(old, updated), isFalse);
    });
  });

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
