import XCTest
@testable import Folio

/// 1.30.1: fixes from the 13 Nov code review and the 12 Nov report.
final class Fixes1301Tests: XCTestCase {
    /// An episode known by its day only is announced at 09:00 on that day.
    /// TVmaze's stand-in air time is 12:00 UTC, which is 07:00 in New York:
    /// a replan between 07:00 and 09:00 dropped the alert.
    func testDayOnlyAlertSurvivesAReplanAfterItsStandInAirTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        var s = TrackedShow(id: "tt16358384", name: "Tulsa King")
        let air = Date(timeIntervalSince1970: 1_794_571_200)        // 13 Nov 2026 12:00 UTC, 07:00 in New York
        s.next = AiringEpisode(season: 4, number: 5, airDate: air, day: "2026-11-13")

        let at0730 = air.addingTimeInterval(30 * 60)
        let plan = AiringNotifications.plan([s], now: at0730, mode: .air, calendar: cal)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.title, "Tulsa King S4 · E5 comes out today")
        XCTAssertEqual(plan.first.map { cal.component(.hour, from: $0.fire) }, 9)
        XCTAssertEqual(plan.first.map { cal.component(.day, from: $0.fire) }, 13)

        // Once its morning alert is over, it isn't planned again.
        let at1000 = air.addingTimeInterval(3 * 3600)
        XCTAssertTrue(AiringNotifications.plan([s], now: at1000, mode: .air, calendar: cal).isEmpty)
    }

    /// An episode with a real air time is still planned by that time only.
    func testTimedEpisodeIsNotPlannedAfterItAired() {
        var s = TrackedShow(id: "tt1", name: "Show")
        let air = Date(timeIntervalSince1970: 1_794_571_200)
        s.next = AiringEpisode(season: 1, number: 2, airDate: air, day: nil)
        XCTAssertEqual(AiringNotifications.plan([s], now: air.addingTimeInterval(-3600), mode: .air).count, 1)
        XCTAssertTrue(AiringNotifications.plan([s], now: air.addingTimeInterval(60), mode: .air).isEmpty)
    }

    /// An outage or a rate limit keeps a scrobble queued; a refusal of the
    /// job itself still counts towards dropping it.
    func testWhichSyncFailuresWait() {
        for status in [0, 401, 408, 429, 500, 502, 503, 599] {
            XCTAssertTrue(SyncCenter.isTransient(status: status), "\(status)")
        }
        for status in [400, 403, 404, 409, 422] {
            XCTAssertFalse(SyncCenter.isTransient(status: status), "\(status)")
        }
    }

    /// Efficient dithers too: its 8-bit frames showed bands in the gradients
    /// of 10-bit videos.
    func testEveryPictureModeDithers() {
        for mode in [PictureMode.efficient, .balanced] {
            XCTAssertEqual(mode.options.first { $0.0 == "dither-depth" }?.1, "auto", mode.rawValue)
        }
    }
}
