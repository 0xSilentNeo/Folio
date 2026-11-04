import XCTest
@testable import Folio

/// iOS's own download progress (1.22.3, iOS 26): its texts as Safari's
/// show them, the units it reads, and the identifiers Info.plist allows.
final class SystemProgressTests: XCTestCase {
    func testTheTextsReadAsSafarisDo() {
        let one = SystemProgress.texts(running: ["Show · S01E04"], next: "Show · S01E04", waiting: false,
                                       received: 102_900_000, total: 137_100_000)
        XCTAssertEqual(one.title, "Downloading \u{201C}Show · S01E04\u{201D}")
        XCTAssertEqual(one.subtitle, "\(bytes(102_900_000)) of \(bytes(137_100_000))")
        XCTAssertEqual(SystemProgress.texts(running: ["A", "B", "C"], next: "A", waiting: false, received: 1, total: 2).title,
                       "Downloading 3 files")
        // Between files, or a retry's wait.
        let waiting = SystemProgress.texts(running: [], next: "Next", waiting: true, received: 5_000_000, total: 9_000_000)
        XCTAssertEqual(waiting.title, "Downloading \u{201C}Next\u{201D}")
        XCTAssertTrue(waiting.subtitle.hasPrefix("Waiting to retry · "))
        // No length yet.
        XCTAssertEqual(SystemProgress.texts(running: ["A"], next: "A", waiting: false, received: 0, total: 0).subtitle, "Starting")
        // Never past the whole.
        XCTAssertEqual(SystemProgress.texts(running: ["A"], next: "A", waiting: false, received: 9, total: 5).subtitle,
                       "\(bytes(5)) of \(bytes(5))")
    }

    private func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    func testTheProgressIsInMegabytes() {
        XCTAssertTrue(SystemProgress.units(received: 102_900_000, total: 137_100_000) == (102, 137))
        // Nothing known yet: one unit, none done (never 0 of 0).
        XCTAssertTrue(SystemProgress.units(received: 0, total: 0) == (0, 1))
        XCTAssertTrue(SystemProgress.units(received: 9_000_000, total: 5_000_000) == (5, 5))
        XCTAssertTrue(SystemProgress.units(received: -4, total: 500) == (0, 1))
    }

    func testTheIdentifiersAreAllowedByInfoPlist() throws {
        let allowed = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        XCTAssertTrue(allowed.contains(SystemProgress.prefix + "*"), "\(allowed)")
        XCTAssertTrue(allowed.contains(AiringBackground.taskID), "the airing refresh stays")
        XCTAssertTrue(SystemProgress.prefix.hasPrefix("dev.silentneo.folio."), "under the bundle ID")
        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        XCTAssertTrue(Set(["audio", "picture-in-picture", "fetch", "processing"]).isSubset(of: Set(modes)), "\(modes)")
    }
}
