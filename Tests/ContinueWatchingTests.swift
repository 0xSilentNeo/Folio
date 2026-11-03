import XCTest
@testable import Folio

/// Continue Watching keeps the episode furthest along per show (1.22.1).
@MainActor
final class ContinueWatchingTests: XCTestCase {
    private func entry(_ url: String, position: Double = 300, duration: Double = 1400, ago: TimeInterval) -> HistoryEntry {
        var m = MediaItem(url: url, title: "", source: .url)
        m.historyKey = url
        return HistoryEntry(item: m, position: position, duration: duration, updated: Date().addingTimeInterval(-ago))
    }

    func testAnOlderSeasonPlayedLaterDoesNotReplaceTheNewerOne() {
        let newer = entry("https://dav.example.com/Show/Classroom.of.the.Elite.S03E02.1080p.mkv", ago: 3600)
        let older = entry("/var/mobile/Documents/Media/Classroom.of.the.Elite.S01E05.mkv", ago: 60)
        let cw = HistoryStore.pickContinueWatching([older, newer])
        XCTAssertEqual(cw.count, 1)
        XCTAssertEqual(cw.first?.id, newer.id)
    }

    func testTheShowIsPlacedByItsLatestPlay() {
        let showA3 = entry("https://dav.example.com/A/Show.A.S03E02.mkv", ago: 7200)
        let showA1 = entry("/Documents/Media/Show.A.S01E01.mkv", ago: 10)
        let showB = entry("https://dav.example.com/B/Show.B.S01E04.mkv", ago: 600)
        let cw = HistoryStore.pickContinueWatching([showA3, showA1, showB])
        XCTAssertEqual(cw.map(\.id), [showA3.id, showB.id])
    }

    func testFilmsKeepThePlayedLast() {
        let a = entry("https://x/Dune.2021.mkv", ago: 100), b = entry("https://x/Arrival.2016.mkv", ago: 10)
        XCTAssertEqual(HistoryStore.pickContinueWatching([a, b]).map(\.id), [b.id, a.id])
    }
}
