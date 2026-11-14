import XCTest
@testable import Folio

/// 1.30.4: Continue Watching's card for the episode after a finished one.
/// 14 Nov report: Tulsa King, E01 from an addon on 13 Nov, then E02-E07
/// from the Real-Debrid library, E06 and E07 closed in their credits (97%
/// and 95%): Home had no card for the show. Only resumable entries were
/// ever cards, so a show left the row once an episode was watched to its end.
@MainActor
final class Fixes1304ContinueTests: XCTestCase {
    /// The report's moment, 14 Nov 23:40.
    private let now = Date(timeIntervalSince1970: 1_794_660_029)
    private let server = UUID()
    private let root = URL(string: "https://dav.real-debrid.com/torrents/")!
    private let release = "Tulsa King S01 1080p BluRay REMUX AVC TrueHD 5.1-TRiToN"

    private func name(_ e: Int, group: String = "TRiToN") -> String {
        "Tulsa.King.S01E0\(e).Episode.\(e).1080p.BluRay.REMUX.AVC.TrueHD.5.1-\(group).mkv"
    }

    private func file(_ e: Int, folder: String? = nil, group: String = "TRiToN") -> LibraryIndex.File {
        let n = name(e, group: group)
        return LibraryIndex.File(url: root.appendingPathComponent(folder ?? release, isDirectory: true).appendingPathComponent(n), name: n, size: 1, added: nil)
    }

    /// The server's saved library: the season's folder, another release of
    /// E08 in a folder of its own, a film and another show.
    private var library: [LibraryIndex.File] {
        (1...9).map { file($0) } + [
            file(8, folder: "Tulsa.King.S01E08.720p.WEB.h264-OTHER", group: "OTHER"),
            LibraryIndex.File(url: root.appendingPathComponent("Dune.2021.1080p.mkv"), name: "Dune.2021.1080p.mkv", size: 1, added: nil),
            LibraryIndex.File(url: root.appendingPathComponent("MobLand.S01E03.1080p.WEB-GRP.mkv"), name: "MobLand.S01E03.1080p.WEB-GRP.mkv", size: 1, added: nil),
        ]
    }

    /// A WebDAV episode's entry, as the item the browser plays is saved.
    private func dav(_ e: Int, position: Double, duration: Double = 2400, ago: TimeInterval) -> HistoryEntry {
        HistoryEntry(item: ContinueNext.webdavItem(file(e), serverID: server, cleanTitles: true),
                     position: position, duration: duration, updated: now.addingTimeInterval(-ago))
    }

    /// An addon episode's entry (AIOStreams, 13 Nov: "addon:tt16358384:1:1").
    private func addon(_ e: Int, position: Double, duration: Double = 2498, ago: TimeInterval) -> HistoryEntry {
        var item = MediaItem(url: "https://aiostreams.example/playback/Tulsa.King.S01E0\(e).mkv", title: "Tulsa King",
                             subtitle: "S1 · E\(e)", source: .addon(name: "AIOStreams"))
        item.historyKey = "addon:tt16358384:1:\(e)"
        item.addonRef = "series|tt16358384|tt16358384:1:\(e)"
        return HistoryEntry(item: item, position: position, duration: duration, updated: now.addingTimeInterval(-ago))
    }

    /// What Home asks for a WebDAV entry (ContinueNext.after, without the stores).
    private func next(_ e: HistoryEntry) -> [MediaItem] {
        guard case .webdav = e.item.source else { return [] }
        let shows = NextEpisodes.byShow(library)
        return ContinueNext.webdav(e.item, shows: shows) { ContinueNext.webdavItem($0, serverID: self.server, cleanTitles: true) }
    }

    private func pick(_ entries: [HistoryEntry], dismissed: [String: Double] = [:]) -> [HistoryEntry] {
        HistoryStore.pickContinueWatching(entries, now: now, dismissed: dismissed) { self.next($0) }
    }

    /// The 14 Nov evening, as the log has it: E01 from the addon (closed at
    /// 40:28, the day before), E02-E05 to their ends, E06 closed at 38:45
    /// and E07 at 40:24.
    private var reported: [HistoryEntry] {
        [addon(1, position: 2428, ago: 28 * 3600),
         dav(2, position: 2190, duration: 2190, ago: 4 * 3600),
         dav(3, position: 2300, duration: 2300, ago: 3.5 * 3600),
         dav(4, position: 2314, duration: 2314, ago: 3 * 3600),
         dav(5, position: 2143, duration: 2143, ago: 2.5 * 3600),
         dav(6, position: 2325, duration: 2383, ago: 1.5 * 3600),
         dav(7, position: 2424, duration: 2557, ago: 300)]
    }

    // MARK: The report

