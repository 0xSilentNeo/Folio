import XCTest
@testable import Folio

/// 1.30.4: the Keychain read once per login, the library index's turns, a
/// refused subfolder, its cap, Home told only of real changes, Fix Match
/// across a show's specials, watchlist ids, server messages and pictures.
final class Fixes1304LibraryTests: XCTestCase {
    // MARK: Keychain

    /// A fake Keychain: the values, and how many reads reached it.
    private final class Store {
        var values: [String: String] = [:]
        var reads = 0
        var failing = false
        func read(_ account: String) -> SecretCache.Read {
            reads += 1
            if failing { return .failed }
            return values[account].map { .found($0) } ?? .missing
        }
    }

    func testAKeychainValueIsReadOnceUntilItChanges() {
        let cache = SecretCache(), store = Store()
        store.values["token"] = "abc"
        XCTAssertEqual(cache.value(for: "token") { store.read("token") }, "abc")
        XCTAssertEqual(cache.value(for: "token") { store.read("token") }, "abc")
        XCTAssertEqual(store.reads, 1, "the second read asked the Keychain again")

        store.values["token"] = "def"
        cache.forget("token")
        XCTAssertEqual(cache.value(for: "token") { store.read("token") }, "def", "a value set is read again")
        XCTAssertEqual(store.reads, 2)

        // Nothing saved: kept as missing, until something is.
        XCTAssertNil(cache.value(for: "password") { store.read("password") })
        XCTAssertNil(cache.value(for: "password") { store.read("password") })
        XCTAssertEqual(store.reads, 3)
        store.values["password"] = "secret"
        cache.forget("password")
        XCTAssertEqual(cache.value(for: "password") { store.read("password") }, "secret")
    }

    /// The phone not yet unlocked: the read fails and is asked again next time.
    func testAFailedReadIsNotKept() {
        let cache = SecretCache(), store = Store()
        store.values["token"] = "abc"
        store.failing = true
        XCTAssertNil(cache.value(for: "token") { store.read("token") })
        store.failing = false
        XCTAssertEqual(cache.value(for: "token") { store.read("token") }, "abc")
        XCTAssertEqual(store.reads, 2)
    }

    /// A value changed while it was being read: the old one isn't kept.
    func testAReadOverlappingAChangeIsNotKept() {
        let cache = SecretCache(), store = Store()
        store.values["token"] = "old"
        let first = cache.value(for: "token") { () -> SecretCache.Read in
            let r = store.read("token")
            store.values["token"] = "new"
            cache.forget("token")
            return r
        }
        XCTAssertEqual(first, "old")
        XCTAssertEqual(cache.value(for: "token") { store.read("token") }, "new")
    }

    // MARK: Library index

    /// Folder → its listing or an error, and which folders were asked for.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var tree: [String: [DAVItem]] = [:]
        private var errors: [String: Error] = [:]
        private var askedKeys: [String] = []
        var asked: [String] { lock.lock(); defer { lock.unlock() }; return askedKeys }

