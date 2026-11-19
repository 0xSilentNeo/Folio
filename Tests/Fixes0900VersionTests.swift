import SwiftUI
import XCTest
@testable import Folio

/// 0.90.0: the version numbers start again (after 1.30.6 comes 0.90.0, then
/// 0.90.1, 0.91.0 … and 1.0.0), What's New starts empty, the library
/// index's folders no longer come due together, and the traces cost less a line.
final class Fixes0900VersionTests: XCTestCase {
    private typealias Entry = Announcements.Entry

    private func defaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "folio.tests.0900." + name
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func pending(_ d: UserDefaults) -> [Entry] {
        d.data(forKey: "announcementsPending").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// What an install of 1.30.6 has saved: its version, two ids seen, an
    /// update banner and a piece of news waiting, and the feed's copy.
    private func used(_ d: UserDefaults, shown: String = "1.30.6") throws {
        d.set(shown, forKey: SettingsKey.whatsNewShown)
        d.set(["2026-11-14-update-1-30-3", "2026-11-15-update-1-30-4"], forKey: "announcementsSeen")
        d.set(true, forKey: "announcementsSeeded")
        let waiting = [Entry(id: "update-1-30-7", title: "Folio 1.30.7 is out", version: "1.30.7"), Entry(id: "news", title: "News")]
        d.set(try JSONEncoder().encode(waiting), forKey: "announcementsPending")
        d.set(Data("{}".utf8), forKey: "announcementsFeed")
        d.set("\"tag\"", forKey: "announcementsETag")
        d.set(1_800_000_000.0, forKey: "announcementsChecked")
    }

    // MARK: The reset, once

    func testAFreshInstallKeepsNothingButTheFlag() throws {
        let d = try defaults()
        XCTAssertTrue(WhatsNew.resetVersionLine(current: "0.90.0", defaults: d))
        XCTAssertNil(d.string(forKey: SettingsKey.whatsNewShown), "left for the first launch's own rule: nothing shown, the version remembered")
        XCTAssertNil(d.object(forKey: "announcementsSeen"))
        XCTAssertNil(d.object(forKey: "announcementsPending"))
        XCTAssertTrue(d.bool(forKey: SettingsKey.versionLineReset))
        XCTAssertEqual(Set(d.persistentDomain(forName: "folio.tests.0900." + #function)?.keys.map { $0 } ?? []), [SettingsKey.versionLineReset])
        // And the launch itself, as before.
        XCTAssertEqual(WhatsNew.decide(current: "0.90.0", lastShown: nil, existingInstall: false, hasEntries: false),
                       WhatsNew.Decision(show: false, remember: "0.90.0"))
    }

    func testFrom1306To0900() throws {
        let d = try defaults()
        try used(d)
        XCTAssertTrue(WhatsNew.resetVersionLine(current: "0.90.0", defaults: d))
        XCTAssertNil(d.string(forKey: SettingsKey.whatsNewShown))
        // The launch: 0.90.0 has no list, so nothing is shown and it's remembered.
        XCTAssertEqual(WhatsNew.decide(current: "0.90.0", lastShown: nil, existingInstall: true, hasEntries: false),
                       WhatsNew.Decision(show: false, remember: "0.90.0"))
        // Straight from 1.30.6 to a 0.9x with a list: that list is shown.
        XCTAssertEqual(WhatsNew.decide(current: "0.90.1", lastShown: nil, existingInstall: true, hasEntries: true),
                       WhatsNew.Decision(show: true, remember: "0.90.1"))
        // The next version with a list is an update, shown once.
        XCTAssertEqual(WhatsNew.decide(current: "0.90.1", lastShown: "0.90.0", existingInstall: true, hasEntries: true),
                       WhatsNew.Decision(show: true, remember: "0.90.1"))
        // The 1.30.7 banner is gone and won't come back from the feed; the news waits on.
        XCTAssertEqual(pending(d).map(\.id), ["news"])
        XCTAssertEqual(d.stringArray(forKey: "announcementsSeen"), ["2026-11-14-update-1-30-3", "2026-11-15-update-1-30-4", "update-1-30-7"])
        XCTAssertTrue(d.bool(forKey: "announcementsSeeded"), "not a first look again")
        for k in ["announcementsFeed", "announcementsETag", "announcementsChecked"] { XCTAssertNil(d.object(forKey: k), k) }
    }

    /// Straight from 1.30.6 to 1.0.0 or 1.2.0, when those numbers come
    /// round again: the same flag, whatever the two versions are.
    func testFrom1306To100AndLater() throws {
        for current in ["1.0.0", "1.2.0", "1.30.6", "1.31.0"] {
            let d = try defaults("jump." + current)
            try used(d)
            XCTAssertTrue(WhatsNew.resetVersionLine(current: current, defaults: d), current)
            XCTAssertNil(d.string(forKey: SettingsKey.whatsNewShown), current)
            XCTAssertEqual(WhatsNew.decide(current: current, lastShown: nil, existingInstall: true, hasEntries: true).show, true, current)
            XCTAssertEqual(pending(d).map(\.id), ["news"], current)
        }
        // Without the step, 1.0.0 after 1.30.6 was "an older version
        // installed again" and 1.30.7's banner stayed up.
        XCTAssertFalse(WhatsNew.newer("1.0.0", than: "1.30.6"))
        XCTAssertTrue(Announcements.relevant(Entry(id: "u", title: "u", version: "1.30.7"), appVersion: "1.0.0"))
    }

    func testRunTwice() throws {
        let d = try defaults()
        try used(d)
        XCTAssertTrue(WhatsNew.resetVersionLine(current: "0.90.0", defaults: d))
        XCTAssertFalse(WhatsNew.resetVersionLine(current: "0.90.0", defaults: d))
        // What 0.90.x keeps afterwards isn't touched by a later launch.
        d.set("0.90.1", forKey: SettingsKey.whatsNewShown)
        let later = [Entry(id: "update-0-91-0", title: "Folio 0.91.0 is out", version: "0.91.0")]
        d.set(try JSONEncoder().encode(later), forKey: "announcementsPending")
        d.set(5.0, forKey: "announcementsChecked")
        XCTAssertFalse(WhatsNew.resetVersionLine(current: "0.91.0", defaults: d))
        XCTAssertEqual(d.string(forKey: SettingsKey.whatsNewShown), "0.90.1")
        XCTAssertEqual(pending(d).map(\.id), ["update-0-91-0"])
        XCTAssertEqual(d.double(forKey: "announcementsChecked"), 5)
    }

    /// 1.30.3's single banner (before the list of them) goes as well.
    func testTheOldSingleBannerGoes() throws {
        let d = try defaults()
        d.set("1.30.3", forKey: SettingsKey.whatsNewShown)
        d.set(try JSONEncoder().encode(Entry(id: "u4", title: "Folio 1.30.4 is out", version: "1.30.4")), forKey: "announcementsCurrent")
        WhatsNew.resetVersionLine(current: "0.90.0", defaults: d)
        XCTAssertNil(d.object(forKey: "announcementsCurrent"))
        XCTAssertNil(d.object(forKey: "announcementsPending"))
        XCTAssertEqual(d.stringArray(forKey: "announcementsSeen"), ["u4"])
    }

    // MARK: What's New with no entries

    func testAnEmptyListShowsNothingAnywhere() {
        XCTAssertTrue(WhatsNew.releases.isEmpty, "0.90.0 starts with none; when a version adds entries this test goes")
        XCTAssertTrue(WhatsNew.releases(after: "1.30.6", upTo: "0.90.0").isEmpty)
        XCTAssertTrue(WhatsNew.releases(after: nil, upTo: "0.90.0").isEmpty)
        XCTAssertNil(WhatsNew.release("0.90.0"))
        // An update with nothing to list: remembered, not shown.
        XCTAssertEqual(WhatsNew.decide(current: "0.90.0", lastShown: "1.30.6", existingInstall: true, hasEntries: false),
                       WhatsNew.Decision(show: false, remember: "0.90.0"))
        XCTAssertEqual(WhatsNew.decide(current: "0.90.0", lastShown: nil, existingInstall: true, hasEntries: false),
                       WhatsNew.Decision(show: false, remember: "0.90.0"))
    }

    /// The sheet from Settings → About, and after an update, with no
    /// entries: laid out without a crash.
    @MainActor
    func testTheSheetWithNoEntriesLaysOut() {
        for sheet in [WhatsNewSheet(all: true), WhatsNewSheet(version: "0.90.0", since: "1.30.6"), WhatsNewSheet(version: "0.90.0")] {
            let host = UIHostingController(rootView: sheet)
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 390, height: 844)).height, 0)
        }
    }

    // MARK: Versions as numbers

    func testVersionsCompareAsNumbers() {
        // Ascending, each after the one before.
        let order = ["0.9.0", "0.90.0", "0.90.1", "0.90.10", "0.91.0", "0.100.0", "1.0.0", "1.0.1", "1.2.0", "1.30.6", "2.0.0"]
        for (i, a) in order.enumerated() {
            for (j, b) in order.enumerated() {
                let want: ComparisonResult = i < j ? .orderedAscending : i > j ? .orderedDescending : .orderedSame
                XCTAssertEqual(Announcements.compare(a, b), want, "\(a) and \(b)")
                XCTAssertEqual(WhatsNew.newer(a, than: b), i > j, "\(a) after \(b)")
            }
        }
        XCTAssertEqual(Announcements.compare("0.90", "0.90.0"), .orderedSame)
        XCTAssertEqual(Announcements.compare("v1.0.0", "0.99.9"), .orderedDescending)
    }

    func testUpdateAnnouncementsAfterTheReset() {
        func update(_ v: String) -> Entry { Entry(id: "update-" + v, title: "Folio \(v) is out", version: v) }
        // 0.90.1 is told to 0.90.0, 1.0.0 to every 0.9x, and none to itself.
        XCTAssertEqual(Announcements.select([update("0.90.1")], seen: [], firstRun: false, appVersion: "0.90.0").show.map(\.id), ["update-0.90.1"])
        for v in ["0.90.0", "0.99.9", "0.100.0"] {
            XCTAssertEqual(Announcements.select([update("1.0.0")], seen: [], firstRun: true, appVersion: v).show.map(\.id), ["update-1.0.0"], v)
        }
        XCTAssertTrue(Announcements.select([update("0.90.0")], seen: [], firstRun: false, appVersion: "0.90.0").show.isEmpty)
        XCTAssertTrue(Announcements.select([update("0.9.0")], seen: [], firstRun: false, appVersion: "0.90.0").show.isEmpty, "0.9.0 is before 0.90.0")
        // The newest of several, by number.
        XCTAssertEqual(Announcements.select([update("0.90.9"), update("0.100.0"), update("0.91.0")], seen: [], firstRun: false, appVersion: "0.90.0").show.map(\.id),
                       ["update-0.100.0"])
        XCTAssertEqual(Announcements.queued([update("0.90.1")], adding: [update("1.0.0")], appVersion: "0.90.0").map(\.id), ["update-1.0.0"])
        // Why the feed's 1.30.x entries have to go: an install that never
        // saw them takes them for newer than 0.90.0.
        XCTAssertEqual(Announcements.select([update("1.30.4")], seen: [], firstRun: true, appVersion: "0.90.0").show.count, 1)
        // 0.90.0 told to 1.30.x: as news for those versions only, since an
        // entry with `version` 0.90.0 isn't newer than theirs.
        XCTAssertTrue(Announcements.select([update("0.90.0")], seen: [], firstRun: false, appVersion: "1.30.6").show.isEmpty)
        let move = Entry(id: "move", title: "Folio is now 0.90.0", minVersion: "1.30.3", maxVersion: "1.30.6")
        XCTAssertEqual(Announcements.select([move], seen: [], firstRun: false, appVersion: "1.30.6").show.map(\.id), ["move"])
        XCTAssertTrue(Announcements.select([move], seen: [], firstRun: false, appVersion: "0.90.0").show.isEmpty)
        XCTAssertTrue(Announcements.select([move], seen: [], firstRun: false, appVersion: "1.0.0").show.isEmpty)
    }

    // MARK: The library index's 24 hours

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var tree: [String: [DAVItem]] = [:]
        private var _asked: [String] = []
        var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }
        func set(_ folder: URL, _ items: [DAVItem]) { lock.lock(); tree[LibraryIndex.key(folder)] = items; lock.unlock() }
        func reset() { lock.lock(); _asked = []; lock.unlock() }
        func list(_ url: URL) throws -> [DAVItem] {
            lock.lock(); defer { lock.unlock() }
            _asked.append(LibraryIndex.key(url))
            return tree[LibraryIndex.key(url)] ?? []
        }
    }

    private let root = URL(string: "https://dav.example.invalid/torrents/")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func url(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    private func key(_ name: String) -> String { LibraryIndex.key(url(name)) }
    private func folderItem(_ name: String, modified: TimeInterval = 100) -> DAVItem {
        DAVItem(url: url(name), name: name, isDirectory: true, size: nil, modified: Date(timeIntervalSince1970: modified), contentType: nil)
    }
    private func fileItem(_ folder: String, _ name: String) -> DAVItem {
        DAVItem(url: url(folder).appendingPathComponent(name), name: name, isDirectory: false, size: 1_000_000, modified: Date(timeIntervalSince1970: 1), contentType: nil)
    }
    private func indexer(_ s: Server) -> LibraryIndexer { LibraryIndexer(list: { try s.list($0) }) }

    /// `count` releases, an episode each.
    private func server(_ count: Int) -> (Server, [String]) {
        let s = Server()
        let names = (0..<count).map { String(format: "R%03d", $0) }
        s.set(root, names.map { folderItem($0) })
        for n in names { s.set(url(n), [fileItem(n, "\(n).S01E01.1080p.mkv")]) }
        return (s, names)
    }

    func testEachFolderHasItsOwnAgeLimit() {
        let day: TimeInterval = 24 * 3600
        let limits = (0..<104).map { LibraryIndexer.ageLimit(key(String(format: "R%03d", $0)), maxAge: day) }
        for l in limits {
            XCTAssertGreaterThanOrEqual(l, 18 * 3600)
            XCTAssertLessThanOrEqual(l, day, "never later than the 24 hours before")
        }
        XCTAssertEqual(LibraryIndexer.ageLimit(key("R001"), maxAge: day), LibraryIndexer.ageLimit(key("R001"), maxAge: day), "the same each time")
        XCTAssertGreaterThan(Set(limits.map { Int($0 / 600) }).count, 20, "spread over the six hours, not one moment")
        // No hour of the six takes the lot.
        let perHour = Dictionary(grouping: limits) { Int(($0 - 18 * 3600) / 3600) }.mapValues(\.count)
        XCTAssertLessThan(perHour.values.max() ?? 0, 40)
    }

    /// The user's log: 104 folders listed together, and again a day later.
    func testACohortIsListedAFewAtATime() async {
        let (s, names) = server(104)
        let (first, built) = await indexer(s).refresh(LibraryIndex(account: "test", root: LibraryIndex.key(root)), rootURL: root, full: true, now: t0)
        XCTAssertEqual(built.listed, 105)
        let share = LibraryIndexer.turnShare(names.count)
        XCTAssertEqual(share, 12)

        // A day and a half on, every listing is past its limit.
        var now = t0.addingTimeInterval(36 * 3600)
        XCTAssertEqual(LibraryIndexer.staleFolders(first, root: first.root, now: now, maxAge: 24 * 3600).count, 2 * share)
        s.reset()
        var (index, report) = await indexer(s).refresh(first, rootURL: root, full: false, now: now)
        XCTAssertEqual(report.listed, 1 + 2 * share, "the start folder and twice the turn share, not all 104")
        XCTAssertEqual(report.kept, 104 - 2 * share)
        XCTAssertEqual(index.folders.count, 105, "those waiting keep what was saved")

        // Home's quick check in between lists the start folder only.
        s.reset()
        _ = await indexer(s).refresh(index, rootURL: root, full: false, turns: false, now: now.addingTimeInterval(60))
        XCTAssertEqual(s.asked, [LibraryIndex.key(root)])

        // The refreshes after it, ten minutes apart, take the rest: none twice.
        var listed = Set(index.folders.filter { $0.value.listed == now }.keys)
        var rounds = 1
        while listed.count < 105, rounds < 10 {
            now = now.addingTimeInterval(600)
            s.reset()
            (index, report) = await indexer(s).refresh(index, rootURL: root, full: false, now: now)
            XCTAssertLessThanOrEqual(report.listed, 1 + 2 * share)
            let again = Set(s.asked).subtracting([LibraryIndex.key(root)])
            XCTAssertTrue(again.isDisjoint(with: listed.subtracting([LibraryIndex.key(root)])), "oldest first: none listed twice before all were")
            listed.formUnion(again)
            rounds += 1
        }
        XCTAssertEqual(listed.count, 105)
        XCTAssertEqual(rounds, 5, "104 folders, 24 a refresh")

        // The next day, opened once: no refresh lists them all, whatever the hour.
        for hours in [19.0, 21, 23, 24, 25, 30, 48] {
            s.reset()
            let (_, r) = await indexer(s).refresh(index, rootURL: root, full: false, now: now.addingTimeInterval(hours * 3600))
            XCTAssertLessThanOrEqual(r.listed, 1 + 2 * share, "\(hours) h")
            XCTAssertGreaterThan(r.listed, 1, "\(hours) h: some are due")
        }
    }

    /// Left alone, the folders of one moment come due over six hours.
    func testACohortDriftsApart() async {
        let (s, _) = server(104)
        let (first, _) = await indexer(s).refresh(LibraryIndex(account: "test", root: LibraryIndex.key(root)), rootURL: root, full: true, now: t0)
        func due(_ hours: Double) -> Int {
            let now = t0.addingTimeInterval(hours * 3600)
            return first.folders.filter { $0.key != first.root && now.timeIntervalSince($0.value.listed) > LibraryIndexer.ageLimit($0.key, maxAge: 24 * 3600) }.count
        }
        XCTAssertEqual(due(17.9), 0)
        XCTAssertGreaterThan(due(21), 20)
        XCTAssertLessThan(due(21), 84)
        XCTAssertEqual(due(24.1), 104)
    }

    func testAChangeTheStartFolderShowsIsListedAtOnce() async {
        let (s, names) = server(104)
        let (first, _) = await indexer(s).refresh(LibraryIndex(account: "test", root: LibraryIndex.key(root)), rootURL: root, full: true, now: t0)
        // Every folder past its age, 30 with a new date as well, and one new release.
        let changed = Array(names.suffix(30))
        s.set(root, names.map { folderItem($0, modified: changed.contains($0) ? 999 : 100) } + [folderItem("New")])
        s.set(url("New"), [fileItem("New", "New.2026.1080p.mkv")])
        let now = t0.addingTimeInterval(36 * 3600)
        s.reset()
        let (index, report) = await indexer(s).refresh(first, rootURL: root, full: false, now: now)
        let asked = Set(s.asked)
        for n in changed { XCTAssertTrue(asked.contains(key(n)), "\(n) changed: not held back by the cap") }
        XCTAssertTrue(asked.contains(key("New")))
        XCTAssertNotNil(index.folders[key("New")])
        XCTAssertLessThanOrEqual(report.listed, 1 + 31 + 2 * LibraryIndexer.turnShare(104))
        // The quick check too.
        s.set(root, names.map { folderItem($0, modified: $0 == "R000" ? 555 : (changed.contains($0) ? 999 : 100)) } + [folderItem("New")])
        s.reset()
        _ = await indexer(s).refresh(index, rootURL: root, full: false, turns: false, now: now.addingTimeInterval(60))
        XCTAssertEqual(Set(s.asked), [LibraryIndex.key(root), key("R000")])
    }

    /// A folder inside a release is listed with its release once past its own age.
    func testAFolderInsideAReleaseFollowsItsRelease() async {
        let s = Server()
        s.set(root, [folderItem("R")])
        s.set(url("R"), [fileItem("R", "R.S01E01.mkv"), folderItem("R/Subs")])
        s.set(url("R/Subs"), [])
        let (first, _) = await indexer(s).refresh(LibraryIndex(account: "test", root: LibraryIndex.key(root)), rootURL: root, full: true, now: t0)
        s.reset()
        _ = await indexer(s).refresh(first, rootURL: root, full: false, now: t0.addingTimeInterval(25 * 3600))
        XCTAssertEqual(Set(s.asked), [LibraryIndex.key(root), key("R"), key("R/Subs")])
        s.reset()
        _ = await indexer(s).refresh(first, rootURL: root, full: false, now: t0.addingTimeInterval(2 * 3600))
        XCTAssertEqual(Set(s.asked), [LibraryIndex.key(root), key("R")], "its turn; the folder inside isn't old yet")
    }

    func testTheTraceSaysHowManyNotEachName() {
        let names = (1...104).map { "Release.\($0)" }
        XCTAssertEqual(LibraryIndexer.listedLine(names, why: "older than 24 h"),
                       "list 104 folder(s) (older than 24 h): Release.1, Release.2, Release.3, Release.4, Release.5 and 99 more")
        XCTAssertEqual(LibraryIndexer.listedLine(["A", "B"], why: "new"), "list 2 folder(s) (new): A, B")
    }

    // MARK: The traces

    /// The switches are read from memory and follow the settings.
    func testTheTraceSwitchesFollowTheSettings() {
        let d = UserDefaults.standard
        let keys = [SettingsKey.libTrace, SettingsKey.netTrace, SettingsKey.pipTrace]
        let before = keys.map { d.object(forKey: $0) }
        defer {
            for (k, v) in zip(keys, before) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            TraceFlags.refresh()
        }
        for k in keys { d.set(false, forKey: k) }
        XCTAssertEqual([TraceFlags.lib, TraceFlags.net, TraceFlags.pip], [false, false, false])
        XCTAssertFalse(LibTrace.on)
        XCTAssertFalse(PiPTrace.on)
        d.set(true, forKey: SettingsKey.libTrace)
        XCTAssertTrue(LibTrace.on, "at once, on the thread that wrote it")
        XCTAssertEqual([TraceFlags.net, TraceFlags.pip], [false, false])
        d.set(true, forKey: SettingsKey.pipTrace)
        d.set(true, forKey: SettingsKey.netTrace)
        XCTAssertTrue(PiPTrace.on)
        XCTAssertTrue(TraceFlags.net)
        d.removeObject(forKey: SettingsKey.libTrace)
        XCTAssertFalse(LibTrace.on)
        // From another thread, as the library's metadata writes its settings.
        let done = expectation(description: "written off the main thread")
        DispatchQueue.global().async {
            d.set(true, forKey: SettingsKey.libTrace)
            XCTAssertTrue(LibTrace.on)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(LibTrace.on)
    }

    /// While the screen is recorded: no line per tile, no frame timing.
    @MainActor
    func testRecordingPausesThePerTileLines() {
        let d = UserDefaults.standard
        let before = d.object(forKey: SettingsKey.libTrace)
        defer {
            if let before { d.set(before, forKey: SettingsKey.libTrace) } else { d.removeObject(forKey: SettingsKey.libTrace) }
            TraceFlags.setCaptured(false)
        }
        d.set(true, forKey: SettingsKey.libTrace)
        TraceFlags.setCaptured(false)
        XCTAssertTrue(TraceFlags.perTile)
        TraceFlags.setCaptured(true)
        XCTAssertFalse(TraceFlags.perTile)
        XCTAssertTrue(LibTrace.on, "the trace itself stays on")
        // A setting changing doesn't lose the screen's state.
        d.set(false, forKey: SettingsKey.libTrace)
        XCTAssertTrue(TraceFlags.captured)
        XCTAssertFalse(TraceFlags.perTile)
    }

    /// Frames are timed for the trace they belong to.
    func testFrameTimingBelongsToOneTrace() {
        XCTAssertTrue(HitchProbe.wanted("tab", lib: true, pip: false))
        XCTAssertTrue(HitchProbe.wanted("search", lib: true, pip: false))
        XCTAssertFalse(HitchProbe.wanted("ui", lib: true, pip: false), "the player's buttons aren't the library trace's")
        XCTAssertTrue(HitchProbe.wanted("ui", lib: false, pip: true))
        XCTAssertFalse(HitchProbe.wanted("tab", lib: false, pip: true))
        XCTAssertFalse(HitchProbe.wanted("tab", lib: false, pip: false))
    }

    /// A scroll is one line once it rests, not a line a frame.
    @MainActor
    func testAScrollIsOneLine() async throws {
        let d = UserDefaults.standard
        let before = d.object(forKey: SettingsKey.libTrace)
        defer { if let before { d.set(before, forKey: SettingsKey.libTrace) } else { d.removeObject(forKey: SettingsKey.libTrace) } }
        d.set(true, forKey: SettingsKey.libTrace)
        let label = "test scroll \(UUID().uuidString.prefix(8))"
        for i in 0..<50 { LibTrace.scrolled(label, from: i * 10, to: (i + 1) * 10) }
        try await Task.sleep(for: .milliseconds(800))
        Diagnostics.shared.flush()
        let log = (try? String(contentsOf: Diagnostics.shared.appLog, encoding: .utf8)) ?? ""
        let lines = log.split(separator: "\n").filter { $0.contains(label) }
        XCTAssertEqual(lines.count, 1, "one line for the whole scroll")
        XCTAssertTrue(lines.first?.contains("[panel] \(label) offset 0 → 500 (50 steps in ") == true, String(lines.first ?? ""))
    }
}