    func testClosedInTheCreditsCountsAsFinished() {
        XCTAssertTrue(dav(6, position: 2325, duration: 2383, ago: 0).isFinished, "97%")
        XCTAssertTrue(dav(7, position: 2424, duration: 2557, ago: 0).isFinished, "95%")
        XCTAssertTrue(addon(1, position: 2428, ago: 0).isFinished, "70 s left")
    }

    func testUntil1304TheShowLeftTheRow() {
        let film = HistoryEntry(item: HistoryStore.libraryItem("/lab/Documents/Media/Dune.Part.One.2021.2160p.mkv"),
                                position: 2095, duration: 9300, updated: now.addingTimeInterval(-7200))
        XCTAssertEqual(HistoryStore.pickContinueWatching(reported + [film]).map(\.id), [film.id], "no next episodes: no Tulsa King")
    }

    func testTheNextEpisodeFromTheSameReleaseIsTheCard() {
        let film = HistoryEntry(item: HistoryStore.libraryItem("/lab/Documents/Media/Dune.Part.One.2021.2160p.mkv"),
                                position: 2095, duration: 9300, updated: now.addingTimeInterval(-7200))
        let cw = pick(reported + [film])
        XCTAssertEqual(cw.count, 2, "one card for the show, whichever source played it")
        let card = cw[0]
        XCTAssertEqual(card.item.url, file(8).url.absoluteString, "E08 of the TRiToN release, not another one's")
        XCTAssertEqual(card.item.source, .webdav(serverID: server))
        XCTAssertEqual(card.follows, reported.last?.id)
        XCTAssertEqual(card.position, 0)
        XCTAssertFalse(card.canResume)
        XCTAssertFalse(card.isFinished)
        XCTAssertEqual(card.duration, 2557, "the last episode's length, for the widget's minutes")
        XCTAssertEqual(card.updated, reported.last?.updated, "placed by the show's last play")
        XCTAssertNil(card.item.headers["Authorization"], "the login is added at play time")
        XCTAssertEqual(cw[1].id, film.id)
        XCTAssertEqual(HistoryStore.continueShow(card).key, HistoryStore.continueShow(reported[6]).key, "Remove takes the right show away")
    }

    func testTheAddonsEpisodesAreTheSameShow() {
        let a = HistoryStore.continueShow(addon(1, position: 600, ago: 0))
        let d = HistoryStore.continueShow(dav(7, position: 600, ago: 0))
        XCTAssertEqual(a.key, d.key)
        XCTAssertEqual(a.number, HistoryStore.EpisodeNumber(season: 1, episode: 1))
        XCTAssertEqual(d.number, HistoryStore.EpisodeNumber(season: 1, episode: 7))
        var kitsu = addon(5, position: 600, ago: 0)
        kitsu.item.addonRef = "series|kitsu:46474|kitsu:46474:5"
        XCTAssertNotEqual(HistoryStore.continueShow(kitsu).key, a.key, "not an IMDb id: on its own, as before")
    }

    func testAnOlderAddonEpisodeInProgressDoesNotKeepTheCard() {
        // E01 left at 20 minutes on 13 Nov, the rest from Real-Debrid since.
        var entries = reported
        entries[0] = addon(1, position: 1200, ago: 28 * 3600)
        let cw = pick(entries)
        XCTAssertEqual(cw.map(\.item.url), [file(8).url.absoluteString], "one card: the next episode, not E01")
    }

    func testTheAddonPlayedLastGoesOnFromTheOtherSource() {
        // E08 from the addon after E07 from Real-Debrid: no addon list here,
        // so the server's episode after E08.
        let cw = pick(reported + [addon(8, position: 2480, ago: 60)])
        XCTAssertEqual(cw.map(\.item.url), [file(9).url.absoluteString])
        XCTAssertEqual(cw.first?.follows, "addon:tt16358384:1:8")
    }

    // MARK: The rules around it

    func testAnEpisodeFurtherAlongWithAPlaceStillWins() {
        // E08 begun, then E07 watched again to its end.
        let e8 = dav(8, position: 600, duration: 2500, ago: 2 * 3600)
        let cw = pick(reported + [e8])
        XCTAssertEqual(cw.map(\.id), [e8.id])
        XCTAssertNil(cw.first?.follows)
        XCTAssertEqual(cw.first?.position, 600)
    }

    func testANextEpisodeWatchedBeforeIsPassedOver() {
        let cw = pick(reported + [dav(8, position: 2500, duration: 2500, ago: 90 * 86400)])
        XCTAssertEqual(cw.map(\.item.url), [file(9).url.absoluteString])
    }

    func testTheLastEpisodeLeavesTheRow() {
        XCTAssertTrue(pick(reported + [dav(9, position: 2600, duration: 2600, ago: 10)]).isEmpty)
    }

