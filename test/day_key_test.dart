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
}
