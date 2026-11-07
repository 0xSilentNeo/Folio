import XCTest
@testable import Folio

/// 1.24.1, from the 7 Nov recordings and screenshot: the speed next to the
/// size in iOS's own progress view and in the downloads Live Activity.
@MainActor
final class Downloads1241Tests: XCTestCase {
    private func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    func testIOSProgressShowsTheSpeedNextToTheSize() {
        let t = SystemProgress.texts(running: ["Show · S01E04"], next: nil, waiting: false,
                                     received: 102_900_000, total: 137_100_000, speed: 8_400_000)
        XCTAssertEqual(t.subtitle, "\(bytes(102_900_000)) of \(bytes(137_100_000)) · \(bytes(8_400_000))/s")
        // No speed yet, waiting for a retry, or no size yet: as before.
        XCTAssertEqual(SystemProgress.texts(running: ["A"], next: "A", waiting: false, received: 1_000_000, total: 2_000_000, speed: 0).subtitle,
                       "\(bytes(1_000_000)) of \(bytes(2_000_000))")
        XCTAssertFalse(SystemProgress.texts(running: [], next: "A", waiting: true, received: 1, total: 2, speed: 5_000_000).subtitle.contains("/s"))
        XCTAssertEqual(SystemProgress.texts(running: ["A"], next: "A", waiting: false, received: 0, total: 0, speed: 5_000_000).subtitle, "Starting")
    }

    func testTheActivityCarriesTheRunsBytes() {
        func item(_ name: String, _ state: DownloadItem.State, received: Int64, expected: Int64) -> DownloadItem {
            var d = DownloadItem(url: URL(string: "https://dav.example.invalid/\(name)")!, fileName: name, package: "P", expected: expected,
                                 destination: URL(fileURLWithPath: "/tmp/\(name)"))
            d.state = state
            d.received = received
            return d
        }
        let a = item("a.mkv", .running, received: 300_000_000, expected: 1_000_000_000)
        let b = item("b.mkv", .done, received: 500_000_000, expected: 500_000_000)
        let s = DownloadActivity.state([a, b], run: [a.id, b.id], speed: 25_000_000) { $0.fileName }
        XCTAssertEqual(s.received, 800_000_000)
        XCTAssertEqual(s.total, 1_500_000_000)
        XCTAssertEqual(s.bytesText, ByteCountFormatter.string(fromByteCount: 800_000_000, countStyle: .file) + " of "
                       + ByteCountFormatter.string(fromByteCount: 1_500_000_000, countStyle: .file))
        // A state written by an older build (the widgets' downloads file) still reads, without the bytes.
        let old = #"{"title":"x","filesLeft":1,"progress":0.5,"speed":10,"waiting":false,"done":false,"finished":0,"failed":0}"#
        let decoded = try? JSONDecoder().decode(DownloadActivityAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.bytesText)
    }
}
