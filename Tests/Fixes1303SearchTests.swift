import XCTest
@testable import Folio

/// 1.30.3: Home's Real-Debrid row follows what the server's start folder
/// lists (a deleted release leaves it), the search's Movies and Shows chips
/// get a fuller list, "Yours" reads "Library", and a server's matches are
/// capped by release, not by file.
final class Fixes1303SearchTests: XCTestCase {
    // MARK: Real-Debrid row

    /// Folder → its listing, and which folders were asked for.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var tree: [String: [DAVItem]] = [:]
        private var askedKeys: [String] = []
        var asked: [String] { lock.lock(); defer { lock.unlock() }; return askedKeys }

        func set(_ folder: URL, _ items: [DAVItem]) { lock.lock(); tree[LibraryIndex.key(folder)] = items; lock.unlock() }
        func resetCount() { lock.lock(); askedKeys = []; lock.unlock() }
        func list(_ url: URL) throws -> [DAVItem] {
            lock.lock(); defer { lock.unlock() }
            let k = LibraryIndex.key(url)
            askedKeys.append(k)
            return tree[k] ?? []
        }
    }

    private let root = URL(string: "https://dav.example.invalid/torrents/")!
    private let names = ["MobLand.S01.2160p.AMZN.WEB-DL.DDP5.1.H.265-NTb", "Dune.Part.Two.2024.2160p.UHD.BluRay-FGT", "Silo.S02.1080p.ATVP.WEB-DL-FLUX"]

    private func folder(_ name: String, modified: TimeInterval) -> DAVItem {
        DAVItem(url: root.appendingPathComponent(name, isDirectory: true), name: name, isDirectory: true, size: nil,
                modified: Date(timeIntervalSince1970: modified), contentType: nil)
    }

    private func file(_ folder: String) -> DAVItem {
        DAVItem(url: root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(folder + ".mkv"), name: folder + ".mkv",
                isDirectory: false, size: 1_000_000, modified: Date(timeIntervalSince1970: 1), contentType: nil)
    }

    private func server(_ names: [String]) -> Server {
        let s = Server()
        s.set(root, names.enumerated().map { folder($0.element, modified: Double(100 * ($0.offset + 1))) })
        for n in names { s.set(root.appendingPathComponent(n, isDirectory: true), [file(n)]) }
        return s
    }

    private func indexer(_ s: Server) -> LibraryIndexer { LibraryIndexer(list: { try s.list($0) }) }
    private func empty() -> LibraryIndex { LibraryIndex(account: "test", root: LibraryIndex.key(root)) }

    /// A release deleted on the server is gone from the index, its files
    /// and Home's row after the start folder's next listing: one request.
    func testAReleaseGoneFromTheStartFolderLeavesTheIndexAndTheRow() async {
        let s = server(names)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true, now: t0)
        XCTAssertEqual(LibraryIndexStore.newestReleases(first, limit: 20).count, 3)

        // Dune is deleted on Real-Debrid; nothing else changes (no new date or etag anywhere).
        s.set(root, [folder(names[0], modified: 100), folder(names[2], modified: 300)])
        s.resetCount()
        let (second, report) = await indexer(s).refresh(first, rootURL: root, full: false, turns: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(s.asked, [LibraryIndex.key(root)], "more than the start folder was listed")
        XCTAssertEqual(report.listed, 1)
        XCTAssertEqual(report.kept, 2)
        let gone = LibraryIndex.key(root.appendingPathComponent(names[1], isDirectory: true))
        XCTAssertNil(second.folders[gone], "the deleted release's folder is still in the index")
        XCTAssertEqual(second.allFiles.map(\.name).sorted(), [names[0] + ".mkv", names[2] + ".mkv"])
        XCTAssertEqual(Set(LibraryIndexStore.newestReleases(second, limit: 20).map(\.name)), [names[0], names[2]])
        let summary = LibraryIndexStore.build(second).summary
        XCTAssertEqual(summary.files, 2)
        XCTAssertEqual(summary.releases?.contains { $0.name == names[1] }, false)
    }

    /// The quick check leaves the folders due "in their turn" for the
    /// regular refresh; that one still lists them.
    func testTheQuickCheckSkipsTurns() async {
        let s = server(names)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true, now: t0)
        let later = t0.addingTimeInterval(2 * 3600)        // every folder's turn has come

        s.resetCount()
        _ = await indexer(s).refresh(first, rootURL: root, full: false, turns: false, now: later)
        XCTAssertEqual(s.asked.count, 1)

        s.resetCount()
        let (third, _) = await indexer(s).refresh(first, rootURL: root, full: false, now: later)
        XCTAssertEqual(s.asked.count, 4, "the regular refresh no longer lists the folders in their turn")
        XCTAssertEqual(third.folders.count, 4)
    }

    /// A new release is read by the quick check too.
    func testTheQuickCheckReadsANewRelease() async {
        let s = server(Array(names.prefix(2)))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true, now: t0)
        s.set(root, names.enumerated().map { folder($0.element, modified: Double(100 * ($0.offset + 1))) })
        s.set(root.appendingPathComponent(names[2], isDirectory: true), [file(names[2])])
        let (second, _) = await indexer(s).refresh(first, rootURL: root, full: false, turns: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(second.allFiles.count, 3)
    }

    func testWhenTheStartFolderIsAskedAgain() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(LibraryIndexStore.rootCheckDue(last: nil, now: now, every: 60))
        XCTAssertFalse(LibraryIndexStore.rootCheckDue(last: now.addingTimeInterval(-30), now: now, every: 60))
        XCTAssertTrue(LibraryIndexStore.rootCheckDue(last: now.addingTimeInterval(-61), now: now, every: 60))
        // See all was opened: asked whatever the time.
        XCTAssertTrue(LibraryIndexStore.rootCheckDue(last: now, now: now, every: 0))
        // The clock went back.
        XCTAssertTrue(LibraryIndexStore.rootCheckDue(last: now.addingTimeInterval(500), now: now, every: 60))
    }

    // MARK: Search

    private func meta(_ n: Int, series: Bool = false) -> MetaItem {
        MetaItem(id: "tt\(n)", type: series ? "series" : "movie", name: "Title \(n)", poster: nil, description: nil,
                 releaseInfo: "2024", imdbRating: nil, genres: nil)
    }

    func testLibraryIsTheChipsName() {
        XCTAssertEqual(SearchScope.yours.title, "Library")
        XCTAssertEqual(SearchScope.yours.rawValue, "yours", "the chip's identifier changed")
    }

    /// The suggestions keep their places; the fuller lists come after, each title once.
    func testFullerListsComeAfterTheSuggestionsOnce() {
        let suggestions = [meta(1, series: true), meta(2), meta(3, series: true)]
        let fuller = ["series": [meta(3, series: true), meta(4, series: true), meta(1, series: true), meta(5, series: true)],
                      "movie": [meta(2), meta(6)]]
        let all = DiscoverSearch.merged(suggestions, fuller: fuller)
        XCTAssertEqual(all.map(\.id), ["tt1", "tt2", "tt3", "tt6", "tt4", "tt5"])
        XCTAssertEqual(DiscoverSearch.merged(suggestions, fuller: [:]).map(\.id), ["tt1", "tt2", "tt3"])
    }

    @MainActor
    func testTheShowsChipListsTheFullerList() {
        let suggestions = [meta(1, series: true), meta(2), meta(3, series: true)]
        let more = (10..<40).map { meta($0, series: true) }
        let r = SearchResults(imdb: DiscoverSearch.merged(suggestions, fuller: ["series": more]))
        XCTAssertEqual(r.shows.count, 32)
        XCTAssertEqual(r.movies.count, 1)
        // "All" still opens on the suggestions.
        XCTAssertEqual(r.titlesShort.prefix(3).map(\.id), ["title|tt1", "title|tt2", "title|tt3"])
        XCTAssertEqual(r.hiddenShows, 32 - 7)
    }

    func testAFullerListIsAskedOncePerQueryAndKind() {
        XCTAssertTrue(DiscoverSearch.shouldAskFuller(type: "series", query: "mon", current: "", asked: []))
        XCTAssertFalse(DiscoverSearch.shouldAskFuller(type: "series", query: "mon", current: "mon", asked: ["series"]))
        XCTAssertTrue(DiscoverSearch.shouldAskFuller(type: "movie", query: "mon", current: "mon", asked: ["series"]))
        // Another text: asked again.
        XCTAssertTrue(DiscoverSearch.shouldAskFuller(type: "series", query: "mone", current: "mon", asked: ["series"]))
        // One letter: never.
        XCTAssertFalse(DiscoverSearch.shouldAskFuller(type: "series", query: "m", current: "", asked: []))
    }

    // MARK: A server's matches, by release

    private func indexFile(_ folder: String?, _ name: String) -> LibraryIndex.File {
        let dir = folder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        return LibraryIndex.File(url: dir.appendingPathComponent(name), name: name, size: 1, added: nil)
    }

    func testReleaseKey() {
        let r = LibraryIndex.key(root)
        XCTAssertEqual(LibrarySearchResults.releaseKey(r + "Show.S01/E01.mkv", root: r), "Show.S01")
        XCTAssertEqual(LibrarySearchResults.releaseKey(r + "Show.S01/Extras/A.mkv", root: r), "Show.S01")
        // At the top, or somewhere else: the file itself.
        XCTAssertEqual(LibrarySearchResults.releaseKey(r + "Film.mkv", root: r), r + "Film.mkv")
        XCTAssertEqual(LibrarySearchResults.releaseKey("https://other.invalid/a/b.mkv", root: r), "https://other.invalid/a/b.mkv")
        XCTAssertEqual(LibrarySearchResults.releaseKey(r + "Show.S01/E01.mkv", root: nil), r + "Show.S01/E01.mkv")
    }

    /// 60 episodes of one season are one release with all 60; the cap
    /// counts releases.
    func testTheCapCountsReleasesNotFiles() {
        var files = (1...60).map { indexFile("Show.S01.1080p.WEB-DL-GRP", String(format: "Show.S01E%02d.mkv", $0)) }
        files += (1...5).map { indexFile("Film.\($0).2024.1080p.BluRay-GRP", "Film.\($0).mkv") }
        // A late file of the first release, after the cap is full.
        files.append(indexFile("Show.S01.1080p.WEB-DL-GRP", "Show.S01E61.mkv"))
        let kept = LibrarySearchResults.capByRelease(files, root: LibraryIndex.key(root), cap: 3)
        XCTAssertEqual(kept.filter { $0.name.hasPrefix("Show.S01E") }.count, 61)
        XCTAssertEqual(kept.filter { $0.name.hasPrefix("Film.") }.map(\.name), ["Film.1.mkv", "Film.2.mkv"])
        XCTAssertEqual(LibrarySearchResults.capByRelease(files, root: LibraryIndex.key(root), cap: 40).count, files.count)
    }
}
