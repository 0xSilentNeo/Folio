import XCTest
@testable import Folio

/// 1.25.0's fixes from the 7 Nov audit that can be checked without the UI.
@MainActor
final class Fixes1250Tests: XCTestCase {
    /// Your Week rolls on at midnight without Folio: the oldest day leaves.
    func testWeekRollsForwardFromItsDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 22))!
        // Mon 3 h, the six days before 1 h each: 9 h this week.
        let w = WeekGlance(seconds: 9 * 3600, shows: 2, films: 0, episodes: 9, perDay: [3600, 3600, 3600, 3600, 3600, 3600, 3 * 3600],
                           countingSince: nil, day: monday)
        XCTAssertEqual(w.seconds(at: monday, calendar: cal), 9 * 3600)
        let tuesday = cal.date(byAdding: .hour, value: 3, to: monday)!
        XCTAssertEqual(w.daysOld(at: tuesday, calendar: cal), 1)
        XCTAssertEqual(w.seconds(at: tuesday, calendar: cal), 8 * 3600)
        let sunday = cal.date(byAdding: .day, value: 5, to: tuesday)!
        XCTAssertEqual(w.seconds(at: sunday, calendar: cal), 3 * 3600, "on Sunday only Monday is left of that week")
        XCTAssertEqual(w.seconds(at: cal.date(byAdding: .day, value: 7, to: monday)!, calendar: cal), 0)
    }
}
