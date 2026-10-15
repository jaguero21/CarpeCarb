import 'dart:async';

import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/health_kit_service.dart';

/// Stands in for HealthKit. Each delete waits until the test finishes it
/// with [finishDelete], which also picks whether it worked; writes answer at
/// once. Every call is recorded in order.
class HeldHealth extends HealthKitService {
  final calls = <String>[];
  final _held = <String, List<Completer<bool>>>{};

  /// The foods written so far, by name.
  List<String> get writes => [
        for (final c in calls)
          if (c.startsWith('write ')) c.substring('write '.length),
      ];

  /// Finishes the oldest delete of [name] still waiting, as a success unless
  /// [ok] is false.
  void finishDelete(String name, {bool ok = true}) =>
      _held[name]!.removeAt(0).complete(ok);

  @override
  Future<bool> deleteFoodItem(FoodItem item) async {
    final done = Completer<bool>();
    (_held[item.name] ??= []).add(done);
    final ok = await done.future;
    calls.add('delete ${item.name}${ok ? '' : ' failed'}');
    return ok;
  }

  @override
  Future<bool> writeFoodItem(FoodItem item) async {
    calls.add('write ${item.name}');
    return true;
  }
}
