/// The app's calendar day as `YYYY-MM-DD`. A day starts at [resetHour]
/// (0 = midnight), so earlier hours belong to the previous day.
///
/// Mirrors `CarbDay.key` in ios/CarbShared/Sources/CarbShared/CarbDay.swift,
/// which Siri and the widget use; both are tested against the same cases, so
/// change them together. Uses calendar arithmetic (not "minus 24 hours") so the
/// day after a daylight-saving change still maps to the right date.
String dayKey(DateTime now, int resetHour) {
  final day = (resetHour > 0 && now.hour < resetHour)
      ? DateTime(now.year, now.month, now.day - 1)
      : now;
  final y = day.year.toString().padLeft(4, '0');
  final m = day.month.toString().padLeft(2, '0');
  final d = day.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
