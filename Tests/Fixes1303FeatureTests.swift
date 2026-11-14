import XCTest
@testable import Folio

/// 1.30.3: News from Folio (the feed's reading and which entries are shown)
/// and the traces' "Keep on until I turn them off".
final class Fixes1303FeatureTests: XCTestCase {
    private typealias Entry = Announcements.Entry

    // MARK: Versions

    func testVersionsCompareAsNumbers() {
        XCTAssertEqual(Announcements.compare("1.30.3", "1.30.3"), .orderedSame)
        XCTAssertEqual(Announcements.compare("1.30.10", "1.30.9"), .orderedDescending)
        XCTAssertEqual(Announcements.compare("1.9.9", "1.30.0"), .orderedAscending)
        XCTAssertEqual(Announcements.compare("1.30", "1.30.0"), .orderedSame, "a missing part is 0")
        XCTAssertEqual(Announcements.compare("1.30", "1.30.1"), .orderedAscending)
        XCTAssertEqual(Announcements.compare("2", "1.99.99"), .orderedDescending)
        XCTAssertEqual(Announcements.compare("v1.30.3", "1.30.3"), .orderedSame, "a tag's v")
        XCTAssertEqual(Announcements.compare("1.30.3-beta", "1.30.3"), .orderedSame, "a suffix doesn't count")
        XCTAssertEqual(Announcements.compare("", "0.0"), .orderedSame)
        XCTAssertEqual(Announcements.compare("nonsense", "1.0"), .orderedAscending)
    }

    // MARK: The feed

