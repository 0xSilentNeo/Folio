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

    /// A list as a version's entries are written, for the tests: the
    /// app's own is empty at 0.90.0, where the numbers start again.
    private let list: [WhatsNew.Release] = ["0.91.0", "0.90.10", "0.90.9", "0.90.8", "0.90.1"].map {
        WhatsNew.Release(version: $0, items: [WhatsNew.Item(icon: "star", title: "A thing", text: "You'll see it.")])
    }

    /// 0.90.0: no entries (those of 1.21.0 to 1.30.6 are gone). What is
    /// there is newest first, has items, and keeps to five a release.
    func testTheList() {
        let versions = WhatsNew.releases.map(\.version)
        XCTAssertFalse(versions.contains { $0.hasPrefix("1.") }, "nothing from before the numbers started again")
        XCTAssertEqual(versions, versions.sorted { WhatsNew.newer($0, than: $1) }, "newest first")
        XCTAssertEqual(Set(versions).count, versions.count)
        for r in WhatsNew.releases {
            XCTAssertFalse(r.items.isEmpty, r.version)
            XCTAssertLessThanOrEqual(r.items.count, 5, r.version)
        }
        XCTAssertNil(WhatsNew.release("1.30.6"))
    }

    /// 1.28.11: an update over several versions lists each one since.
    func testEverythingSinceTheVersionYouHad() {
        func since(_ last: String?, _ current: String) -> [String] { WhatsNew.releases(after: last, upTo: current, in: list).map(\.version) }
        XCTAssertEqual(since("0.90.1", "0.90.10"), ["0.90.10", "0.90.9", "0.90.8"])
        XCTAssertEqual(since(nil, "0.90.8"), ["0.90.8"])
        XCTAssertTrue(since("0.90.8", "0.90.8").isEmpty)
        // Numbered, not spelt: 0.90.10 is after 0.90.9.
        XCTAssertEqual(since("0.90.9", "0.90.10"), ["0.90.10"])
        XCTAssertEqual(since("0.90.0", "0.90.1"), ["0.90.1"])
    }
}
