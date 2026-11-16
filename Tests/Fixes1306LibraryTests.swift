import XCTest
@testable import Folio

/// 1.30.6: a finished download's stream folded into its copy, a season's
/// finale not bringing back an older place, a widget's link to a library
/// card after a container move, the library index told of real changes
/// only, its cap, and pull to refresh's wait.
@MainActor
final class Fixes1306LibraryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_800_000)
    private let serverID = UUID()
    private let dav = URL(string: "https://dav.real-debrid.com/torrents/")!
    private let media = "/private/var/mobile/Containers/Data/Application/LAB-1306/Documents/Media/"

    /// A WebDAV file's entry, as the browser's item is saved.
    private func stream(_ name: String, position: Double, duration: Double = 7200, ago: TimeInterval) -> HistoryEntry {
        let f = LibraryIndex.File(url: dav.appendingPathComponent(name), name: name, size: 1, added: nil)
        return HistoryEntry(item: ContinueNext.webdavItem(f, serverID: serverID, cleanTitles: true),
                            position: position, duration: duration, updated: now.addingTimeInterval(-ago))
    }

    /// The downloaded copy's entry, as carryToDownloads makes it.
    private func copy(_ name: String, position: Double, duration: Double = 7200, ago: TimeInterval) -> HistoryEntry {
        HistoryEntry(item: ContinueQueue.libraryItem(URL(fileURLWithPath: media + name)), position: position, duration: duration,
                     updated: now.addingTimeInterval(-ago))
    }

    // MARK: H1: a finished download and its stream

    private let film = "Zz.Lab.Film.2024.1080p.WEB-DL.mkv"

    func testUntil1306AFilmAndItsCopyWereTwoCards() {
        let s = stream(film, position: 2400, ago: 600)
        let c = copy(film, position: 2400, ago: 599)
        XCTAssertNotEqual(HistoryStore.continueShow(s).key, HistoryStore.continueShow(c).key, "keyed by address and by name")
        XCTAssertEqual(HistoryStore.pickContinueWatching([s, c], now: now, dismissed: [:]) { _ in [] }.count, 2)
    }

    func testACopyWithNoEntryTakesTheStreamsPlace() {
        let s = stream(film, position: 2400, ago: 600)
        let item = ContinueQueue.libraryItem(URL(fileURLWithPath: media + film))
        let e = HistoryStore.carriedToCopy(s, copy: nil, item: item)
        XCTAssertEqual(e?.id, item.id)
        XCTAssertEqual(e?.position, 2400)
        XCTAssertEqual(e?.duration, 7200)
        XCTAssertEqual(e?.updated, s.updated.addingTimeInterval(1))
        XCTAssertNil(e?.watched)
    }

    func testACopyPlayedSinceKeepsItsOwnPlace() {
        let s = stream(film, position: 2400, ago: 600)
        let c = copy(film, position: 3000, ago: 60)
        XCTAssertNil(HistoryStore.carriedToCopy(s, copy: c, item: c.item), "the copy is the newer: it stays")
        let done = copy(film, position: 7200, ago: 60)
        XCTAssertNil(HistoryStore.carriedToCopy(s, copy: done, item: done.item), "watched to its end since: stays watched")
    }

    func testAStreamPlayedAfterTheCopyGivesItItsPlace() {
        let c = copy(film, position: 1200, ago: 3600)
        let s = stream(film, position: 2400, duration: 0, ago: 60)
        let e = HistoryStore.carriedToCopy(s, copy: c, item: c.item)
        XCTAssertEqual(e?.id, c.id)
        XCTAssertEqual(e?.position, 2400)
        XCTAssertEqual(e?.duration, 7200, "the copy's length when the stream had none")
        XCTAssertEqual(e?.updated, s.updated)

        // A copy watched to its end, then streamed again: a look keeps the
        // mark, past the first minute it's being watched again.
        var watched = copy(film, position: 7200, ago: 3600)
        watched.watched = true
        XCTAssertEqual(HistoryStore.carriedToCopy(stream(film, position: 30, ago: 60), copy: watched, item: watched.item)?.watched, true)
        let again = HistoryStore.carriedToCopy(stream(film, position: 2400, ago: 60), copy: watched, item: watched.item)
        XCTAssertNotEqual(again?.watched, true)
        XCTAssertEqual(again?.canResume, true)
    }

    /// The report's case, in the real store: streamed to 40 minutes, then
    /// downloaded. The copy gets the place and is the one card; the
    /// stream's entry stays for the server's browser (post-fix review:
    /// removing it lost the place there, and with the copy deleted).
    func testTheStreamsPlaceGoesToTheCopyAndOneCardShows() {
        let h = HistoryStore.shared
        let name = "Zz.Lab.Carry.2024.1080p.mkv"
        let s = stream(name, position: 0, ago: 0)
        let copyPath = media + name
        defer { h.setWatched([s.id, copyPath], false, item: HistoryStore.libraryItem) }
        h.record(s.item, position: 2400, duration: 7200)
        XCTAssertTrue(h.carry(streamURL: s.item.url, to: copyPath))
        guard let kept = h.entry(forURL: s.item.url) else { return XCTFail("the stream's entry went") }
        XCTAssertEqual(kept.position, 2400, "the browser still resumes the stream at its place")
        guard let c = h.entry(forURL: copyPath) else { return XCTFail("no entry for the copy") }
        XCTAssertEqual(c.position, 2400)
        let shown = HistoryStore.hidingCopiedStreams([kept, c], copies: [s.item.url: copyPath])
        XCTAssertEqual(HistoryStore.pickContinueWatching(shown, now: Date(), dismissed: [:]) { _ in [] }.map(\.id), [c.id])
        XCTAssertFalse(h.carry(streamURL: s.item.url, to: copyPath), "the copy has it already")

        // A watched stream isn't carried: its mark stays where it is.
        h.record(s.item, position: 7200, duration: 7200)
        XCTAssertFalse(h.carry(streamURL: s.item.url, to: copyPath))
        XCTAssertEqual(h.entry(forURL: s.item.url)?.isFinished, true)
    }

    /// Of a stream and its copy, the newer is the card: a stream played
    /// again after the download shows, its copy doesn't; the copy played
    /// since, the other way round; a stream with no copy entry shows.
    func testTheNewerOfAStreamAndItsCopyIsTheCard() {
        let path = media + film
        let s = stream(film, position: 2400, ago: 60)
        let c = copy(film, position: 1200, ago: 3600)
        let copies = [s.item.url: path]
        XCTAssertEqual(HistoryStore.hidingCopiedStreams([s, c], copies: copies).map(\.id), [s.id])
        let later = copy(film, position: 3000, ago: 10)
        XCTAssertEqual(HistoryStore.hidingCopiedStreams([s, later], copies: copies).map(\.id), [later.id])
        XCTAssertEqual(HistoryStore.hidingCopiedStreams([s], copies: copies).map(\.id), [s.id])
        // The copy found by its place in Media after a container move.
        let moved = "/private/var/mobile/Containers/Data/Application/LAB-OTHER/Documents/Media/" + film
        XCTAssertEqual(HistoryStore.hidingCopiedStreams([s, later], copies: [s.item.url: moved]).map(\.id), [later.id])
    }

    // MARK: H1: a season's finale

    private func episode(_ e: Int) -> String { "Zz.Lab.Finale.S01E\(String(format: "%02d", e)).1080p.WEB-GRP.mkv" }

    func testAFinaleWatchedFromTheCopyDoesNotBringBackTheStream() {
        // E10 streamed to 40 minutes, downloaded, the copy watched to its end.
        let s = stream(episode(10), position: 2400, duration: 3000, ago: 3600)
        let c = copy(episode(10), position: 3000, duration: 3000, ago: 60)
        XCTAssertEqual(HistoryStore.continueShow(s).key, HistoryStore.continueShow(c).key)
        XCTAssertTrue(HistoryStore.pickContinueWatching([s, c], now: now, dismissed: [:]) { _ in [] }.isEmpty)
        // An older episode left in progress before it doesn't come back either.
        let e8 = stream(episode(8), position: 600, duration: 3000, ago: 7200)
        XCTAssertTrue(HistoryStore.pickContinueWatching([e8, c], now: now, dismissed: [:]) { _ in [] }.isEmpty)
    }

    func testAnEpisodeFurtherAlongStillComesBack() {
        // E11 begun, then E10 watched again to its end.
        let e11 = stream(episode(11), position: 600, duration: 3000, ago: 7200)
        let e10 = copy(episode(10), position: 3000, duration: 3000, ago: 60)
        XCTAssertEqual(HistoryStore.pickContinueWatching([e11, e10], now: now, dismissed: [:]) { _ in [] }.map(\.id), [e11.id])
        // In progress after the finished one: as before.
        let later = stream(episode(9), position: 600, duration: 3000, ago: 10)
        XCTAssertEqual(HistoryStore.pickContinueWatching([later, e10], now: now, dismissed: [:]) { _ in [] }.map(\.id), [later.id])
        // A film has no number: as before.
        let f = stream(film, position: 2400, ago: 60)
        XCTAssertEqual(HistoryStore.pickContinueWatching([f], now: now, dismissed: [:]) { _ in [] }.map(\.id), [f.id])
    }

    // MARK: H4: a link to a library card after a container move

    func testALibraryCardIsFoundByItsPlaceInMedia() {
        let next = ContinueQueue.libraryItem(URL(fileURLWithPath: media + "Zz.Lab.Link.S01E02.mkv"))
        let card = HistoryEntry(item: next, position: 0, duration: 0, updated: now, follows: media + "Zz.Lab.Link.S01E01.mkv")
        let moved = "/var/mobile/Containers/Data/Application/OLD-1305/Documents/Media/Zz.Lab.Link.S01E02.mkv"
        XCTAssertEqual(HistoryStore.nextCard(next.id, in: [card])?.id, card.id)
        XCTAssertEqual(HistoryStore.nextCard(moved, in: [card])?.id, card.id, "the link from before the update")
        XCTAssertNil(HistoryStore.nextCard(media + "Zz.Lab.Link.S01E03.mkv", in: [card]))
        var entry = card
        entry.follows = nil
        XCTAssertNil(HistoryStore.nextCard(moved, in: [entry]), "only next-episode cards: entries are found by entry(for:)")
        let davCard = HistoryEntry(item: stream(episode(2), position: 0, ago: 0).item, position: 0, duration: 0, updated: now, follows: "x")
        XCTAssertEqual(HistoryStore.nextCard(davCard.id, in: [card, davCard])?.id, davCard.id)
    }

    // MARK: H5: the index told of real changes only

    private let root = URL(string: "https://dav.example.invalid/torrents/")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let modified = Date(timeIntervalSince1970: 100)

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var tree: [String: [DAVItem]] = [:]
        private var askedKeys: [String] = []
        var asked: [String] { lock.lock(); defer { lock.unlock() }; return askedKeys }
        func set(_ folder: URL, _ items: [DAVItem]) { lock.lock(); tree[LibraryIndex.key(folder)] = items; lock.unlock() }
        func list(_ url: URL) throws -> [DAVItem] {
            lock.lock(); defer { lock.unlock() }
            let k = LibraryIndex.key(url)
            askedKeys.append(k)
            return tree[k] ?? []
        }
    }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path, isDirectory: true) }
    private func key(_ path: String) -> String { LibraryIndex.key(url(path)) }
    private func folderItem(_ path: String) -> DAVItem {
        DAVItem(url: url(path), name: (path as NSString).lastPathComponent, isDirectory: true, size: nil, modified: modified, contentType: nil)
    }
    private func fileItem(_ folder: String, _ name: String) -> DAVItem {
        DAVItem(url: url(folder).appendingPathComponent(name), name: name, isDirectory: false, size: 1_000_000, modified: modified, contentType: nil)
    }
    private func indexer(_ s: Server, cap: Int = LibraryIndexer.folderCap) -> LibraryIndexer {
        var i = LibraryIndexer(list: { try s.list($0) })
        i.maxFolders = cap
        return i
    }
    private func empty() -> LibraryIndex { LibraryIndex(account: "test", root: LibraryIndex.key(root)) }

    /// Releases, each with an episode and a Subs folder.
    private func releases(_ names: [String]) -> Server {
        let s = Server()
        s.set(root, names.map(folderItem))
        for n in names {
            s.set(url(n), [fileItem(n, "\(n).S01E01.1080p.mkv"), folderItem(n + "/Subs")])
            s.set(url(n + "/Subs"), [])
        }
        return s
    }

    func testACheckThatMovedOnlyDatesHasTheSameContent() async {
        let s = releases(["R1", "R2"])
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true, now: t0)
        let (checked, _) = await indexer(s).refresh(first, rootURL: root, full: false, turns: false, now: t0.addingTimeInterval(60))
        XCTAssertNotEqual(first.refreshed, checked.refreshed)
        XCTAssertTrue(LibraryIndexStore.sameContent(first, checked))

        // Listed in their turn: their dates move, and only those.
        let (turned, _) = await indexer(s).refresh(first, rootURL: root, full: false, turns: true, now: t0.addingTimeInterval(2 * 3600))
        XCTAssertFalse(LibraryIndexStore.sameOnDisk(first, turned), "saved: the turns go by those dates")
        XCTAssertTrue(LibraryIndexStore.sameContent(first, turned), "nothing made from it changed")

        var refused = checked
        refused.lastCheck?.ok = false
        XCTAssertFalse(LibraryIndexStore.sameContent(checked, refused), "Home says offline")
        var never = checked
        never.refreshed = nil
        XCTAssertFalse(LibraryIndexStore.sameContent(checked, never))

        s.set(root, ["R1", "R2", "R3"].map(folderItem))
        s.set(url("R3"), [fileItem("R3", "R3.S01E01.1080p.mkv")])
        let (added, _) = await indexer(s).refresh(checked, rootURL: root, full: false, turns: false, now: t0.addingTimeInterval(120))
        XCTAssertFalse(LibraryIndexStore.sameContent(checked, added), "a new release")
        var renamed = checked
        renamed.folders[key("R1")]?.files[0].name = "R1.S01E01.720p.mkv"
        XCTAssertFalse(LibraryIndexStore.sameContent(checked, renamed), "a file changed in place")
    }

    // MARK: D5: the cap

    func testNearTheCapAChangesOnlyRefreshKeepsWhatWasIndexed() async {
        // Seven folders: the start folder, three releases and their Subs.
        let s = releases(["R1", "R2", "R3"])
        let (first, report) = await indexer(s, cap: 7).refresh(empty(), rootURL: root, full: true, now: t0)
        XCTAssertEqual(first.folders.count, 7)
        XCTAssertEqual(report.unread, 0)

        // Two new releases listed first. Until 1.30.6 R3 was dropped: the
        // folders seen counted R1's and R2's Subs as they were kept.
        s.set(root, ["R0", "R00", "R1", "R2", "R3"].map(folderItem))
        let (second, changes) = await indexer(s, cap: 7).refresh(first, rootURL: root, full: false, turns: false, now: t0.addingTimeInterval(60))
        XCTAssertEqual(Set(second.folders.keys), Set(first.folders.keys), "every folder indexed before is kept")
        XCTAssertEqual(changes.unread, 2, "the new ones past the cap are counted")
        XCTAssertEqual(second.unread, 2)
        XCTAssertEqual(second.folders[second.root]?.subfolders, ["R0", "R00", "R1", "R2", "R3"].map(key), "in the listing's order")
        XCTAssertEqual(second.allFiles.count, 3)

        // With room, the new ones come in.
        s.set(url("R0"), [fileItem("R0", "R0.S01E01.1080p.mkv")])
        let (third, roomy) = await indexer(s, cap: 9).refresh(second, rootURL: root, full: false, turns: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(roomy.unread, 0)
        XCTAssertNil(third.unread)
        XCTAssertEqual(third.folders.count, 9)
        XCTAssertEqual(third.allFiles.count, 4)
    }

    func testAFullRefreshStillStopsAtTheCap() async {
        let s = releases(["R1", "R2", "R3", "R4"])
        let (index, report) = await indexer(s, cap: 6).refresh(empty(), rootURL: root, full: true, now: t0)
        XCTAssertEqual(index.folders.count, 6, "the start folder, four releases and one Subs")
        XCTAssertEqual(report.unread, 3)
    }

    // MARK: H2: pull to refresh's wait

    func testThePullWaitsAtMostItsLimitAndTheRefreshCarriesOn() async {
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        let long = Task { try? await Task.sleep(for: .milliseconds(900)); flag.done = true }
        let t = Date()
        await HomeView.wait(for: long, atMost: .milliseconds(150))
        let waited = Date().timeIntervalSince(t)
        XCTAssertLessThan(waited, 0.7, "waited for the refresh")
        XCTAssertFalse(flag.done)
        await long.value
        XCTAssertTrue(flag.done, "the refresh went on after the wait")

        let short = Task { _ = try? await Task.sleep(for: .milliseconds(50)) }
        let t2 = Date()
        await HomeView.wait(for: short, atMost: .seconds(3))
        XCTAssertLessThan(Date().timeIntervalSince(t2), 1.5, "a refresh done early ends the wait")
        XCTAssertGreaterThan(HomeView.refreshWait, .zero)
    }
}
