import Foundation

/// The app's notion of "today": a calendar day that starts at `resetHour`
/// (0 = midnight). Mirrors `dayKey` in lib/utils/day_key.dart; both are tested
/// against the same cases, so change them together. Keys are always Gregorian
/// `yyyy-MM-dd`, even on a device set to another calendar (Buddhist, Japanese),
/// because Dart's `dayKey` always writes Gregorian dates.
public enum CarbDay {
    /// `yyyy-MM-dd` of the day `date` belongs to. Hours before `resetHour`
    /// count as the previous calendar day.
    public static func key(for date: Date, resetHour: Int, calendar: Calendar = .current) -> String {
        // Keys are Gregorian yyyy-MM-dd (what Dart writes) whatever calendar the
        // device uses; only the time zone comes from `calendar`.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var day = date
        if resetHour > 0, gregorian.component(.hour, from: date) < resetHour,
           let previous = gregorian.date(byAdding: .day, value: -1, to: date) {
            day = previous
        }
        let c = gregorian.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The next instant after `date` when the day changes (`resetHour`:00 local time).
    public static func nextBoundary(after date: Date, resetHour: Int, calendar: Calendar = .current) -> Date {
        let boundary = DateComponents(hour: resetHour, minute: 0, second: 0)
        return calendar.nextDate(after: date, matching: boundary, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(24 * 60 * 60)
    }
}
