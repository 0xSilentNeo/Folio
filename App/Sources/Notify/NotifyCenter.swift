import SwiftUI
import UIKit
import UserNotifications

/// Schedules Folio's own notifications (1.25.0; the 1.24.0 reminders grew
/// into this). They're planned when Folio leaves the screen (a chain up to
/// two weeks ahead, since Folio may not run for days). Coming back takes
/// back the ones that hang on what you do in Folio; the charts, the
/// briefing and the weather stay pending (1.28.5: until then every one was
/// taken back, so one due while you were in Folio never came).
///
/// Each one: the wording in your personality, the next of its kind's lines
/// (never the same twice in a row), the group's sound, the title's poster
/// when there is one, and Play / Tomorrow / Fewer like this. A kind you
/// dismiss three times in a row without opening rests for two weeks.
///
/// Test: leaving Folio sends every kind that's on, one every 20 seconds,
/// with your own titles where Folio has the facts and samples where it
/// doesn't. Opening Folio stops the run; leaving again carries on from
/// where it stopped. Each run moves every kind to its next line.
@MainActor
enum NotifyCenter {
    static let prefix = "folio.notify."
    /// The pending ones at most outside Test (iOS keeps 64 per app; the tracker uses up to 40).
    static let maxPending = 12
    static let categoryPlay = "folio.notify.play"
    static let categoryPlain = "folio.notify.plain"
    static let restDays = 14.0
    static let restAfter = 3

    nonisolated static var lab: Bool { CommandLine.arguments.contains("-labEngage") }

    private static var started = false
    private static var running: Task<Void, Never>?
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid

    // MARK: Start

