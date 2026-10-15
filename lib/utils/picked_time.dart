import 'package:flutter/material.dart';

import 'day_key.dart';

/// The moment a time picked for a logged food means: today (the app's day,
/// which starts at [resetHour]), at or before [now]. Null when the time
/// would fall outside today, i.e. in the future or before the day began.
DateTime? resolvePickedTime(TimeOfDay picked,
    {required DateTime now, required int resetHour}) {
  var candidate =
      DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
  // A time later than now on today's date means the evening before, which
  // is still today when the day starts after midnight.
  if (candidate.isAfter(now)) {
    candidate = DateTime(
        now.year, now.month, now.day - 1, picked.hour, picked.minute);
  }
  return candidate.isBefore(dayStart(now, resetHour)) ? null : candidate;
}
