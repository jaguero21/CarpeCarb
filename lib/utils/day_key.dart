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

/// The next moment the app's day changes: the first [resetHour]:00 strictly
/// after [now].
///
/// Strictly after, so a timer set at a boundary does not fire again at once.
/// Built with calendar arithmetic like [dayKey], so a daylight-saving change
/// does not shift it by an hour — and it must agree with [dayKey], or a timer
/// would fire at a moment that is not actually a new day.
DateTime nextDayBoundary(DateTime now, int resetHour) {
  final today = DateTime(now.year, now.month, now.day, resetHour);
  return today.isAfter(now)
      ? today
      : DateTime(now.year, now.month, now.day + 1, resetHour);
}