    /// FolioApp, at launch.
    static func start() {
        guard !started else { return }
        started = true
        migrate()
        // 1.28.6: Test was on by default (left from the 1.25.0 test build),
        // so real notifications were never planned and new-episode alerts
        // were held. Off once for everyone; it can be turned on again.
        if !UserDefaults.standard.bool(forKey: "notifyTestOffOnce") {
            UserDefaults.standard.set(true, forKey: "notifyTestOffOnce")
            if NotifyPrefs.test { dlog("notify", "Test was on from an earlier build: turned off") }
            UserDefaults.standard.removeObject(forKey: SettingsKey.notifyTest)
            UserDefaults.standard.removeObject(forKey: "notifyTestNext")
        }
        registerCategories()
        for s in NotifySounds.folio { NotifySounds.file(for: .folio(s)) }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                HabitLog.shared.ended()
                // Planned once Folio has really left (AwayWork, 1.28.2): a
                // dozen requests with pictures, taken back on return.
                AwayWork.onLeaving("notifications") { replan("left the screen") }
            }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                HabitLog.shared.began()
                if !lab { takeBack(keepOutside: true) }
                refreshFeeds(after: 4)
            }
        }
        if lab { Task { await runLab() } }
        // `-openNotifyLink <folio://…>` (lab): what a tap on a notification with that link does.
        if let i = CommandLine.arguments.firstIndex(of: "-openNotifyLink"), i + 1 < CommandLine.arguments.count {
            open(CommandLine.arguments[i + 1])
        }
        // `-openNotify` (lab, UI tests): Settings → Notifications over Home.
        if CommandLine.arguments.contains("-openNotify") {
            HandoffPresenter.present(AnyView(NavigationStack {
                NotifySettingsView()
                    .settingsPage()
                    .navigationDestination(for: LibraryRoute.self) { LibraryRoute.destination($0) }
            }.tint(Theme.accent)))
        }
    }

    /// 1.24's reminders: their pending ones go (they'd come twice), and
    /// what was sent counts for the rules.
    private static func migrate() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "notifyMigrated") else { return }
        d.set(true, forKey: "notifyMigrated")
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let old = reqs.map(\.identifier).filter { $0.hasPrefix("engage.") }
            center.removePendingNotificationRequests(withIdentifiers: old)
        }
        if let data = d.data(forKey: "engageSent"), let old = try? JSONDecoder().decode([EngagePlanner.Sent].self, from: data) {
            let moved: [NotifySent] = old.compactMap { s in
                guard let k = NotifyKind(rawValue: momentName(s.id)) else { return nil }
                return NotifySent(key: s.id, kind: k, at: s.at, showKey: s.showKey)
            }
            saveSent(loadSent() + moved)
        }
    }

    /// "paused.…" → "paused", for 1.24's sent ids.
    private static func momentName(_ id: String) -> String {
        let head = String(id.split(separator: ".").first ?? "")
        switch head {
        case "cliff": return "cliffhanger"
        case "film": return "filmNearlyDone"
        case "left": return "showNearlyDone"
        case "late": return "lateNight"
        case "away": return "weekAway"
        case "plants": return "houseplants"
        default: return head
        }
    }

    /// The charts, the forecast and the holidays, while Folio is in front.
    static func refreshFeeds(after seconds: Double = 0) {
        Task {
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            await refreshFeedsNow()
        }
    }

    static func refreshFeedsNow() async {
        async let a: Void = TrendFeed.refresh()
        async let b: Void = WeatherFeed.refresh()
        async let c: Void = HolidayFeed.refresh()
        _ = await (a, b, c)
        if NotifyPrefs.allowed(.unwatchedClassic) { _ = await IMDbSource.chart("/chart/top/", type: "movie") }
    }

    // MARK: Plan

    /// Planned again from scratch.
    static func replan(_ reason: String) {
        let previous = running
        beginBackgroundTask()
        running = Task {
            await previous?.value
            await apply(reason)
            endBackgroundTask()
        }
    }

    /// Taken back: on coming back to Folio (`keepOutside`) the ones that
    /// hang on what you do in it, else every planned one (a setting
    /// changed; all planned again when Folio leaves). `asked` takes
    /// "Tomorrow" and Send the next one too (notifications turned off).
    static func takeBack(keepOutside: Bool = false, asked: Bool = false) {
        let previous = running
        running = Task {
            await previous?.value
            if NotifyPrefs.test { await checkDeliveredPictures() }
            let now = Date()
            let keep = keepOutside && !NotifyPrefs.test ? await pendingKept(now: now) : []
            settle(now: now, keep: keep)
            // "Tomorrow" ones go too while the kids profile is on (1.30.4).
            await removePending(keeping: Set(keep.map(\.request)), asked: asked || KidsProfile.isOnNow)
            if !keep.isEmpty { dlog("notify", "back in Folio: \(keep.count) left pending (\(keep.map(\.kind.rawValue).joined(separator: ", ")))") }
        }
    }

    /// A notification setting changed while Folio is open: what's pending
    /// was planned with the old ones.
    static func settingsChanged() {
        takeBack()
    }

    /// The planned ones that stay while Folio is open and are still pending.
    private static func pendingKept(now: Date) async -> [Scheduled] {
        let kept = loadScheduled().filter { !$0.test && $0.at > now && $0.kind.keptWhileOpen }
        guard !kept.isEmpty else { return [] }
        let pending = Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
        return kept.filter { pending.contains($0.request) }
    }

    private static func apply(_ reason: String) async {
        let now = Date()
        settle(now: now, keep: [])
        await removePending()
        guard !KidsProfile.isOnNow else { return }
        guard NotifyPrefs.allOn else {
            dlog("notify", "nothing planned: notifications are off in Folio")
            return
        }
        let center = UNUserNotificationCenter.current()
        guard [.authorized, .provisional, .ephemeral].contains(await center.notificationSettings().authorizationStatus) else {
            dlog("notify", "nothing planned: notifications aren't allowed")
            return
        }
        if NotifyPrefs.test {
            // An hour after Test was first seen on, it's off (1.28.10): a
            // whole run only ends it if you stay away for all of it.
            let d = UserDefaults.standard
            if let since = d.object(forKey: "notifyTestSince") as? Date, now.timeIntervalSince(since) > 3600 {
                d.removeObject(forKey: "notifyTestSince")
                d.set(false, forKey: SettingsKey.notifyTest)
                dlog("notify", "test: on for over an hour; Test is off again")
                AiringNotifications.reschedule(TrackingStore.shared.shows)
                NotifyPrefsModel.shared.changed()
            } else {
                if d.object(forKey: "notifyTestSince") == nil { d.set(now, forKey: "notifyTestSince") }
                await scheduleTest(now: now)
                return
            }
        } else {
            UserDefaults.standard.removeObject(forKey: "notifyTestSince")
        }
        let all = await candidates(now: now)
        let chosen = Array(NotifyPlanner.choose(all, rules(now: now)).prefix(maxPending))
        var records: [Scheduled] = []
        for ch in chosen {
            // Written down as each is added (1.30.2): each waits up to 4 s
            // for its picture, and iOS suspending Folio part-way left the
            // ones already added unrecorded, to be sent again.
            if let r = await schedule(ch.candidate, at: ch.fire, test: false) { records.append(r); saveScheduled(records) }
        }
        saveScheduled(records)
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM HH:mm"
        dlog("notify", "\(records.count) planned (\(reason)) of \(all.count) candidates"
             + (chosen.isEmpty ? "" : ": " + chosen.map { "\($0.candidate.kind.rawValue) \(f.string(from: $0.fire))" }.joined(separator: ", ")))
    }

    static func rules(now: Date) -> NotifyPlanner.Rules {
        var r = NotifyPlanner.Rules(now: now)
        r.quiet = NotifyPrefs.quiet
        r.maxPerDay = NotifyPrefs.maxPerDay
        r.preferredMinute = NotifyPlanner.preferredMinute(firstHours: firstHours(), quiet: r.quiet)
        r.sent = loadSent()
        let resting = Set(memory.filter { ($0.value.restUntil ?? .distantPast) > now }.keys)
        r.allowed = { k in NotifyPrefs.allowed(k) && !resting.contains(k.rawValue) && !k.group.essential }
        return r
    }

    /// The first hour watched (from 5 am on) of each of the last 21 days with watching.
    static func firstHours() -> [Int] {
        WatchLog.shared.days.suffix(21).compactMap { d in
            d.hours?.compactMap { k, v in Int(k).flatMap { $0 >= 5 && v >= 600 ? $0 : nil } }.min()
        }
    }

    /// Every candidate: the watching moments and the rest.
    static func candidates(now: Date) async -> [NotifyCandidate] {
        let watching = await EngagementState.gather(now: now)
        let moments: [NotifyCandidate] = EngagePlanner.candidates(watching, now: now).compactMap { p in
            guard let k = NotifyKind(rawValue: p.moment.rawValue) else { return nil }
            let entry = p.link.flatMap(URL.init(string:)).flatMap(ContinueLink.id(from:))
            return NotifyCandidate(kind: k, key: p.id, fire: p.fire, facts: p.facts, link: p.link, showKey: p.showKey,
                                   image: entry.map { .history($0) }, reason: "From what you watched")
        }
        return moments + NotifySignals.candidates(await inputs(now: now))
    }

    static func inputs(now: Date) async -> NotifySignals.Inputs {
        var x = NotifySignals.Inputs(now: now)
        let history = HistoryStore.shared
        let index = LibraryMetaIndex.shared
        let files = await ContinueQueue.libraryFiles()
        let groups = LibraryOrganizer.groups(files)
        x.films = groups.filter { !$0.isSeries }.compactMap { g in
            guard let f = g.files.first else { return nil }
            let m = index.meta(for: f)
            return .init(title: m?.name ?? g.title, path: f.path, added: g.date,
                         played: g.files.contains { history.entry(forURL: $0.path) != nil },
                         watched: g.files.contains { history.isWatched($0) },
                         imdbID: m.flatMap { $0.id.hasPrefix("tt") ? $0.id : nil }, rating: m?.rating.flatMap(Double.init), poster: m?.poster)
        }
        x.seriesCount = groups.filter(\.isSeries).count
        if index.complete, UserDefaults.standard.bool(forKey: SettingsKey.metadataFetching) {
            x.mystery = LibraryMetaIndex.lookupFiles(files).filter { index.meta(for: $0) == nil }.prefix(1).map(\.lastPathComponent)
        }
        let d = UserDefaults.standard
        if d.object(forKey: "notifyFilmsMax") != nil { x.filmsBefore = d.integer(forKey: "notifyFilmsMax") }
        if !files.isEmpty { d.set(max(x.filmsBefore ?? 0, x.films.count), forKey: "notifyFilmsMax") }
        let since = now.addingTimeInterval(-60 * 86400)
        x.watched = history.entries.filter { $0.updated >= since }.map { e in
            let meta = index.meta(for: URL(fileURLWithPath: e.id))
            let id = ForYou.addonTitle(e)?.id ?? meta.flatMap { $0.id.hasPrefix("tt") ? $0.id : nil }
            let genres = meta?.genres ?? id.flatMap { IMDbSource.cachedDetails(id: $0)?.genres } ?? []
            return .init(at: e.updated, genres: genres, imdbID: id)
        }
        x.continueCount = history.continueWatching.count
        x.continueSeries = history.continueWatching.filter { HistoryStore.episodeNumber($0) != nil }.count
        x.trend = TrendFeed.snapshot
        x.top250 = Set((IMDbSource.cachedStale("chart|/chart/top/|\(IMDbSource.language)", as: [MetaItem].self) ?? []).map(\.id))
        x.forYou = ForYou.saved()?.metas ?? []
        x.habits = HabitLog.shared.days
        x.watchDays = WatchLog.shared.days
        if let f = WeatherFeed.forecast, f.place == WeatherFeed.place { x.forecast = f.days }
        if let h = HolidayFeed.saved, h.country == HolidayFeed.country { x.holidays = h.holidays }
        x.quiet = NotifyPrefs.quiet
        return x
    }

    // MARK: One notification

    struct Scheduled: Codable {
        var request: String
        var key: String
        var kind: NotifyKind
        var at: Date
        var showKey: String?
        var test: Bool
    }

    /// Adds one; nil when it couldn't (no wording, or iOS refused).
    @discardableResult
    static func schedule(_ c: NotifyCandidate, at fire: Date, test: Bool, requestID: String? = nil) async -> Scheduled? {
        let wait = fire.timeIntervalSince(Date())
        guard wait > 1, let text = wording(c, test: test) else { return nil }
        let content = UNMutableNotificationContent()
        if let t = text.title { content.title = t }
        content.body = text.body
        content.sound = NotifySounds.sound(for: c.kind.group)
        content.threadIdentifier = "folio." + c.kind.group.rawValue
        content.categoryIdentifier = c.link != nil ? categoryPlay : categoryPlain
        content.relevanceScore = c.kind.group == .watching ? 0.8 : 0.4
        var info: [String: Any] = ["notify": c.kind.rawValue, "key": c.key]
        if let l = c.link { info["link"] = l }
        if test { info["test"] = true }
        content.userInfo = info
        if let img = c.image {
            if let a = await attachment(img) { content.attachments = [a] } else { dlog("notify", "\(c.kind.rawValue): no picture (\(img))") }
            if test { dlog("notify", "\(c.kind.rawValue): \(content.attachments.count) picture(s)") }
        }
        let id = requestID ?? prefix + (test ? "test." : "") + c.key
        // An interval, as the tracker's: the moment stays right across a time zone change.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            dlog("notify", "not scheduled (\(c.kind.rawValue)): \(error.localizedDescription)")
            return nil
        }
        appendLog(LogEntry(id: id, kind: c.kind, at: fire, title: text.title, body: text.body, reason: c.reason, test: test))
        return Scheduled(request: id, key: c.key, kind: c.kind, at: fire, showKey: c.showKey, test: test)
    }

    /// The text in your personality, the kind's current line. Test moves
    /// each kind to its next line every run; otherwise a line moves on once
    /// it has gone out.
    static func wording(_ c: NotifyCandidate, test: Bool) -> (title: String?, body: String)? {
        let tone = NotifyPrefs.tone
        let v = test ? bumpVariation(c.kind) : memory[c.kind.rawValue]?.variation ?? 0
        if let t = NotifyWording.text(c.kind, tone, c.facts, variation: v) { return t }
        if let t = NotifyWording.text(c.kind, .balanced, c.facts, variation: v), !c.kind.group.essential { return t }
        return plain(c.kind, c.facts)
    }

    /// The plain wording of the essential ones (Subtle).
    static func plain(_ k: NotifyKind, _ f: [String: String]) -> (title: String?, body: String)? {
        switch k {
        case .newEpisode: return f["what"].map { ("\($0) is out", f["extra"] ?? "") }
        case .newSeason: return f["show"].map { s in ("\(s) S\(f["season"] ?? "") is out", f["extra"] ?? "") }
        case .downloadFinished: return f["what"].map { ("Downloads finished", $0) }
        default: return nil
        }
    }

    /// The poster or still, written to a file iOS moves into its store.
    static func attachment(_ img: NotifyImage) async -> UNNotificationAttachment? {
        let address: String?
        switch img {
        case .url(let s): address = s
        case .history(let id):
            address = HistoryStore.shared.entry(for: id)?.item.artwork ?? LibraryMetaIndex.shared.meta(for: URL(fileURLWithPath: id))?.poster
        case .file(let path): address = LibraryMetaIndex.shared.meta(for: URL(fileURLWithPath: path))?.poster
        }
        guard let address, let url = URL(string: address) else {
            dlog("notify", "picture: no address")
            return nil
        }
        let data: Data? = await withTaskGroup(of: Data?.self) { g in
            g.addTask { await ImageCache.shared.image(url, maxPixel: 600)?.jpegData(compressionQuality: 0.85) }
            g.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        guard let data else {
            dlog("notify", "picture: not loaded in 4 s (\(url.host ?? url.scheme ?? "?"))")
            return nil
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notify-\(UUID().uuidString).jpg")
        do {
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "art", url: file, options: nil)
        } catch {
            dlog("notify", "picture not attached: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Test

    /// Test: whether the pictures of the notifications that came are still
    /// readable in iOS's store (a developer forums thread, 812127, reports
    /// previews missing while the notification still has its attachment).
    private static func checkDeliveredPictures() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications().filter { $0.request.identifier.hasPrefix(prefix) }
        guard !delivered.isEmpty else { return }
        var with = 0, readable = 0
        for n in delivered {
            for a in n.request.content.attachments {
                with += 1
                let scoped = a.url.startAccessingSecurityScopedResource()
                if (try? Data(contentsOf: a.url))?.isEmpty == false { readable += 1 }
                if scoped { a.url.stopAccessingSecurityScopedResource() }
            }
        }
        dlog("notify", "test: \(delivered.count) delivered, \(with) with a picture, \(readable) readable")
    }

    /// The kinds Test sends: the ones your settings would send for real
    /// (1.25.2): their group and their own switch on, allowed by the
    /// personality (Just for fun is off in Subtle), what they need set up
    /// (rain, cold and heat need a city), and not resting after three
    /// dismissals or turned off with Fewer Like This.
    static func testKinds(now: Date = Date()) -> [NotifyKind] {
        NotifyKind.allCases.filter { NotifyPrefs.allowed($0) && resting($0, now: now) == nil }
    }

    /// Every kind Test sends, in the Notifications page's order, from where
    /// the last run stopped.
    static func testOrder() -> [NotifyKind] {
        let on = testKinds()
        guard let next = UserDefaults.standard.string(forKey: "notifyTestNext").flatMap(NotifyKind.init(rawValue:)),
              let i = on.firstIndex(of: next) else { return on }
        return Array(on[i...] + on[..<i])
    }

    static func testCandidates(now: Date) async -> [NotifyCandidate] {
        let real = await candidates(now: now)
        let s = await samples()
        return testOrder().map { k in
            if var c = real.first(where: { $0.kind == k }) {
                c.reason = "Test, from your own: " + c.reason
                return c
            }
            // A sample's picture and tap are those of the title its text names
            // (1.25.1: every sample had the first Continue Watching title's).
            let about: SampleTitle? = switch sampleSubject(k) {
            case .show: s.show
            case .film: s.film
            case .none: nil
            }
            return NotifyCandidate(kind: k, key: "sample.\(k.rawValue)",
                                   facts: NotifyWording.sample(k, show: s.show.name, film: s.film.name, file: s.file),
                                   link: about?.link, image: about?.image, reason: "Test, a sample: nothing of yours fits this one yet")
        }
    }

    enum SampleSubject { case show, film, none }

    /// Which title a kind's sample text names (NotifyWording.sample).
    static func sampleSubject(_ k: NotifyKind) -> SampleSubject {
        switch k {
        case .paused, .lateNight, .cliffhanger, .houseplants, .showNearlyDone, .friday, .newEpisode, .newSeason,
             .trendingSeries, .risingFast, .viral, .highlyRatedSeries, .ratingMilestone, .weeklyBriefing, .monthlyRecap, .downloadFinished:
            return .show
        case .filmNearlyDone, .trendingMovie, .forYouPick, .forgotten, .unwatchedClassic, .rediscovery, .topRated, .hiddenGem,
             .lowRatedPopular, .comeback, .freshTitles:
            return .film
        default:
            return .none
        }
    }

    private static func scheduleTest(now: Date) async {
        let center = UNUserNotificationCenter.current()
        let others = await center.pendingNotificationRequests().filter { !$0.identifier.hasPrefix(prefix) }.count
        let room = max(0, 62 - others)
        let list = Array(await testCandidates(now: now).prefix(room))
        let times = NotifyPlanner.testTimes(list.count, from: Date())
        var records: [Scheduled] = []
        for (c, t) in zip(list, times) {
            if let r = await schedule(c, at: t, test: true, requestID: prefix + "test.\(c.kind.rawValue)") { records.append(r); saveScheduled(records) }
        }
        saveScheduled(records)
        dlog("notify", "test: \(records.count) notifications, 20 s apart, from \(list.first?.kind.rawValue ?? "none")")
    }

    struct SampleTitle {
        var name: String
        var image: NotifyImage?
        var link: String?
    }

    /// Titles from your own library and history for Test's samples, each with its own picture and tap.
    private static func samples() async -> (show: SampleTitle, film: SampleTitle, file: String) {
        let index = LibraryMetaIndex.shared
        let files = await ContinueQueue.libraryFiles()
        let groups = LibraryOrganizer.groups(files)
        var show = SampleTitle(name: "Harbor Lights")
        if let e = HistoryStore.shared.continueWatching.first(where: { HistoryStore.episodeNumber($0) != nil }) {
            show = SampleTitle(name: ShowCatalog.name(of: e), image: .history(e.id), link: EngagePlanner.continueLink(e.id))
        } else if let g = groups.first(where: \.isSeries), let f = g.files.first {
            show = SampleTitle(name: index.meta(for: f)?.name ?? g.title, image: .file(f.path), link: LibraryLink.url(f.path))
        }
        var film = SampleTitle(name: "The Quiet Orchard")
        if let g = groups.first(where: { !$0.isSeries }), let f = g.files.first {
            film = SampleTitle(name: index.meta(for: f)?.name ?? g.title, image: .file(f.path), link: LibraryLink.url(f.path))
        }
        // A file Folio really found no title for, else an example name.
        let mystery = index.complete ? LibraryMetaIndex.lookupFiles(files).first { index.meta(for: $0) == nil } : nil
        return (show, film, mystery?.lastPathComponent ?? "VID_20250614_183022.mp4")
    }

    /// Settings → Notifications → Send the next one: the next kind in Test's order, in 5 seconds, shown over Folio too.
    static func sendNext() async -> NotifyKind? {
        let center = UNUserNotificationCenter.current()
        guard [.authorized, .provisional, .ephemeral].contains(await center.notificationSettings().authorizationStatus) else { return nil }
        guard let c = await testCandidates(now: Date()).first else { return nil }
        guard await schedule(c, at: Date().addingTimeInterval(5), test: true, requestID: prefix + "now.\(c.kind.rawValue)") != nil else { return nil }
        let on = testKinds()
        if let i = on.firstIndex(of: c.kind) { UserDefaults.standard.set(on[(i + 1) % on.count].rawValue, forKey: "notifyTestNext") }
        return c.kind
    }

    /// Test switched on or off: the tracker's are held while it's on (Test has their samples), and planned again after.
    static func testChanged() {
        AiringNotifications.reschedule(TrackingStore.shared.shows)
        takeBack()
    }

    // MARK: Pending and sent

    /// The ones due by `now` went out (or would have): kept for the rules,
    /// and their kinds move to their next line. The rest are taken back,
    /// except `keep` (still pending while Folio is open).
    private static func settle(now: Date, keep: [Scheduled]) {
        let scheduled = loadScheduled()
        guard !scheduled.isEmpty else { return }
        let due = scheduled.filter { $0.at <= now }
        let real = due.filter { !$0.test }
        if !real.isEmpty {
            let month = now.addingTimeInterval(-30 * 86400)
            saveSent((loadSent() + real.map { NotifySent(key: $0.key, kind: $0.kind, at: $0.at, showKey: $0.showKey) }).filter { $0.at > month })
            for r in real { _ = bumpVariation(r.kind) }
        }
        let tests = scheduled.filter(\.test).sorted { $0.at < $1.at }
        if !tests.isEmpty {
            let on = testKinds()
            if let last = tests.last(where: { $0.at <= now }), let i = on.firstIndex(of: last.kind) {
                // The run carries on after the last one that came; a whole run done starts again.
                let finished = tests.allSatisfy { $0.at <= now }
                UserDefaults.standard.set(finished ? nil : on[(i + 1) % on.count].rawValue, forKey: "notifyTestNext")
                if finished {
                    // A whole run came (1.28.6): Test turns itself off, so
                    // the real ones are planned again (it started over on
                    // every trip away, and held new-episode alerts).
                    UserDefaults.standard.set(false, forKey: SettingsKey.notifyTest)
                    dlog("notify", "test: the whole run came; Test is off again")
                    AiringNotifications.reschedule(TrackingStore.shared.shows)
                    NotifyPrefsModel.shared.changed()
                }
            }
        }
        let kept = Set(keep.map(\.request))
        let gone = Set(scheduled.filter { $0.at > now && !kept.contains($0.request) }.map(\.request))
        if !gone.isEmpty { removeLog(gone) }
        saveScheduled(keep)
    }

    /// Ours that are pending, but `keeping`. "Tomorrow" and Send the next
    /// one stay unless `asked`: they were asked for.
    private static func removePending(keeping: Set<String> = [], asked: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(prefix) && !keeping.contains($0) && (asked || (!$0.hasPrefix(prefix + "snooze.") && !$0.hasPrefix(prefix + "now."))) }
        if !ours.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ours) }
    }

    private static func loadScheduled() -> [Scheduled] { load("notifyScheduled") ?? [] }
    private static func saveScheduled(_ s: [Scheduled]) { save(s, "notifyScheduled") }
    static func loadSent() -> [NotifySent] { load("notifySent") ?? [] }
    private static func saveSent(_ s: [NotifySent]) { save(s, "notifySent") }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private static func save<T: Encodable>(_ v: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key)
    }

    private static func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Notifications") {
            MainActor.assumeIsolated { endBackgroundTask() }
        }
    }

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Memory: lines and rests

    struct KindMemory: Codable {
        var variation = 0
        var dismissStreak = 0
        var restUntil: Date?
        var opened = 0
        var dismissed = 0
    }

    static var memory: [String: KindMemory] {
        get { load("notifyMemory") ?? [:] }
        set { save(newValue, "notifyMemory") }
    }

    /// The kind's line now, and moves it on.
    static func bumpVariation(_ k: NotifyKind) -> Int {
        var m = memory
        let v = m[k.rawValue]?.variation ?? 0
        m[k.rawValue, default: KindMemory()].variation = v + 1
        memory = m
        return v
    }

    static func resting(_ k: NotifyKind, now: Date = Date()) -> Date? {
        memory[k.rawValue]?.restUntil.flatMap { $0 > now ? $0 : nil }
    }

    static func wake(_ k: NotifyKind) {
        var m = memory
        m[k.rawValue]?.restUntil = nil
        m[k.rawValue]?.dismissStreak = 0
        memory = m
    }

    private static func opened(_ k: NotifyKind) {
        var m = memory
        m[k.rawValue, default: KindMemory()].opened += 1
        m[k.rawValue, default: KindMemory()].dismissStreak = 0
        memory = m
    }

    private static func dismissed(_ k: NotifyKind) {
        var m = memory
        var x = m[k.rawValue] ?? KindMemory()
        x.dismissed += 1
        x.dismissStreak += 1
        if x.dismissStreak >= restAfter {
            x.restUntil = Date().addingTimeInterval(restDays * 86400)
            x.dismissStreak = 0
            dlog("notify", "\(k.rawValue) rests two weeks: dismissed \(restAfter) times in a row")
        }
        m[k.rawValue] = x
        memory = m
    }

    // MARK: The sent list

    struct LogEntry: Codable, Identifiable, Equatable {
        var id: String
        var kind: NotifyKind
        var at: Date
        var title: String?
        var body: String
        var reason: String
        var test: Bool
        var outcome: String?
    }

    private static var logFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("notify-log.json")
    }

    static func log() -> [LogEntry] {
        (try? Data(contentsOf: logFile)).flatMap { try? JSONDecoder().decode([LogEntry].self, from: $0) } ?? []
    }

    private static func writeLog(_ l: [LogEntry]) {
        if let d = try? JSONEncoder().encode(Array(l.suffix(150))) { try? d.write(to: logFile, options: .atomic) }
    }

    static func appendLog(_ e: LogEntry) {
        var l = log()
        l.removeAll { $0.id == e.id && $0.at > Date() }
        l.append(e)
        writeLog(l)
    }

    private static func removeLog(_ ids: Set<String>) {
        let now = Date()
        writeLog(log().filter { !(ids.contains($0.id) && $0.at > now) })
    }

    private static func markLog(_ id: String, _ outcome: String) {
        var l = log()
        if let i = l.lastIndex(where: { $0.id == id }) { l[i].outcome = outcome }
        writeLog(l)
    }

    static func clearLog() { writeLog([]) }

    // MARK: Taps and buttons

    static func registerCategories() {
        let play = UNNotificationAction(identifier: "play", title: "Play", options: [.foreground])
        let tomorrow = UNNotificationAction(identifier: "tomorrow", title: "Tomorrow", options: [])
        let fewer = UNNotificationAction(identifier: "fewer", title: "Fewer Like This", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: categoryPlay, actions: [play, tomorrow, fewer], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: categoryPlain, actions: [tomorrow, fewer], intentIdentifiers: [], options: [.customDismissAction]),
        ])
    }

    /// A tap or a button on one of these; false when it isn't one.
    static func handle(_ r: UNNotificationResponse) -> Bool {
        let req = r.notification.request
        let info = req.content.userInfo
        guard let raw = info["notify"] as? String, let kind = NotifyKind(rawValue: raw) else { return false }
        switch r.actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            if info["test"] == nil { dismissed(kind) }
            markLog(req.identifier, "Dismissed")
        case "tomorrow":
            // Not in the kids profile (1.30.4): one delivered before it came
            // on was planned again, grown-up title and all.
            guard !KidsProfile.isOnNow else {
                markLog(req.identifier, "Not again tomorrow: kids profile")
                return true
            }
            let c = (req.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
            c.attachments = []
            let again = UNNotificationRequest(identifier: prefix + "snooze." + UUID().uuidString, content: c,
                                              trigger: UNTimeIntervalNotificationTrigger(timeInterval: 86400, repeats: false))
            UNUserNotificationCenter.current().add(again)
            markLog(req.identifier, "Again tomorrow")
        case "fewer":
            NotifyPrefs.setKind(kind, on: false)
            NotifyPrefsModel.shared.changed()
            markLog(req.identifier, "Turned off: Fewer like this")
            dlog("notify", "\(kind.rawValue) turned off from a notification")
        default:
            if info["test"] == nil { opened(kind) }
            markLog(req.identifier, "Opened")
            if let link = info["link"] as? String { open(link) }
        }
        return true
    }

    /// folio://continue plays the entry as Home's card does (with &next=1 the
    /// episode after it); a title, a library title or a tracked show opens
    /// its page. Handled here, inside Folio (1.25.1: handing folio:// back to
    /// iOS made it ask "Open in “Folio”?" while Folio was already open).
    static func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        guard !KidsProfile.isOnNow else {
            dlog("notify", "kids profile: notification not opened")
            return
        }
        Task { @MainActor in
            // Tapped while Folio was closed: its window comes a moment later.
            var waited = 0
            while waited < 30, !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            switch url.host?.lowercased() {
            case "continue": break
            case "title": openTitle(url); return
            case "libtitle": openLibraryTitle(url); return
            case "track": TrackingPresenter.open(TrackLink.id(from: url)); return
            default:
                dlog("notify", "notification link opens Folio only: \(url.host ?? "none")")
                return
            }
            guard let id = ContinueLink.id(from: url) else { return }
            // A next-episode card is there once the libraries are read (1.30.4: a cold launch).
            guard let entry = await HistoryStore.shared.continueEntry(for: id) else {
                dlog("notify", "notification for an entry that's no longer in the history")
                return
            }
            if ContinueLink.wantsNext(url) {
                let (queue, index) = await ContinueQueue.build(entry.item)
                if index + 1 < queue.count {
                    PlayerPresenter.play(queue: queue, index: index + 1, fromStart: true)
                    return
                }
            }
            ContinueQueue.play(entry.item)
        }
    }

    /// folio://title?id=tt…: the title's page (trending, picks).
    static func openTitle(_ url: URL) {
        guard let m = TitleLink.meta(from: url) else { return }
        HandoffPresenter.present(AnyView(MetaDetailView(preview: m, sourceAddon: nil)))
    }

    /// folio://libtitle?path=…: the library title's page.
    static func openLibraryTitle(_ url: URL) {
        guard let raw = LibraryLink.path(from: url) else { return }
        // Media and the library's own files only (1.30.4): any path in the app's container was opened.
        let library = Set(LocalMediaStore.shared.files.map { $0.standardizedFileURL.path })
        guard let path = LibraryLink.allowed(raw, media: MPVFiles.mediaDir.path, library: library) else {
            dlog("open", "folio://libtitle for a file outside the library: not opened")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            dlog("open", "folio://libtitle for a file that's gone")
            return
        }
        HandoffPresenter.present(AnyView(TitleHeroView(file: URL(fileURLWithPath: path))))
    }

    /// Shown over Folio too: Test's, the lab's, and (1.28.5) the ones left
    /// pending while it's open, which would otherwise come unseen.
    nonisolated static func showsOverApp(_ n: UNNotification) -> Bool {
        let id = n.request.identifier
        if id.hasPrefix(prefix + "test.") || id.hasPrefix(prefix + "now.") || (lab && id.hasPrefix(prefix)) { return true }
        guard id.hasPrefix(prefix), let raw = n.request.content.userInfo["notify"] as? String else { return false }
        return NotifyKind(rawValue: raw)?.keptWhileOpen == true
    }

    // MARK: The essential ones' wording

    /// The tracker's "is out" in your personality (nil: its plain wording).
    nonisolated static func airingWording(show: String, episode: AiringEpisode, tone: NotifyTone, variation: Int) -> (title: String, body: String)? {
        let premiere = episode.number == 1 && (episode.season ?? 0) >= 2
        let what = episode.number == nil && episode.season == nil ? "A new episode of \(show)" : "\(show) \(episode.label)"
        let facts = ["what": what, "show": show, "season": episode.season.map(String.init) ?? ""]
        guard let t = NotifyWording.text(premiere ? .newSeason : .newEpisode, tone, facts, variation: variation), let title = t.title else { return nil }
        return (title, t.body)
    }

    // MARK: Lab

    /// `-labEngage` (simulator): every kind's sample, three seconds apart.
    static func runLab() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let list = await testCandidates(now: Date())
        for (i, c) in list.enumerated() {
            await schedule(c, at: Date().addingTimeInterval(TimeInterval(3 + i * 3)), test: true, requestID: prefix + "lab.\(i)")
        }
        dlog("notify", "lab: \(list.count) samples, 3 s apart")
    }
}