    func testAShowFinishedLongAgoBringsNoCard() {
        XCTAssertTrue(pick([dav(7, position: 2424, duration: 2557, ago: 61 * 86400)]).isEmpty)
        XCTAssertEqual(pick([dav(7, position: 2424, duration: 2557, ago: 59 * 86400)]).count, 1)
    }

    func testRemovedStaysAwayUntilPlayedAgain() {
        let key = HistoryStore.continueShow(reported[6]).key
        let removed = [key: now.addingTimeInterval(-60).timeIntervalSince1970]
        XCTAssertTrue(pick(reported, dismissed: removed).isEmpty)
        // An older episode in progress doesn't take its place either.
        XCTAssertTrue(pick(reported + [dav(3, position: 600, ago: 5 * 3600)], dismissed: removed).isEmpty)
        let e8 = dav(8, position: 300, duration: 2500, ago: 10)
        XCTAssertEqual(pick(reported + [e8], dismissed: removed).map(\.id), [e8.id], "played again: back")
    }

    func testTheResumableOnesKeepTheirOrder() {
        // ContinueWatchingTests' case, with next episodes known.
        let a3 = dav(3, position: 600, ago: 7200)
        let a1 = dav(1, position: 600, ago: 10)
        let cw = pick([a1, a3])
        XCTAssertEqual(cw.map(\.id), [a3.id], "the episode furthest along, as before")
    }

    func testMarkAsWatchedTakesTheShowsOtherEpisodesInProgress() {
        // Home's Mark as watched on E03's card: E01, left half-watched before,
        // took its place. (The real store, with files no library has.)
        let h = HistoryStore.shared
        let dir = "/lab/Documents/Media/Zz.Lab.Mark/"
        let eps = (1...3).map { HistoryStore.libraryItem(dir + "Zz.Lab.Mark.S01E0\($0).mkv") }
        let other = HistoryStore.libraryItem(dir + "Zz.Lab.Other.S01E01.mkv")
        let keys = (eps + [other]).map(\.id)
        defer { h.setWatched(keys, false, item: HistoryStore.libraryItem) }
        h.record(eps[0], position: 300, duration: 1400)
        h.record(eps[2], position: 600, duration: 1400)
        h.record(other, position: 300, duration: 1400)
        guard let card = h.entry(forURL: eps[2].id) else { return XCTFail("no entry for E03") }
        h.markWatchedFromContinueWatching(card)
        XCTAssertTrue(h.isWatched(key: eps[2].id))
        XCTAssertTrue(h.isWatched(key: eps[0].id), "the show's other episode in progress")
        XCTAssertNil(h.entry(forURL: eps[1].id), "never played: no entry made")
        XCTAssertEqual(h.entry(forURL: other.id)?.canResume, true, "another show's isn't touched")
    }

    // MARK: Where the next episodes come from

    func testTheServersLibraryByShow() {
        let shows = NextEpisodes.byShow(library)
        XCTAssertEqual(shows[NextEpisodes.showKey("Tulsa King")]?.count, 10)
        XCTAssertEqual(shows[NextEpisodes.showKey("MobLand")]?.count, 1)
        XCTAssertNil(shows[NextEpisodes.showKey("Dune")], "a film isn't a show's episode")
        let after = ContinueNext.webdav(dav(7, position: 0, ago: 0).item, shows: shows) { ContinueNext.webdavItem($0, serverID: self.server, cleanTitles: true) }
        XCTAssertEqual(after.map(\.url), [file(8).url.absoluteString, file(9).url.absoluteString])
        XCTAssertEqual(after.first?.anime?.episode, 8)
        XCTAssertEqual(after.first?.subtitle, release, "the folder's name, as the browser's item has it")
    }

    func testALibraryShowGoesOnToItsNextFile() {
        let dir = "/private/var/mobile/Containers/Data/Application/LAB-1304/Documents/Media/"
        let files = ["Zz.Lab.Next.S01E01.mkv", "Zz.Lab.Next.S01E02.mkv", "Zz.Lab.Next.S01E03.mkv"].map { URL(fileURLWithPath: dir + $0) }
        // Saved as "/var/…": the same file (HistoryStore.libraryRelative).
        let watched = HistoryStore.libraryItem("/var/mobile/Containers/Data/Application/LAB-1304/Documents/Media/Zz.Lab.Next.S01E01.mkv")
        let after = ContinueNext.local(watched, files: files)
        XCTAssertEqual(after.map(\.historyKey), [files[1].path, files[2].path])
        XCTAssertEqual(after.first?.anime?.episode, 2)
        let e1 = HistoryEntry(item: watched, position: 1400, duration: 1420, updated: now.addingTimeInterval(-60))
        let cw = HistoryStore.pickContinueWatching([e1], now: now, dismissed: [:]) { ContinueNext.local($0.item, files: files) }
        XCTAssertEqual(cw.map(\.id), [files[1].path])
        XCTAssertEqual(cw.first?.follows, e1.id)
    }
}
