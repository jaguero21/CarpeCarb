import Foundation
import Testing
@testable import CarbShared

// Same cases as test/day_key_test.dart (the Dart twin of CarbDay.key).
struct CarbDayTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test(arguments: [
        (2026, 9, 18, 0, 0, 0, "2026-09-18"),   // midnight reset, start of day
        (2026, 9, 18, 23, 59, 0, "2026-09-18"), // midnight reset, end of day
        (2026, 9, 18, 3, 59, 4, "2026-09-17"),  // before a 4 AM reset → previous day
        (2026, 9, 18, 4, 0, 4, "2026-09-18"),   // at the reset hour → same day
        (2026, 3, 1, 2, 0, 4, "2026-02-28"),    // month boundary
        (2026, 1, 1, 0, 30, 4, "2025-12-31"),   // year boundary
        (2026, 3, 9, 0, 30, 4, "2026-03-08"),   // day after DST starts (23-hour day)
    ])
    func key(y: Int, m: Int, d: Int, h: Int, min: Int, resetHour: Int, expected: String) {
        #expect(CarbDay.key(for: date(y, m, d, h, min), resetHour: resetHour, calendar: calendar) == expected)
    }

    @Test func keyIsGregorianWhateverTheDeviceCalendar() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        #expect(CarbDay.key(for: date(2026, 9, 18, 12, 0), resetHour: 0, calendar: buddhist) == "2026-09-18")

        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = calendar.timeZone
        #expect(CarbDay.key(for: date(2026, 9, 18, 3, 0), resetHour: 4, calendar: japanese) == "2026-09-17")
    }

    @Test func nextBoundaryIsNextMidnightWithNoResetHour() {
        let next = CarbDay.nextBoundary(after: date(2026, 9, 18, 21, 15), resetHour: 0, calendar: calendar)
        #expect(next == date(2026, 9, 19, 0, 0))
    }

    @Test func nextBoundaryIsLaterTodayBeforeTheResetHour() {
        let next = CarbDay.nextBoundary(after: date(2026, 9, 18, 2, 0), resetHour: 4, calendar: calendar)
        #expect(next == date(2026, 9, 18, 4, 0))
    }

    @Test func nextBoundaryAtTheResetHourIsTomorrow() {
        let next = CarbDay.nextBoundary(after: date(2026, 9, 18, 4, 0), resetHour: 4, calendar: calendar)
        #expect(next == date(2026, 9, 19, 4, 0))
    }
}
