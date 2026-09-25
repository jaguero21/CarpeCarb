import 'package:carb_tracker/utils/day_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Same cases as CarbDayTests.swift (the Swift twin used by Siri and the widget).
  final cases = <(DateTime, int, String, String)>[
    (DateTime(2026, 9, 18, 0, 0), 0, '2026-09-18', 'midnight reset, start of day'),
    (DateTime(2026, 9, 18, 23, 59), 0, '2026-09-18', 'midnight reset, end of day'),
    (DateTime(2026, 9, 18, 3, 59), 4, '2026-09-17', 'before a 4 AM reset: previous day'),
    (DateTime(2026, 9, 18, 4, 0), 4, '2026-09-18', 'at the reset hour: same day'),
    (DateTime(2026, 3, 1, 2, 0), 4, '2026-02-28', 'month boundary'),
    (DateTime(2026, 1, 1, 0, 30), 4, '2025-12-31', 'year boundary'),
    // Only catches the old "minus 24 hours" bug when the tests run in a US
    // daylight-saving time zone (e.g. `TZ=America/Chicago flutter test`); in
    // UTC there's no 23-hour day, so both versions pass.
    (DateTime(2026, 3, 9, 0, 30), 4, '2026-03-08', 'day after DST starts (23-hour day)'),
  ];

  for (final (now, resetHour, expected, label) in cases) {
    test('dayKey: $label', () {
      expect(dayKey(now, resetHour), expected);
    });
  }

  group('nextDayBoundary', () {
    // The moment an app left open should roll over to a new day. Before this,
    // nothing fired at that moment: the list stayed on yesterday until the
    // user left and came back.

    test('is later today when the reset hour has not come yet', () {
      expect(nextDayBoundary(DateTime(2026, 9, 24, 3, 0), 4),
          DateTime(2026, 9, 24, 4));
    });

    test('is tomorrow once the reset hour has passed', () {
      expect(nextDayBoundary(DateTime(2026, 9, 24, 10, 0), 4),
          DateTime(2026, 9, 25, 4));
    });

    test('is tomorrow when now is exactly the boundary', () {
      // Strictly after now, or a timer set at the boundary would fire again
      // immediately and loop.
      expect(nextDayBoundary(DateTime(2026, 9, 24, 4), 4),
          DateTime(2026, 9, 25, 4));
    });

    test('is midnight with no reset hour set', () {
      expect(nextDayBoundary(DateTime(2026, 9, 24, 23, 59), 0),
          DateTime(2026, 9, 25));
    });

    test('rolls over months and years', () {
      expect(nextDayBoundary(DateTime(2026, 9, 30, 12), 0), DateTime(2026, 10, 1));
      expect(nextDayBoundary(DateTime(2026, 12, 31, 12), 0), DateTime(2027, 1, 1));
    });

    test('is exactly where dayKey changes', () {
      // The two must agree, or the timer fires on a moment that is not
      // actually a new day and the rollover does nothing.
      for (final resetHour in [0, 2, 4, 6]) {
        final now = DateTime(2026, 9, 24, 13, 7);
        final boundary = nextDayBoundary(now, resetHour);
        final before = boundary.subtract(const Duration(milliseconds: 1));
        expect(dayKey(before, resetHour), isNot(dayKey(boundary, resetHour)),
            reason: 'resetHour $resetHour');
        expect(dayKey(before, resetHour), dayKey(now, resetHour),
            reason: 'nothing changes before the boundary, resetHour $resetHour');
      }
    });
  });
}
