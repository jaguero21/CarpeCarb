import 'package:carb_tracker/utils/picked_time.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an earlier time today is that time today', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 8, minute: 30),
          now: DateTime(2026, 10, 14, 13, 5), resetHour: 0),
      DateTime(2026, 10, 14, 8, 30),
    );
  });

  test('a time later than now is refused', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 23, minute: 59),
          now: DateTime(2026, 10, 14, 13, 5), resetHour: 0),
      isNull,
    );
  });

  test('a time before the day started is refused', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 3, minute: 0),
          now: DateTime(2026, 10, 14, 9), resetHour: 4),
      isNull,
    );
  });

  test('with a 4 AM reset at 2 AM, 11 PM means last night', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 23, minute: 0),
          now: DateTime(2026, 10, 14, 2), resetHour: 4),
      DateTime(2026, 10, 13, 23),
    );
  });

  test('now itself is allowed', () {
    expect(
      resolvePickedTime(const TimeOfDay(hour: 13, minute: 5),
          now: DateTime(2026, 10, 14, 13, 5, 40), resetHour: 0),
      DateTime(2026, 10, 14, 13, 5),
    );
  });
}
