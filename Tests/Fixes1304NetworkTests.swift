import XCTest
import UIKit
@testable import Folio

/// 1.30.4: what a preset adds before anything changes, the sync queue read
/// entry by entry, the links addons and deep links may hand Folio, free
/// space for downloads, News from Folio's waiting banners, and the smaller
/// network decisions (IMDb's web view, a debrid address, catalog keys).
@MainActor
final class Fixes1304NetworkTests: XCTestCase {

    // MARK: Presets

    private let known: [String: SettingsPreset.Kind] = [
        "subLangs": .string, "autoPlay": .bool,
        SettingsKey.downloadDeleteWatched: .int, SettingsKey.scriptCommands: .data,
    ]

    private func preset(settings: String = "{}", extra: String = "") -> Data {
        Data(#"{"format": "folio-preset", "version": 1, "settings": \#(settings)\#(extra)}"#.utf8)
    }

    func testAPresetIsReadWithoutChangingAnything() throws {
        let json = preset(settings: #"{"subLangs": "en", "autoPlay": true, "gone": 3, "downloadDeleteWatched": 1, "scriptCommands": "W10="}"#, extra: #"""
        , "addons": [{"transportURL": "https://addon.example/key123/manifest.json", "manifest": {"id": "a", "name": "Addon A", "types": [], "catalogs": [], "resources": []}}, {"nonsense": 1}],
          "webdav": [{"name": "NAS", "url": "https://nas.example/dav", "username": "me", "password": "pw"}, {"name": "no url"}],
          "mpv": {"mpv.conf": "script=/x.lua", "input.conf": "a quit", "scripts/evil.lua": "os.exit()", "scripts-disabled/old.js": "x",
                  "script-opts/osc.conf": "a=b", "shaders/sharpen.glsl": "//", "fonts/x.txt": "x", "../escape.conf": "x", "shaders/../../x.glsl": "x"}
        """#)
        let p = try SettingsPreset.plan(json, known: known, deleteWatchedNow: 7)
        XCTAssertEqual(p.settings["subLangs"] as? String, "en")
        XCTAssertEqual(p.settings["autoPlay"] as? Bool, true)
        XCTAssertNil(p.settings[SettingsKey.downloadDeleteWatched], "shorter than now: asked on its own")
        XCTAssertNil(p.settings[SettingsKey.scriptCommands], "the command buttons go with mpv's files")
        XCTAssertEqual(p.deleteWatched, 1)
        XCTAssertNotNil(p.commandButtons)
        XCTAssertEqual(p.skipped, ["gone"])
        XCTAssertEqual(p.addons.map(\.host), ["addon.example"])
        XCTAssertEqual(p.addons.first?.name, "Addon A")
        XCTAssertEqual(p.servers.map(\.name), ["NAS"])
        XCTAssertEqual(p.servers.first?.password, "pw")
        XCTAssertEqual(p.filesOf(.script).map(\.path), ["scripts-disabled/old.js", "scripts/evil.lua"])
        XCTAssertEqual(p.filesOf(.conf).map(\.path), ["input.conf", "mpv.conf", "script-opts/osc.conf"])
        XCTAssertEqual(p.filesOf(.shader).map(\.path), ["shaders/sharpen.glsl"])
        XCTAssertEqual(Set(p.strayFiles), ["fonts/x.txt", "../escape.conf", "shaders/../../x.glsl"])
    }

    func testScriptsAndMPVsFilesAreOffUntilTicked() {
        let c = SettingsPreset.Plan.Choices()
        XCTAssertFalse(c.scripts)
        XCTAssertFalse(c.conf)
        XCTAssertFalse(c.deleteWatched)
        XCTAssertTrue(c.addons)
        XCTAssertTrue(c.servers)
        XCTAssertFalse(c.allows(.script))
        XCTAssertFalse(c.allows(.conf))
        XCTAssertTrue(c.allows(.shader))
        var ticked = c
        ticked.scripts = true
        XCTAssertTrue(ticked.allows(.script))
        XCTAssertFalse(ticked.allows(.conf))
    }

    func testWhereAPresetsMPVFileGoes() {
        XCTAssertEqual(SettingsPreset.fileKind("mpv.conf"), .conf)
        XCTAssertEqual(SettingsPreset.fileKind("input.conf"), .conf)
        XCTAssertEqual(SettingsPreset.fileKind("script-opts/stats.conf"), .conf)
        XCTAssertEqual(SettingsPreset.fileKind("scripts/a.lua"), .script)
        XCTAssertEqual(SettingsPreset.fileKind("scripts/dir/main.js"), .script)
        XCTAssertEqual(SettingsPreset.fileKind("shaders/a.lua"), .script, "Lua is a script wherever it is")
        XCTAssertEqual(SettingsPreset.fileKind("shaders/FSR.glsl"), .shader)
        for bad in ["other.conf", "fonts/a.ttf", "/etc/x", "../mpv.conf", "scripts/../../x", "scripts//a", "./mpv.conf", ""] {
            XCTAssertNil(SettingsPreset.fileKind(bad), bad)
        }
    }

    func testDeleteWatchedIsAskedOnlyWhenItWouldDeleteMore() throws {
        func plan(_ days: Int, now: Int) throws -> SettingsPreset.Plan {
            try SettingsPreset.plan(preset(settings: #"{"downloadDeleteWatched": \#(days)}"#), known: known, deleteWatchedNow: now)
        }
        XCTAssertEqual(try plan(7, now: 0).deleteWatched, 7, "turned on")
        XCTAssertEqual(try plan(1, now: 7).deleteWatched, 1, "made shorter")
        XCTAssertNil(try plan(7, now: 1).deleteWatched)
        XCTAssertEqual(try plan(7, now: 1).settings[SettingsKey.downloadDeleteWatched] as? Int, 7, "longer: a setting as any other")
        XCTAssertEqual(try plan(0, now: 7).settings[SettingsKey.downloadDeleteWatched] as? Int, 0, "off")
        XCTAssertTrue(WatchedCleanup.asksBeforeDeleting(old: 0, new: 1))
        XCTAssertTrue(WatchedCleanup.asksBeforeDeleting(old: 7, new: 1))
        XCTAssertFalse(WatchedCleanup.asksBeforeDeleting(old: 1, new: 7))
        XCTAssertFalse(WatchedCleanup.asksBeforeDeleting(old: 7, new: 0))
        XCTAssertFalse(WatchedCleanup.asksBeforeDeleting(old: 7, new: 7))
    }

    func testWhatIsntAPresetIsRefused() {
        XCTAssertThrowsError(try SettingsPreset.plan(Data("{}".utf8), known: known, deleteWatchedNow: 0))
        XCTAssertThrowsError(try SettingsPreset.plan(Data(#"{"format": "other"}"#.utf8), known: known, deleteWatchedNow: 0))
        XCTAssertThrowsError(try SettingsPreset.plan(Data("not json".utf8), known: known, deleteWatchedNow: 0))
        XCTAssertTrue(try SettingsPreset.plan(Data(#"{"format": "folio-preset", "version": 9}"#.utf8), known: known, deleteWatchedNow: 0).newerVersion)
    }

    // MARK: The sync queue

    func testTheQueueIsReadEntryByEntry() {
        let json = #"[{"service": "trakt", "attempts": 1}, {"service": "plex", "attempts": 0}, {"service": "mal", "attempts": "x"}, 5, {"service": "anilist", "attempts": 3}]"#
        let jobs = SyncCenter.decodeJobs(Data(json.utf8))
        XCTAssertEqual(jobs.map(\.service), [.trakt, .anilist], "the unreadable ones are left out, not the rest")
        XCTAssertEqual(jobs.map(\.attempts), [1, 3])
        XCTAssertTrue(SyncCenter.decodeJobs(Data("{}".utf8)).isEmpty)
    }

    func testTheSentMapIsReadEntryByEntry() {
        let json = #"{"trakt|tt1|1|2": "2026-11-14T10:00:00Z", "bad": "yesterday", "num": 5}"#
        let sent = SyncCenter.decodeSent(Data(json.utf8))
        XCTAssertEqual(Array(sent.keys), ["trakt|tt1|1|2"])
        XCTAssertEqual(sent["trakt|tt1|1|2"], ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z"))
        XCTAssertTrue(SyncCenter.decodeSent(Data("[]".utf8)).isEmpty)
    }

    func testARefusedRenewalAsksForANewSignIn() {
        XCTAssertTrue(SyncCenter.refusedRefresh(status: 401, body: ""))
        XCTAssertTrue(SyncCenter.refusedRefresh(status: 400, body: #"{"error":"invalid_grant"}"#))
        XCTAssertFalse(SyncCenter.refusedRefresh(status: 400, body: "bad request"))
        XCTAssertFalse(SyncCenter.refusedRefresh(status: 0, body: "offline"))
        XCTAssertFalse(SyncCenter.refusedRefresh(status: 503, body: ""))
    }

    // MARK: Addon links

    private func stream(_ url: String) throws -> AddonStream {
        try JSONDecoder().decode(AddonStream.self, from: Data(#"{"url": "\#(url)", "name": "S"}"#.utf8))
    }

    func testOnlyNetworkStreamsFromAnAddonPlay() throws {
        for good in ["https://debrid.example/f.mkv", "http://nas.local/a.mkv", "smb://nas/share/a.mkv", " https://a.example/x "] {
            XCTAssertTrue(AddonStream.isPlayable(good), good)
        }
        for bad in ["edl://a;b", "lavfi://color", "file:///private/a.mkv", "/var/mobile/a.mkv", "magnet:?xt=urn:btih:1", "https:///nohost", "", "javascript:alert(1)"] {
            XCTAssertFalse(AddonStream.isPlayable(bad), bad)
        }
        XCTAssertTrue(try stream("https://a.example/x.mkv").isPlayable)
        XCTAssertFalse(try stream("edl://x").isPlayable)
    }

    func testAnAddonsOtherLinksDontReachThePlayer() throws {
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data(#"{"id": "a", "name": "A", "types": [], "catalogs": [], "resources": []}"#.utf8))
        let addon = InstalledAddon(transportURL: "https://addon.example/manifest.json", manifest: manifest)
        let c = PlayContext(name: "Film", poster: nil, type: "movie", metaId: "tt1", isAnime: false, videoId: "tt1", videoLabel: nil, episode: nil)
        XCTAssertNil(AddonPlayback.makeItem(c, stream: try stream("edl://a"), addon: addon, extraSubtitles: []))
        let item = try XCTUnwrap(AddonPlayback.makeItem(c, stream: try stream("https://a.example/f.mkv"), addon: addon,
                                                        extraSubtitles: [ExternalSubtitle(url: "file:///etc/x.srt", lang: "en", title: nil),
                                                                         ExternalSubtitle(url: "https://subs.example/x.srt", lang: "en", title: nil)]))
        XCTAssertEqual(item.subtitles.map(\.url), ["https://subs.example/x.srt"])
    }

    // MARK: Deep links

    func testALibraryLinkOpensOnlyTheLibrarysFiles() {
        let media = "/var/mobile/Containers/Data/Application/X/Documents/Media"
        XCTAssertEqual(LibraryLink.allowed(media + "/Show/E1.mkv", media: media), media + "/Show/E1.mkv")
        XCTAssertNotNil(LibraryLink.allowed("/private" + media + "/E1.mkv", media: media), "/private/var is /var")
        for bad in [media + "/../Library/Preferences/x.plist", "/var/mobile/Containers/Data/Application/X/Library/a.plist",
                    media + "X/a.mkv", media, "Media/a.mkv", "", media + "/./a.mkv"] {
            XCTAssertNil(LibraryLink.allowed(bad, media: media), bad)
        }
        XCTAssertEqual(LibraryLink.allowed("/elsewhere/a.mkv", media: media, library: ["/elsewhere/a.mkv"]), "/elsewhere/a.mkv", "one the library lists")
    }

    func testATitleLinksPosterComesOnlyFromImageHosts() throws {
        XCTAssertNotNil(TitleLink.posterAllowed("https://m.media-amazon.com/images/M/x.jpg"))
        XCTAssertNotNil(TitleLink.posterAllowed("https://image.tmdb.org/t/p/w500/x.jpg"))
        for bad in ["http://m.media-amazon.com/x.jpg", "https://evil.example/x.jpg", "https://m.media-amazon.com.evil.example/x.jpg",
                    "https://192.168.1.1/x.jpg", "file:///x.jpg", "x"] {
            XCTAssertNil(TitleLink.posterAllowed(bad), bad)
        }
        let evil = try XCTUnwrap(URL(string: TitleLink.make(id: "tt1", type: "movie", name: "A", poster: "https://evil.example/p.jpg")))
        let m = try XCTUnwrap(TitleLink.meta(from: evil))
        XCTAssertEqual(m.id, "tt1")
        XCTAssertNil(m.poster, "the title opens; the poster isn't fetched")
        let fine = try XCTUnwrap(URL(string: TitleLink.make(id: "tt1", type: "movie", name: "A", poster: "https://m.media-amazon.com/images/M/p.jpg")))
        XCTAssertEqual(TitleLink.meta(from: fine)?.poster, "https://m.media-amazon.com/images/M/p.jpg")
    }

    // MARK: Downloads

    func testADownloadNeedsRoomForItsRestAndAMargin() throws {
        let gb: Int64 = 1 << 30
        XCTAssertNil(DownloadManager.spaceShortfall(remaining: 2 * gb, available: 4 * gb))
        XCTAssertNil(DownloadManager.spaceShortfall(remaining: 0, available: 2 * gb), "size unknown: the margin only")
        XCTAssertNil(DownloadManager.spaceShortfall(remaining: 5 * gb, available: nil), "not known: not held")
        let why = try XCTUnwrap(DownloadManager.spaceShortfall(remaining: 2 * gb, available: 2 * gb))
        XCTAssertTrue(why.hasPrefix(ChunkPlan.noSpace), why)
        XCTAssertTrue(why.contains("needs") && why.contains("free"), why)
        XCTAssertTrue(DownloadManager.isPermanent(why), "not retried by itself")
        XCTAssertNotNil(DownloadManager.spaceShortfall(remaining: 0, available: gb / 2))
    }

    func testWhyDownloadsAreHeld() {
        XCTAssertNil(DownloadManager.holdReason(lowPowerSetting: true, lowPower: false, chargingSetting: false, battery: .unplugged))
        XCTAssertEqual(DownloadManager.holdReason(lowPowerSetting: true, lowPower: true, chargingSetting: false, battery: .full), "Paused for Low Power Mode")
        XCTAssertNil(DownloadManager.holdReason(lowPowerSetting: false, lowPower: true, chargingSetting: false, battery: .unplugged))
        XCTAssertEqual(DownloadManager.holdReason(lowPowerSetting: false, lowPower: false, chargingSetting: true, battery: .unplugged), "Waiting for charging")
        XCTAssertNil(DownloadManager.holdReason(lowPowerSetting: false, lowPower: false, chargingSetting: true, battery: .charging))
    }

    func testAVideosSubtitlesGoWithIt() {
        let dir = URL(fileURLWithPath: "/tmp/Media/Show", isDirectory: true)
        func item(_ name: String, in folder: URL = dir, package: String = "Show") -> DownloadItem {
            DownloadItem(url: URL(string: "https://a.example/\(name.replacingOccurrences(of: " ", with: "%20"))")!, fileName: name,
                         package: package, expected: 1, destination: folder.appendingPathComponent(name))
        }
        let video = item("Show S01E01.mkv")
        XCTAssertTrue(DownloadManager.isSubtitle(item("Show S01E01.en.srt"), of: video))
        XCTAssertFalse(DownloadManager.isSubtitle(item("Show S01E02.en.srt"), of: video))
        XCTAssertFalse(DownloadManager.isSubtitle(item("Show S01E01.en.srt", in: URL(fileURLWithPath: "/tmp/Media/Other")), of: video))
        XCTAssertFalse(DownloadManager.isSubtitle(item("Show S01E01.en.srt", package: "Other"), of: video))
        XCTAssertFalse(DownloadManager.isSubtitle(video, of: video))
    }

    func testThePillStaysForPausedFiles() {
        let paused = DownloadPillSnapshot(hasWork: false, active: 0, paused: 2)
        XCTAssertTrue(paused.shown)
        XCTAssertTrue(paused.resumes, "its button is Resume all")
        let waiting = DownloadPillSnapshot(hasWork: true, active: 0, paused: 0)
        XCTAssertTrue(waiting.shown)
        XCTAssertFalse(waiting.resumes, "queued only: Pause all")
        XCTAssertFalse(DownloadPillSnapshot(hasWork: true, active: 1, paused: 1).resumes)
        XCTAssertFalse(DownloadPillSnapshot().shown)
    }

    func testTheKidsProfilesDownloadNotificationNamesNoFile() {
        XCTAssertEqual(DownloadManager.neutralDone(1), "A download is in your library.")
        XCTAssertEqual(DownloadManager.neutralDone(3), "3 files are in your library.")
    }

    /// A debrid address that ran out is asked through the link again; one
    /// that never took a direct request ends using addresses for the run.
    func testAnAddressTheLinkLedTo() {
        let a = URL(string: "https://cdn.debrid.example/f.mkv")!, b = URL(string: "https://cdn2.debrid.example/f.mkv")!
        XCTAssertEqual(ChunkPlan.refusal(status: 403, address: nil, current: a, worked: true), .stands, "through the link: a failure as before")
        XCTAssertEqual(ChunkPlan.refusal(status: 500, address: a, current: a, worked: true), .stands)
        XCTAssertEqual(ChunkPlan.refusal(status: 403, address: a, current: a, worked: true), .askLink, "it ran out")
        XCTAssertEqual(ChunkPlan.refusal(status: 410, address: a, current: a, worked: false), .stopUsingAddress, "never worked")
        XCTAssertEqual(ChunkPlan.refusal(status: 401, address: a, current: b, worked: false), .askLink, "an old one: where the others are")
        XCTAssertEqual(ChunkPlan.refusal(status: 404, address: a, current: nil, worked: false), .askLink)
    }

    // MARK: News from Folio

    private func news(_ id: String, _ date: String? = nil, max: String? = nil) -> Announcements.Entry {
        Announcements.Entry(id: id, title: id, maxVersion: max, date: date)
    }

    func testBannersWaitInTurn() {
        let a = news("a"), b = news("b"), c = news("c")
        XCTAssertEqual(Announcements.queued([a], adding: [b, c], appVersion: "1.30.4").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(Announcements.queued([a, b], adding: [b, c], appVersion: "1.30.4").map(\.id), ["a", "b", "c"], "no id twice")
        XCTAssertEqual(Announcements.queued([news("old", max: "1.30.3"), a], adding: [], appVersion: "1.30.4").map(\.id), ["a"], "no longer worth showing")
        let update = Announcements.Entry(id: "u", title: "1.30.4 is out", version: "1.30.4")
        XCTAssertTrue(Announcements.queued([update], adding: [], appVersion: "1.30.4").isEmpty, "the update it announced is installed")
    }

    func testWhatsShownIsntSeenUntilItIs() {
        let s = Announcements.select([news("a", "2026-11-01"), news("b", "2026-11-03"), news("c", "2026-11-02"), news("old", max: "1.0")],
                                     seen: [], firstRun: false, appVersion: "1.30.4")
        XCTAssertEqual(s.show.map(\.id), ["b", "c"])
        XCTAssertTrue(Announcements.seenNow(s).isEmpty, "both wait as banners, marked once shown or posted")
        let first = Announcements.select([news("a"), Announcements.Entry(id: "u", title: "u", version: "1.30.5")], seen: [], firstRun: true, appVersion: "1.30.4")
        XCTAssertEqual(first.show.map(\.id), ["u"])
        XCTAssertEqual(Announcements.seenNow(first), ["a"], "skipped for good at the first look: seen at once")
        // A waiting banner isn't picked again (apply passes it as seen).
        let again = Announcements.select([news("b"), news("c"), news("d")], seen: ["b", "c"], firstRun: false, appVersion: "1.30.4")
        XCTAssertEqual(again.show.map(\.id), ["d"])
    }

    // MARK: IMDb, catalogs, episodes

    func testOnlyIMDbsBotCheckGoesToTheWebView() {
        XCTAssertTrue(IMDbSource.needsBrowser(status: 202, body: ""))
        XCTAssertTrue(IMDbSource.needsBrowser(status: 403, body: #"<script src="https://x.token.awswaf.com/challenge.js"></script>"#))
        XCTAssertTrue(IMDbSource.needsBrowser(status: 403, body: "window.gokuProps = {}"))
        XCTAssertFalse(IMDbSource.needsBrowser(status: 403, body: "<html>Forbidden</html>"))
        XCTAssertFalse(IMDbSource.needsBrowser(status: 429, body: "slow down"))
        XCTAssertFalse(IMDbSource.needsBrowser(status: 200, body: "<html>nothing</html>"))
        XCTAssertEqual(IMDbSource.backoff(status: 429, error: nil), 30)
        XCTAssertEqual(IMDbSource.backoff(status: nil, error: .timedOut), 10)
        XCTAssertEqual(IMDbSource.backoff(status: nil, error: .networkConnectionLost), 10)
        XCTAssertEqual(IMDbSource.backoff(status: nil, error: .cannotFindHost), 10)
        XCTAssertNil(IMDbSource.backoff(status: 403, error: nil))
        XCTAssertNil(IMDbSource.backoff(status: nil, error: .badServerResponse))
    }

    func testAReinstalledAddonKeepsItsHiddenCatalogs() {
        let keys: Set<String> = ["https://a.example/old/manifest.json|movie|top", "https://b.example/manifest.json|series|top"]
        XCTAssertEqual(AddonStore.movedKeys(keys, from: "https://a.example/old/manifest.json", to: "https://a.example/new/manifest.json"),
                       ["https://a.example/new/manifest.json|movie|top", "https://b.example/manifest.json|series|top"])
    }

    func testAnEpisodeDatedOnlyByAYearIsntOutUntilItsOver() {
        let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func v(_ r: String?) -> MetaVideo { var x = MetaVideo(id: "tt1:2:1", title: "E", season: 2, episode: 1); x.released = r; return x }
        XCTAssertTrue(v("2027").airsLater(now: now, calendar: cal))
        XCTAssertTrue(v("2026").airsLater(now: now, calendar: cal), "this year, no day yet: not out")
        XCTAssertFalse(v("2025").airsLater(now: now, calendar: cal))
        XCTAssertTrue(v("2026-12").airsLater(now: now, calendar: cal))
        XCTAssertTrue(v("2026-11").airsLater(now: now, calendar: cal))
        XCTAssertFalse(v("2026-10").airsLater(now: now, calendar: cal))
        XCTAssertFalse(v("soon").airsLater(now: now, calendar: cal))
        XCTAssertFalse(v("20x6").airsLater(now: now, calendar: cal))
        // Whole dates as before.
        XCTAssertTrue(v("2026-11-20").airsLater(now: now, calendar: cal))
        XCTAssertFalse(v("2026-11-01").airsLater(now: now, calendar: cal))
    }

    // MARK: Anime ids for sync

    /// An id lookup AniList or ids.moe didn't answer is "not reached" (the
    /// scrobble waits), not "not found" (skipped).
    func testAnAnimeLookupThatWasntAnsweredIsntNotFound() {
        let none = AnimeHint(title: "Sousou no Frieren", episode: 5)
        XCTAssertEqual(SkipService.idLookup(none, failed: false), .notFound)
        XCTAssertEqual(SkipService.idLookup(none, failed: true), .unreachable, "offline, 429, ids.moe down")
        var al = none; al.anilistId = 154587
        XCTAssertEqual(SkipService.idLookup(al, failed: true), .found(al), "an id found is kept, however ids.moe went")
        var mal = none; mal.malId = 52991
        XCTAssertEqual(SkipService.idLookup(mal, failed: false), .found(mal))
        var other = none; other.kitsuId = 46474; other.anidbId = 17617
        XCTAssertEqual(SkipService.idLookup(other, failed: false), .notFound, "Kitsu and AniDB ids aren't what sync sends")
        XCTAssertEqual(SkipService.idLookup(other, failed: true), .unreachable)
        for status in [0, 408, 429, 500, 503] { XCTAssertTrue(SkipService.failedForNow(status: status), "\(status)") }
        for status in [200, 400, 401, 403, 404] { XCTAssertFalse(SkipService.failedForNow(status: status), "\(status)") }
    }
}