    func testTheFeedIsReadLeniently() {
        let json = #"""
        {"schema": 3, "announcements": [
          {"id": "a", "title": "One", "body": "First.", "url": "https://github.com/0xSilentNeo/Folio", "date": "2026-11-14", "colour": "red"},
          {"title": "no id"},
          7,
          {"id": "", "title": "an empty id"},
          {"id": "b", "title": "Two", "body": 5, "version": 1.3, "minVersion": "1.30.0"},
          "text",
          {"id": "c", "title": "Three", "version": "1.30.3"}
        ]}
        """#
        let e = Announcements.parse(Data(json.utf8))
        XCTAssertEqual(e.map(\.id), ["a", "b", "c"], "a bad entry is skipped, the rest are kept")
        XCTAssertEqual(e[0], Entry(id: "a", title: "One", body: "First.", url: "https://github.com/0xSilentNeo/Folio", date: "2026-11-14"))
        XCTAssertEqual(e[1].body, "", "a field of another type is left out, not the entry")
        XCTAssertNil(e[1].version)
        XCTAssertEqual(e[1].minVersion, "1.30.0")
        XCTAssertEqual(e[2].version, "1.30.3")
    }

    func testWhatIsntAFeedIsEmpty() {
        XCTAssertTrue(Announcements.parse(Data()).isEmpty)
        XCTAssertTrue(Announcements.parse(Data("<html>404</html>".utf8)).isEmpty)
        XCTAssertTrue(Announcements.parse(Data("[1,2]".utf8)).isEmpty)
        XCTAssertTrue(Announcements.parse(Data(#"{"announcements": "soon"}"#.utf8)).isEmpty)
        XCTAssertTrue(Announcements.parse(Data(#"{"other": []}"#.utf8)).isEmpty)
    }

    /// The file in the repository is one this version reads.
    func testTheShippedEntry() {
        let json = #"{"announcements":[{"id":"2026-11-14-update-1-30-3","title":"Folio 1.30.3 is out","body":"Kids profile and Settings fixes, addon playlists and the stream picker, and a tidier search.","url":"https://github.com/0xSilentNeo/Folio/releases/tag/v1.30.3","version":"1.30.3","date":"2026-11-14"}]}"#
        let e = Announcements.parse(Data(json.utf8))
        XCTAssertEqual(e.count, 1)
        XCTAssertNotNil(Announcements.link(e.first?.url))
        // Told to 1.30.2, on its first look too; not to 1.30.3 itself.
        XCTAssertEqual(Announcements.select(e, seen: [], firstRun: true, appVersion: "1.30.2").show.map(\.id), ["2026-11-14-update-1-30-3"])
        let same = Announcements.select(e, seen: [], firstRun: false, appVersion: "1.30.3")
        XCTAssertTrue(same.show.isEmpty)
        XCTAssertEqual(same.markSeen, ["2026-11-14-update-1-30-3"])
    }

    // MARK: Which entries are shown

    private func news(_ id: String, _ date: String? = nil, min: String? = nil, max: String? = nil) -> Entry {
        Entry(id: id, title: id, body: "", minVersion: min, maxVersion: max, date: date)
    }
    private func update(_ version: String) -> Entry {
        Entry(id: "update-" + version, title: "Folio \(version) is out", version: version)
    }

    func testSeenEntriesArentShownAgain() {
        let s = Announcements.select([news("a", "2026-11-01"), news("b", "2026-11-02")], seen: ["a"], firstRun: false, appVersion: "1.30.3")
        XCTAssertEqual(s.show.map(\.id), ["b"])
        XCTAssertEqual(s.markSeen, ["b"])
        // The next look, with what was marked.
        let next = Announcements.select([news("a"), news("b")], seen: ["a", "b"], firstRun: false, appVersion: "1.30.3")
        XCTAssertEqual(next, Announcements.Selection(show: [], markSeen: []))
    }

    func testAnUpdateIsShownOnlyToAnOlderVersion() {
        let feed = [update("1.30.3")]
        XCTAssertEqual(Announcements.select(feed, seen: [], firstRun: false, appVersion: "1.30.2").show.map(\.id), ["update-1.30.3"])
        XCTAssertEqual(Announcements.select(feed, seen: [], firstRun: false, appVersion: "1.29.0").show.count, 1)
        for v in ["1.30.3", "1.30.4", "1.31.0", "2.0"] {
            let s = Announcements.select(feed, seen: [], firstRun: false, appVersion: v)
            XCTAssertTrue(s.show.isEmpty, v)
            XCTAssertEqual(s.markSeen, ["update-1.30.3"], "never newer than \(v): not looked at again")
        }
        // The app's version isn't known: nothing claimed, nothing marked.
        XCTAssertEqual(Announcements.select(feed, seen: [], firstRun: false, appVersion: ""), Announcements.Selection(show: [], markSeen: []))
    }

    func testOnlyTheNewestUpdateIsShown() {
        let s = Announcements.select([update("1.30.3"), update("1.31.0"), update("1.30.4"), update("1.30.1")], seen: [], firstRun: false, appVersion: "1.30.2")
        XCTAssertEqual(s.show.map(\.id), ["update-1.31.0"])
        XCTAssertEqual(Set(s.markSeen), ["update-1.30.3", "update-1.31.0", "update-1.30.4", "update-1.30.1"])
    }

    func testVersionRange() {
        let feed = [news("old", min: nil, max: "1.29.9"), news("new", min: "1.31.0"), news("mine", min: "1.30.0", max: "1.30.9"), news("exact", min: "1.30.3", max: "1.30.3")]
        let s = Announcements.select(feed, seen: [], firstRun: false, appVersion: "1.30.3")
        XCTAssertEqual(s.show.map(\.id), ["mine", "exact"])
        XCTAssertEqual(s.markSeen, ["mine", "exact"], "outside the range isn't marked: an update into it still shows it")
        XCTAssertEqual(Announcements.select(feed, seen: ["mine", "exact"], firstRun: false, appVersion: "1.31.0").show.map(\.id), ["new"])
    }

    func testTheFirstLookShowsOnlyANewerVersion() {
        let feed = [news("a", "2026-10-01"), news("b", "2026-11-01"), update("1.30.3"), update("1.30.0"), news("later", min: "1.31.0")]
        let first = Announcements.select(feed, seen: [], firstRun: true, appVersion: "1.30.2")
        XCTAssertEqual(first.show.map(\.id), ["update-1.30.3"])
        XCTAssertEqual(Set(first.markSeen), ["a", "b", "later", "update-1.30.0", "update-1.30.3"], "everything there at the first look is seen")
        // On the newest version: nothing at all.
        let quiet = Announcements.select(feed, seen: [], firstRun: true, appVersion: "1.30.3")
        XCTAssertTrue(quiet.show.isEmpty)
        XCTAssertEqual(Set(quiet.markSeen), Set(feed.map(\.id)))
        // What's added afterwards is shown.
        let next = Announcements.select(feed + [news("c", "2026-11-20")], seen: Set(quiet.markSeen), firstRun: false, appVersion: "1.30.3")
        XCTAssertEqual(next.show.map(\.id), ["c"])
    }

    func testAtMostTwoAtATimeNewestFirst() {
        let feed = [news("a", "2026-11-01"), news("b", "2026-11-03"), news("c", "2026-11-02"), news("d"), news("b", "2026-12-01")]
        let s = Announcements.select(feed, seen: [], firstRun: false, appVersion: "1.30.3")
        XCTAssertEqual(s.show.map(\.id), ["b", "c"])
        XCTAssertEqual(s.show.first?.date, "2026-11-03", "an id twice in the feed: the first")
        XCTAssertEqual(s.markSeen, ["b", "c"], "the rest wait for the next look")
        let next = Announcements.select(feed, seen: Set(s.markSeen), firstRun: false, appVersion: "1.30.3")
        XCTAssertEqual(next.show.map(\.id), ["a", "d"])
        // A new version comes first and counts as one of the two.
        let with = Announcements.select(feed + [update("1.30.4")], seen: [], firstRun: false, appVersion: "1.30.3")
        XCTAssertEqual(with.show.map(\.id), ["update-1.30.4", "b"])
        XCTAssertTrue(Announcements.select(feed, seen: [], firstRun: false, appVersion: "1.30.3", limit: 0).show.isEmpty)
    }

    /// A banner kept from before an update goes once the update is installed.
    func testRelevance() {
        XCTAssertTrue(Announcements.relevant(update("1.30.3"), appVersion: "1.30.2"))
        XCTAssertFalse(Announcements.relevant(update("1.30.3"), appVersion: "1.30.3"))
        XCTAssertTrue(Announcements.relevant(news("a"), appVersion: "1.30.3"))
        XCTAssertFalse(Announcements.relevant(news("a", max: "1.30.2"), appVersion: "1.30.3"))
    }

    // MARK: When, and what opens

    func testTwiceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(Announcements.due(now: now, last: 0), "never looked")
        XCTAssertFalse(Announcements.due(now: now, last: now.timeIntervalSince1970 - 11 * 3600))
        XCTAssertTrue(Announcements.due(now: now, last: now.timeIntervalSince1970 - 12 * 3600))
        XCTAssertTrue(Announcements.due(now: now, last: now.timeIntervalSince1970 + 3600), "the clock went back")
    }

    func testOnlyGitHubLinksOpen() {
        XCTAssertNotNil(Announcements.link("https://github.com/0xSilentNeo/Folio/releases/tag/v1.30.3"))
        XCTAssertNotNil(Announcements.link("https://gist.github.com/x"))
        XCTAssertNotNil(Announcements.link("HTTPS://GitHub.com/x"))
        for bad in ["http://github.com/x", "https://github.com.evil.example/x", "https://notgithub.com/x", "https://evil.example/github.com",
                    "folio://addon?url=x", "https://raw.githubusercontent.com/x", "", "github.com/x"] {
            XCTAssertNil(Announcements.link(bad), bad)
        }
        XCTAssertNil(Announcements.link(nil))
    }

    func testTheSettingsAreRegisteredAndFound() {
        SettingsKey.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[SettingsKey.announcements] as? Bool, true)
        XCTAssertEqual(registered[SettingsKey.diagnosticsKeepOn] as? Bool, false)
        XCTAssertTrue(SettingsIndex.search("announcements").contains { $0.title == "News from Folio" && $0.page == .notifications })
        for q in ["logs", "diagnostics", "trace"] {
            XCTAssertTrue(SettingsIndex.search(q).contains { $0.title == "Keep Traces On" && $0.route == .settingsSubpage(.diagnostics) }, q)
        }
    }

    // MARK: Traces kept on

    func testTracesKeptOnDontGoOffAfterADay() throws {
        let name = "Fixes1303FeatureTests.traces"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        defer { d.removePersistentDomain(forName: name) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        d.set(true, forKey: SettingsKey.libTrace)
        XCTAssertFalse(TraceExpiry.check(now: t0, defaults: d), "the day starts")

        // Kept on: each launch (and each return to Folio) starts the day again.
        d.set(true, forKey: SettingsKey.diagnosticsKeepOn)
        var now = t0
        for _ in 0..<5 {
            now = now.addingTimeInterval(30 * 3600)
            TraceKeepOn.refresh(now: now, defaults: d)
            XCTAssertFalse(TraceExpiry.check(now: now, defaults: d))
            XCTAssertTrue(d.bool(forKey: SettingsKey.libTrace))
        }
        // A trace that's off gets no stamp from it.
        XCTAssertNil(d.object(forKey: TraceKeepOn.stamp(SettingsKey.netTrace)))

        // Not kept on any more: off a day after that.
        d.set(false, forKey: SettingsKey.diagnosticsKeepOn)
        TraceKeepOn.refresh(now: now.addingTimeInterval(23 * 3600), defaults: d)
        XCTAssertFalse(TraceExpiry.check(now: now.addingTimeInterval(23 * 3600), defaults: d))
        XCTAssertTrue(TraceExpiry.check(now: now.addingTimeInterval(25 * 3600), defaults: d))
        XCTAssertFalse(d.bool(forKey: SettingsKey.libTrace))
    }
}