        func set(_ folder: URL, _ items: [DAVItem]) { lock.lock(); tree[LibraryIndex.key(folder)] = items; lock.unlock() }
        func fail(_ folder: URL, _ error: Error?) { lock.lock(); errors[LibraryIndex.key(folder)] = error; lock.unlock() }
        func resetCount() { lock.lock(); askedKeys = []; lock.unlock() }
        func list(_ url: URL) throws -> [DAVItem] {
            lock.lock(); defer { lock.unlock() }
            let k = LibraryIndex.key(url)
            askedKeys.append(k)
            if let e = errors[k] { throw e }
            return tree[k] ?? []
        }
    }

    private let root = URL(string: "https://dav.example.invalid/torrents/")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let modified = Date(timeIntervalSince1970: 100)

    private func url(_ path: String) -> URL { root.appendingPathComponent(path, isDirectory: true) }
    private func key(_ path: String) -> String { LibraryIndex.key(url(path)) }

    private func folderItem(_ path: String) -> DAVItem {
        DAVItem(url: url(path), name: (path as NSString).lastPathComponent, isDirectory: true, size: nil, modified: modified, contentType: nil)
    }

    private func fileItem(_ folder: String, _ name: String) -> DAVItem {
        DAVItem(url: url(folder).appendingPathComponent(name), name: name, isDirectory: false, size: 1_000_000, modified: modified, contentType: nil)
    }

    private func indexer(_ s: Server) -> LibraryIndexer { LibraryIndexer(list: { try s.list($0) }) }
    private func empty() -> LibraryIndex { LibraryIndex(account: "test", root: LibraryIndex.key(root)) }

    /// Releases R1, R2 and R3, an episode each.
    private func server() -> Server {
        let s = Server()
        let names = ["R1", "R2", "R3"]
        s.set(root, names.map(folderItem))
        for n in names { s.set(url(n), [fileItem(n, "\(n).S01E01.1080p.mkv")]) }
        return s
    }

    /// Thirty folders inside one release, listed longer ago than the
    /// releases: they took every turn, and no release was listed again.
    func testOnlyTheStartFoldersOwnFoldersTakeTurns() async {
        let rootKey = LibraryIndex.key(root)
        let deep = (0..<30).map { "R1/D\($0)" }
        var old = empty()
        old.folders[rootKey] = LibraryIndex.Folder(name: "torrents", etag: nil, modified: nil, added: nil, listed: t0.addingTimeInterval(-120),
                                                   subfolders: [key("R1"), key("R2")], files: [])
        old.folders[key("R1")] = LibraryIndex.Folder(name: "R1", etag: nil, modified: modified, added: modified, listed: t0.addingTimeInterval(-2 * 3600),
                                                     subfolders: deep.map(key), files: [])
        old.folders[key("R2")] = LibraryIndex.Folder(name: "R2", etag: nil, modified: modified, added: modified, listed: t0.addingTimeInterval(-2 * 3600),
                                                     subfolders: [], files: [])
        for d in deep {
            old.folders[key(d)] = LibraryIndex.Folder(name: (d as NSString).lastPathComponent, etag: nil, modified: modified, added: modified,
                                                      listed: t0.addingTimeInterval(-5 * 3600), subfolders: [], files: [])
        }
        XCTAssertEqual(LibraryIndexer.turnFolders(old, root: rootKey, now: t0), [key("R1"), key("R2")])
        XCTAssertEqual(LibraryIndexer.turnFolders(old, root: rootKey, now: t0, enabled: false), [])

        let s = Server()
        s.set(root, [folderItem("R1"), folderItem("R2")])
        s.set(url("R1"), deep.map(folderItem))
        let (fresh, _) = await indexer(s).refresh(old, rootURL: root, full: false, now: t0)
        XCTAssertEqual(Set(s.asked), [rootKey, key("R1"), key("R2")], "the releases weren't listed in their turn")
        XCTAssertEqual(fresh.folders.count, 33, "the folders inside were dropped")
    }

    /// One release folder refusing the login isn't the account refusing it.
    func testARefusedSubfolderIsNotARefusedLogin() async {
        let s = server()
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true, now: t0)
        s.fail(url("R2"), WebDAVError.unauthorized)
        let (second, report) = await indexer(s).refresh(first, rootURL: root, full: true, now: t0.addingTimeInterval(120))
        XCTAssertEqual(report.failed, 1)
        XCTAssertFalse(report.unauthorized)
        XCTAssertEqual(second.lastCheck?.unauthorized, false)
        XCTAssertEqual(second.lastCheck?.ok, true)
        XCTAssertEqual(second.allFiles.count, 3, "the refused folder's saved files went")
        let summary = LibraryIndexStore.build(second).summary
        XCTAssertFalse(summary.unauthorized, "Home would hide the section")

        s.fail(root, WebDAVError.unauthorized)
        let (third, refused) = await indexer(s).refresh(second, rootURL: root, full: false, now: t0.addingTimeInterval(240))
        XCTAssertTrue(refused.unauthorized, "the start folder's refusal is the account's")
        XCTAssertEqual(third.lastCheck?.unauthorized, true)
    }

    /// Folders past the cap are counted, kept in the index and said on Home.
    func testFoldersPastTheCapAreCounted() async {
        let s = Server()
        let names = (1...5).map { "R\($0)" }
        s.set(root, names.map(folderItem))
        var capped = indexer(s)
        capped.maxFolders = 3                // the start folder and two more
        let (index, report) = await capped.refresh(empty(), rootURL: root, full: true, now: t0)
        XCTAssertEqual(report.unread, 3)
        XCTAssertEqual(index.unread, 3)
        let summary = LibraryIndexStore.build(index).summary
        XCTAssertEqual(summary.unread, 3)
        XCTAssertTrue(RealDebrid.subtitle(summary).contains("first"), RealDebrid.subtitle(summary))

        let (whole, all) = await indexer(s).refresh(empty(), rootURL: root, full: true, now: t0)
        XCTAssertEqual(all.unread, 0)
        XCTAssertNil(whole.unread)
        XCTAssertFalse(RealDebrid.subtitle(LibraryIndexStore.build(whole).summary).contains("first"))
        XCTAssertGreaterThan(LibraryIndexer.folderCap, 3000)
    }

    /// A check that changed nothing but its dates isn't written again.
    func testACheckThatChangedOnlyDatesIsTheSameOnDisk() async {
        let s = server()
        let (first, _) = await indexer(s).refresh(empty(), rootURL: root, full: true, now: t0)
        let (second, _) = await indexer(s).refresh(first, rootURL: root, full: false, turns: false, now: t0.addingTimeInterval(120))
        XCTAssertNotEqual(first, second, "the dates moved")
        XCTAssertTrue(LibraryIndexStore.sameOnDisk(first, second))

        var refused = second
        refused.lastCheck?.ok = false
        XCTAssertFalse(LibraryIndexStore.sameOnDisk(second, refused), "how the server answered is saved")

        s.set(root, ["R1", "R2", "R3", "R4"].map(folderItem))
        s.set(url("R4"), [fileItem("R4", "R4.S01E01.1080p.mkv")])
        let (third, _) = await indexer(s).refresh(second, rootURL: root, full: false, turns: false, now: t0.addingTimeInterval(240))
        XCTAssertFalse(LibraryIndexStore.sameOnDisk(second, third), "a new release is saved")
    }

    /// Home is told only when what it shows changes, not of each check's date.
    func testHomeIsToldOnlyOfRealChanges() {
        let a = IndexSummaries.Summary(files: 3, bytes: 3_000_000, refreshed: t0, unauthorized: false, offline: false, releases: [])
        var later = a
        later.refreshed = t0.addingTimeInterval(60)
        XCTAssertFalse(IndexSummaries.changed(a, later), "a new date alone redrew Home")
        XCTAssertFalse(IndexSummaries.changed(nil, nil))
        XCTAssertTrue(IndexSummaries.changed(nil, a))
        XCTAssertTrue(IndexSummaries.changed(a, nil))
        var never = a
        never.refreshed = nil
        XCTAssertTrue(IndexSummaries.changed(never, a), "the first refresh that worked is news")
        var more = later
        more.files = 4
        XCTAssertTrue(IndexSummaries.changed(a, more))
        var offline = later
        offline.offline = true
        XCTAssertTrue(IndexSummaries.changed(a, offline))
        var newRelease = later
        newRelease.releases = [IndexSummaries.Summary.Release(name: "R4", url: key("R4"), added: t0)]
        XCTAssertTrue(IndexSummaries.changed(a, newRelease))
    }

    // MARK: Fix Match

    /// A show's OVA and its episodes follow one pin, so fixing either
    /// forgets what was kept for both.
    func testACachedEntryFollowsTheSamePinAsItsFile() {
        let names = ["Lab Show OVA - 02 (1080p).mkv", "Lab Show - 03 (1080p).mkv", "Lab.Show.S01E05.1080p.WEB-GRP.mkv",
                     "Dune (2021).mkv", "Dune (1984).mkv", "Lab Show Movie 02 - The Film.mkv"]
        for n in names {
            let p = TitleParser.parse(n)
            XCTAssertEqual(MetadataService.pinKey(cacheKey: MetadataService.cacheKey(p)), MetadataService.pinKey(p), n)
        }
        let ova = MetadataService.pinKey(cacheKey: MetadataService.cacheKey(TitleParser.parse(names[0])))
        let episode = MetadataService.pinKey(cacheKey: MetadataService.cacheKey(TitleParser.parse(names[1])))
        XCTAssertEqual(ova, episode, "the OVA's entry and the episode's follow different pins")
        XCTAssertNotEqual(MetadataService.pinKey(cacheKey: MetadataService.cacheKey(TitleParser.parse(names[3]))),
                          MetadataService.pinKey(cacheKey: MetadataService.cacheKey(TitleParser.parse(names[4]))))
    }

    // MARK: Watchlist

    private func item(_ id: String, _ name: String) -> WatchlistItem {
        WatchlistItem(meta: MetaItem(id: id, type: "series", name: name, poster: nil, description: nil, releaseInfo: nil, imdbRating: nil, genres: nil),
                      added: t0)
    }

    func testAWatchlistEntryMovesToItsIMDbID() throws {
        let list = [item("anilist:154587", "Frieren"), item("tt0903747", "Breaking Bad")]
        let m = try XCTUnwrap(WatchlistStore.migrating(list, from: "anilist:154587", to: "tt22248376"))
        XCTAssertEqual(m.items.map(\.id), ["tt22248376", "tt0903747"], "the entry keeps its place")
        XCTAssertEqual(m.items[0].altID, "anilist:154587")
        XCTAssertEqual(m.moved?.id, "tt22248376")
        XCTAssertEqual(WatchlistStore.allIDs(m.items), ["tt22248376", "anilist:154587", "tt0903747"],
                       "a tile with the old id doesn't find it")

        XCTAssertNil(WatchlistStore.migrating(list, from: "tmdb:1", to: "tt1"), "nothing saved under that id")
        XCTAssertNil(WatchlistStore.migrating(list, from: "anilist:154587", to: "anilist:154587"))
        XCTAssertNil(WatchlistStore.migrating(list, from: "anilist:154587", to: "tmdb:2"), "not an IMDb id")
    }

    /// Saved under both ids (the duplicate): one entry, the IMDb one.
    func testAWatchlistTitleSavedTwiceIsKeptOnce() throws {
        let list = [item("tt22248376", "Frieren"), item("anilist:154587", "Frieren")]
        let m = try XCTUnwrap(WatchlistStore.migrating(list, from: "anilist:154587", to: "tt22248376"))
        XCTAssertEqual(m.items.map(\.id), ["tt22248376"])
        XCTAssertEqual(m.items[0].altID, "anilist:154587")
        XCTAssertNil(m.moved, "already on the sync services under its IMDb id")
    }

    func testTheOldIDIsSavedWithTheEntry() throws {
        var saved = item("tt22248376", "Frieren")
        saved.altID = "anilist:154587"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(WatchlistItem.self, from: enc.encode(saved)).altID, "anilist:154587")
        // Saved before 1.30.4: no altID.
        let old = Data(#"{"id":"tt1","type":"movie","name":"A","added":"2026-11-01T00:00:00Z"}"#.utf8)
        XCTAssertNil(try dec.decode(WatchlistItem.self, from: old).altID)
    }

    // MARK: Servers

    func testAServerThatIsDownIsNotYoureOffline() {
        let down = URLError(.cannotConnectToHost)
        let online = ServerError.message(down, server: "NAS", online: true)
        XCTAssertFalse(online.offline)
        XCTAssertTrue(online.text.hasPrefix("Couldn't reach NAS"), online.text)

        let offline = ServerError.message(down, server: "NAS", online: false)
        XCTAssertTrue(offline.offline)
        XCTAssertTrue(offline.text.hasPrefix("You're offline"), offline.text)

        XCTAssertTrue(ServerError.message(down, server: "NAS", online: nil).offline, "not known yet: as before")

        let smb = ServerError.message(SMBError.unreachable, server: "NAS", online: true)
        XCTAssertFalse(smb.offline)
        XCTAssertTrue(smb.text.hasPrefix("Couldn't reach NAS"), smb.text)
        XCTAssertTrue(ServerError.message(SMBError.timedOut, server: "NAS", online: false).offline)

        let refused = ServerError.message(ServerError.unauthorized, server: "NAS", online: false)
        XCTAssertFalse(refused.offline)
        XCTAssertEqual(refused.text, ServerError.unauthorized.localizedDescription)
    }

    /// A picture is kept on disk under its address without the login.
    func testAServerPictureIsKeptWithoutItsToken() throws {
        var r = URLRequest(url: URL(string: "https://plex.example.invalid:32400/photo/:/transcode?width=80&height=120&url=%2Flibrary%2Fmetadata%2F1%2Fthumb%2F2&X-Plex-Token=secret")!)
        r.setValue("secret", forHTTPHeaderField: "X-Plex-Token")
        let key = try XCTUnwrap(ServerHTTP.artKey(r))
        let address = try XCTUnwrap(key.url?.absoluteString)
        XCTAssertFalse(address.contains("secret"), address)
        XCTAssertTrue(address.contains("width=80"), address)
        XCTAssertTrue(address.contains("thumb"), address)
        XCTAssertNil(key.value(forHTTPHeaderField: "X-Plex-Token"))
        XCTAssertTrue((key.allHTTPHeaderFields ?? [:]).isEmpty)

        let jellyfin = URLRequest(url: URL(string: "https://jf.example.invalid/Items/abc/Images/Primary?maxHeight=360&tag=t1&api_key=secret")!)
        XCTAssertFalse(try XCTUnwrap(ServerHTTP.artKey(jellyfin)?.url?.absoluteString).contains("secret"))

        var post = r
        post.httpMethod = "POST"
        XCTAssertNil(ServerHTTP.artKey(post), "only GETs are kept")
    }

    /// An SMB call: given up while it waits, it isn't started; once started,
    /// only its own deadline or its answer ends it, once.
    func testAnSMBCallEndsOnce() {
        let waiting = SMBCall()
        XCTAssertTrue(waiting.end(onlyIfWaiting: true), "the wait's deadline")
        XCTAssertFalse(waiting.start(), "a call given up was started when its turn came")
        XCTAssertTrue(waiting.ended)

        let working = SMBCall()
        XCTAssertTrue(working.start())
        XCTAssertFalse(working.ended)
        XCTAssertFalse(working.end(onlyIfWaiting: true), "the wait's deadline ended a call already working")
        XCTAssertTrue(working.end(), "its own deadline, or its answer")
        XCTAssertFalse(working.end(), "answered twice")
        XCTAssertTrue(working.ended)
    }
}
