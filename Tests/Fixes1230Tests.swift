import XCTest
@testable import Folio

/// 1.23.0: the 5 Nov requests (search, Real-Debrid's removed files, widgets
/// without an App Group) and the code review's fixes.
@MainActor
final class Fixes1230Tests: XCTestCase {

    // MARK: The log filter (review, 5 Nov)

    private func hidden(_ s: String, _ secret: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = Diagnostics.redact(s)
        XCTAssertFalse(r.contains(secret), "“\(secret)” is still in: \(r)", file: file, line: line)
    }

    func testTokensAndEncodedLinksAreHidden() {
        hidden(#"Run command: change-list, flags=64, name="http-header-fields", operation="append", value="X-Emby-Token: 9f8e7d6c5b4a39281706f5e4d3c2b1a0"]"#, "9f8e7d6c5b4a39281706f5e4d3c2b1a0")
        hidden("https://h.example/stream?X-Plex-Token=xQ7rT2bN9kLmP4sV8wZ1&x=1", "xQ7rT2bN9kLmP4sV8wZ1")
        hidden(#"Authorization: MediaBrowser Client="Folio", Device="iPhone", Token="9f8e7d6c5b4a39281706f5e4d3c2b1a0""#, "9f8e7d6c5b4a39281706f5e4d3c2b1a0")
        hidden("onOpenURL folio://addon?url=https%3A%2F%2Ftorrentio.strem.fun%2Fsort%3Dsize%7Crealdebrid%3DABCDEFGHIJKLMNOPQRSTUVWXYZ012345%2Fmanifest.json", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
        hidden("folio://play?url=https%3A%2F%2Fbob%3Ahunter2%40dav.example.com%2Ff.mkv", "hunter2")
        hidden("authorization=Basic%20Ym9iOmh1bnRlcjI%3D", "Ym9iOmh1bnRlcjI")
        hidden(#"{"api_key":"0123456789abcdef0123456789abcdef"}"#, "0123456789abcdef")
        hidden(#"password="hunter2""#, "hunter2")
        hidden("password = hunter2", "hunter2")
    }

    func testOrdinaryWordsStay() {
        XCTAssertEqual(Diagnostics.redact("monkey=banana bypass=yes hotkey=space"), "monkey=banana bypass=yes hotkey=space")
        // A JSON key keeps its quotes.
        XCTAssertEqual(Diagnostics.redact(#"{"apiKey":"abc123"}"#), #"{"apiKey":"••••"}"#)
    }

    func testALogIsCutAtALine() {
        let log = "Authorization: Basic Ym9iOmh1bnRlcjI=\nline two\nline three"
        let t = Diagnostics.tail(log, limit: 25)
        XCTAssertEqual(t, "line two\nline three")             // from the first whole line after the cut
        XCTAssertEqual(Diagnostics.tail("short", limit: 100), "short")
    }

    // MARK: Crash: a subtitle language of "-"

    func testADashIsNoLanguage() {
        XCTAssertNil(TrackMatch.language("-"))
        XCTAssertNil(TrackMatch.language("--"))
        XCTAssertNil(TrackMatch.language("_"))
        XCTAssertEqual(TrackMatch.language("en-US"), "en")
    }

    // MARK: Kids profile

    func testARatingFolioCantReadIsNotGuessedFromGenres() {
        let limits = KidsRules.Limits(film: .pg, show: .tvPG)
        // An R-18 animated comedy: once "all ages" from its genres.
        XCTAssertEqual(KidsRules.verdict(rating: "R-18", genres: ["Animation", "Comedy"], isSeries: true, limits: limits), .above("R-18"))
        XCTAssertNotEqual(KidsRules.verdict(rating: "M18", genres: ["Animation"], isSeries: false, limits: limits), .allowed)
        // Something Folio doesn't know at all: hidden, not guessed.
        XCTAssertEqual(KidsRules.verdict(rating: "ZZ9", genres: ["Family"], isSeries: false, limits: limits), .unknown)
        // No rating, or "Not Rated": the genres still decide.
        XCTAssertEqual(KidsRules.verdict(rating: nil, genres: ["Family"], isSeries: false, limits: limits), .allowed)
        XCTAssertEqual(KidsRules.verdict(rating: "Not Rated", genres: ["Family"], isSeries: false, limits: limits), .allowed)
    }

    // MARK: What a server answered

    func testProblemsSaidPlainly() {
        let gone = ServerProblem.classify(status: 404, error: nil, server: "Real-Debrid", realDebrid: true)
        XCTAssertEqual(gone.kind, .gone)
        XCTAssertEqual(gone.title, "Real-Debrid removed this file")
        XCTAssertFalse(gone.retryable)
        XCTAssertEqual(ServerProblem.classify(status: 404, error: nil, server: "Real-Debrid", realDebrid: true, folder: true).title,
                       "Real-Debrid removed this release")
        XCTAssertEqual(ServerProblem.classify(status: 410, error: nil, server: "NAS", realDebrid: false).title, "This file isn't on NAS any more")
        XCTAssertEqual(ServerProblem.classify(status: 401, error: nil, server: "NAS", realDebrid: false).kind, .refused)
        XCTAssertEqual(ServerProblem.classify(status: 503, error: nil, server: "NAS", realDebrid: false).kind, .serverError(503))
        XCTAssertEqual(ServerProblem.classify(status: 206, error: nil, server: "NAS", realDebrid: false).kind, .fileItself)
        XCTAssertEqual(ServerProblem.classify(status: nil, error: URLError(.notConnectedToInternet), server: "NAS", realDebrid: false).kind, .offline)
        XCTAssertEqual(ServerProblem.classify(status: nil, error: URLError(.timedOut), server: "NAS", realDebrid: false).kind, .unreachable)
        XCTAssertEqual(ServerProblem.classify(status: nil, error: WebDAVError.http(404), server: "Real-Debrid", realDebrid: true, folder: true).kind, .gone)
        XCTAssertEqual(ServerProblem.classify(status: nil, error: WebDAVError.unauthorized, server: "NAS", realDebrid: false).kind, .refused)
    }

    // MARK: Search: posters for the files found

    func testFilesFoundMakeOnePosterPerRelease() {
        let server = WebDAVServer(name: "Real-Debrid", baseURL: "https://dav.real-debrid.com/", username: "u")
        let root = WebDAVClient(server: server).url(forPath: server.rootPath)!
        let a = root.appendingPathComponent("MobLand.S01.1080p.Blu-ray.Remux-SiCFoI", isDirectory: true)
        func file(_ dir: URL, _ name: String) -> ServerFile {
            ServerFile(server: server, file: LibraryIndex.File(url: dir.appendingPathComponent(name), name: name, size: 1, added: nil))
        }
        let files = [file(a, "MobLand.S01E01.mkv"), file(a, "MobLand.S01E02.mkv"), file(root, "Conclave.2024.1080p.WEB-DL.mkv")]
        let releases = ServerFile.releases(files)
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases[0].count, 2)
        XCTAssertEqual(releases[0].name.title, "MobLand")
        XCTAssertNotNil(releases[0].folder)
        XCTAssertNil(releases[1].folder)                              // a file at the top plays
        XCTAssertEqual(releases[1].name.title, "Conclave")
        // The server pill opens the folder the file is in, or the server's library.
        if case .webdavFolder(_, let address, let name) = files[0].folderRoute {
            XCTAssertEqual(name, "MobLand.S01.1080p.Blu-ray.Remux-SiCFoI")
            XCTAssertTrue(address.hasSuffix("MobLand.S01.1080p.Blu-ray.Remux-SiCFoI/"), address)
        } else { XCTFail("not a folder: \(files[0].folderRoute)") }
        if case .webdav = files[2].folderRoute {} else { XCTFail("not the library: \(files[2].folderRoute)") }
    }

    func testSearchWords() {
        XCTAssertEqual(LibrarySearchText.words("  Mob Land "), ["mob", "land"])
        XCTAssertEqual(LibrarySearchText.words("m"), [])
    }

    // MARK: Widgets

    func testTheWidgetStoreInAFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WidgetStore.folder(dir)
        let snap = ContinueSnapshot(items: [.init(id: "a", title: "T", line: nil, progress: 0.5, remaining: 60)])
        try snap.write(to: store)
        XCTAssertEqual(ContinueSnapshot.read(from: store as WidgetStore?), snap)
        try store.write(Data([1, 2, 3]), "a-1.jpg")
        XCTAssertTrue(store.exists("a-1.jpg"))
        ContinueSnapshotWriter.sweep(store, keeping: [])
        XCTAssertFalse(store.exists("a-1.jpg"))
        XCTAssertTrue(store.exists("continue.json"))
    }

    func testTeamIDs() {
        XCTAssertTrue(KeychainShare.isTeam("ABCDE12345"))
        XCTAssertFalse(KeychainShare.isTeam("dev"))
        XCTAssertFalse(KeychainShare.isTeam("abcde12345"))
    }

    func testAiringEpisodeDays() {
        let e = AiringSnapshot.Episode(label: "S4 · E5", title: nil, airDate: Date(timeIntervalSince1970: 1_794_571_200), day: "2026-11-13")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let d = try? XCTUnwrap(e.localDay(cal))
        XCTAssertEqual(d.map { cal.component(.day, from: $0) }, 13)
        // Midnights are in the widget's timeline, so "Tomorrow" turns into "Today".
        let now = Date(timeIntervalSince1970: 1_793_851_200)       // 5 Nov, 3 PM in Melbourne
        let snap = AiringSnapshot(items: [.init(id: "t", name: "Tulsa King", network: nil, episodes: [e])])
        let dates = snap.timelineDates(from: now, calendar: cal)
        XCTAssertTrue(dates.contains(cal.startOfDay(for: now.addingTimeInterval(86400))))
    }

    func testDayOnlyEpisodesAreAnnouncedInTheMorning() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        var s = TrackedShow(id: "tt16358384", name: "Tulsa King")
        s.next = AiringEpisode(season: 4, number: 5, airDate: Date(timeIntervalSince1970: 1_794_571_200), day: "2026-11-13")
        let now = Date(timeIntervalSince1970: 1_793_851_200)
        let plan = AiringNotifications.plan([s], now: now, mode: .air, calendar: cal)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.title, "Tulsa King S4 · E5 comes out today")
        XCTAssertEqual(plan.first.map { cal.component(.hour, from: $0.fire) }, 9)
        XCTAssertEqual(plan.first.map { cal.component(.day, from: $0.fire) }, 13)
    }
}
