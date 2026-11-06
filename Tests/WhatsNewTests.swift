import XCTest
@testable import Folio

/// What's new (1.22.0): once per version after an update, never after a
/// first install, from the hand-written list.
final class WhatsNewTests: XCTestCase {
    func testFirstInstallShowsNothing() {
        let d = WhatsNew.decide(current: "1.22.0", lastShown: nil, existingInstall: false, hasEntries: true)
        XCTAssertEqual(d, WhatsNew.Decision(show: false, remember: "1.22.0"), "remembered, so the next launch isn't taken for an update")
    }

    func testUpdateFromBeforeWhatsNewShowsOnce() {
        // 1.21.0 kept nothing: what it left behind says Folio was used.
        let d = WhatsNew.decide(current: "1.22.0", lastShown: nil, existingInstall: true, hasEntries: true)
        XCTAssertEqual(d, WhatsNew.Decision(show: true, remember: "1.22.0"))
        let next = WhatsNew.decide(current: "1.22.0", lastShown: d.remember, existingInstall: true, hasEntries: true)
        XCTAssertEqual(next, WhatsNew.Decision(show: false, remember: nil), "the next launch of the same version: nothing")
    }

    func testLaterUpdate() {
        XCTAssertEqual(WhatsNew.decide(current: "1.23.0", lastShown: "1.22.0", existingInstall: true, hasEntries: true),
                       WhatsNew.Decision(show: true, remember: "1.23.0"))
        XCTAssertEqual(WhatsNew.decide(current: "1.22.10", lastShown: "1.22.9", existingInstall: true, hasEntries: true).show, true,
                       "versions compare as numbers")
    }

    func testNoEntriesOrDowngrade() {
        XCTAssertEqual(WhatsNew.decide(current: "1.22.1", lastShown: "1.22.0", existingInstall: true, hasEntries: false),
                       WhatsNew.Decision(show: false, remember: "1.22.1"), "a version without a list: nothing to show")
        XCTAssertEqual(WhatsNew.decide(current: "1.21.0", lastShown: "1.22.0", existingInstall: true, hasEntries: true).show, false,
                       "an older version installed again")
        XCTAssertEqual(WhatsNew.decide(current: "", lastShown: nil, existingInstall: true, hasEntries: true), WhatsNew.Decision(show: false, remember: nil))
    }

    func testTheList() {
        let versions = WhatsNew.releases.map(\.version)
        XCTAssertEqual(Array(versions.prefix(2)), ["1.23.4", "1.23.3"])
        XCTAssertEqual(versions, versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }, "newest first")
        for r in WhatsNew.releases { XCTAssertFalse(r.items.isEmpty, r.version) }
        XCTAssertNotNil(WhatsNew.release("1.21.0"))
    }
}
