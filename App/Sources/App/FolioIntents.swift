import AppIntents
import Combine
import CryptoKit
import UIKit
import WidgetKit

// Continue Watching outside the app (1.20.3 (2 Nov)): the Home Screen
// widget, Siri and Shortcuts. All three play an entry the way Home's
// Continue Watching card does (ContinueQueue.play).

// MARK: - Widget snapshot

/// Copies the top of Continue Watching into the App Group's container for
/// the widget (ContinueSnapshot), with a small picture for each entry.
///
/// Written a moment after the history settles, not on each change: while the
/// player is open the history changes every few seconds but announces
/// nothing (HistoryStore.deferPublishing), and it announces once when the
/// player closes. Going to the background also writes, so a show left
/// playing in Picture in Picture has its progress on the widget.
@MainActor
enum ContinueSnapshotWriter {
    private static var subscription: AnyCancellable?
    private static var running: Task<Void, Never>?
    /// What's in the container now: an unchanged snapshot isn't written
    /// again, nor the widget reloaded (WidgetKit limits reloads).
    private static var written: ContinueSnapshot?
    private static var shortcutShows: [String]?
    private static var toldNoGroup = false
    private static var toldGroup = false

    static func watch(_ store: HistoryStore) {
        guard subscription == nil else { return }
        subscription = store.objectWillChange
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { schedule() } }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            // Not for a glance at Notification Centre (AwayWork, 1.28.2):
            // each write reloads the widgets, which wakes their extension.
            MainActor.assumeIsolated { AwayWork.onLeaving("Continue Watching widget") { writeInBackground() } }
        }
        // The first snapshot after an install or an update, before anything
        // changes. On the next turn of the main loop: this runs while
        // HistoryStore.shared is still being made.
        DispatchQueue.main.async { MainActor.assumeIsolated {
            schedule()
            // The 1.24.0 widgets' files.
            GlanceWriter.start()
        } }
    }

    static func schedule() {
        running?.cancel()
        running = Task { await write() }
    }

    /// iOS gives an app a few seconds after it leaves the screen; asked for
    /// explicitly so the pictures can be finished.
    private static func writeInBackground() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Continue Watching widget") {
            MainActor.assumeIsolated { endBackgroundTask() }
        }
        running?.cancel()
        running = Task {
            await write()
            endBackgroundTask()
        }
    }

    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static func write() async {
        // Siri's show names don't need the widget's files (they were never
        // updated without an App Group: review, 5 Nov).
        defer { updateShortcuts() }
        guard let dir = WidgetStore.continueWatching(create: true) else {
            if !toldNoGroup {
                toldNoGroup = true
                dlog("widget", "\(FolioGroup.status), and no Keychain group to share either (team \(KeychainShare.team ?? "unknown")): the widget shows Open Folio")
            }
            return
        }
        if !toldGroup {
            toldGroup = true
            if dir.isKeychain {
                let seen = KeychainShare.lastSeen()
                dlog("widget", "\(FolioGroup.status): the widgets' files go in the default Keychain group, here \(KeychainShare.defaultGroup ?? "?") (the profile's Keychain groups: \(KeychainShare.profileKeychainGroups.joined(separator: ", ")))"
                     + "; the widget last read them: \(seen ?? "never"); the Resume control: \(KeychainShare.lastControlDrawn() ?? "never drawn")")
            } else {
                dlog("widget", FolioGroup.status)
            }
        }
        // The kids profile shows an empty widget: Continue Watching is grown-up history.
        let entries = KidsProfile.isOnNow ? [] : Array(HistoryStore.shared.continueWatching.prefix(ContinueSnapshot.limit))
        var items: [ContinueSnapshot.Item] = []
        for e in entries {
            let meta = await meta(for: e.item)
            var item = item(for: e, meta: meta)
            item.picture = await picture(for: e, meta: meta, in: dir)
            item.poster = await poster(for: e, meta: meta, in: dir)
            if item.episode != nil { item.next = await NextUp.label(for: e) }
            guard !Task.isCancelled else { return }
            items.append(item)
        }
        let snapshot = ContinueSnapshot(items: items)
        if written == nil { written = ContinueSnapshot.read(from: dir) }
        if snapshot != written {
            do { try snapshot.write(to: dir) } catch {
                dlog("widget", "snapshot not written: \(error.localizedDescription)")
                return
            }
            written = snapshot
            sweep(dir, keeping: Set(items.flatMap { [$0.picture, $0.poster] }.compactMap { $0 }))
            for kind in WidgetKind.continueKinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
            dlog("widget", "snapshot: \(items.count) item(s), \(items.filter { $0.picture != nil }.count) with a picture\(dir.isKeychain ? " (Keychain)" : "")")
        }
    }

    /// One widget row: what Home's card shows for the entry.
    static func item(for e: HistoryEntry, meta: MediaMeta?) -> ContinueSnapshot.Item {
        // A film's line is its synopsis: the widget shows one line of it.
        let line = HeroCard.line(e.item, meta: meta).map { $0.count > 200 ? String($0.prefix(200)) : $0 }
        let parts = HeroCard.parts(e.item, meta: meta)
        // An episode's title is its show's (1.24.0): the widgets show the
        // episode's number and title on their own lines.
        let title = meta?.name ?? (parts.number != nil ? ShowCatalog.name(of: e) : e.item.displayTitle)
        var item = ContinueSnapshot.Item(id: e.id, title: title, line: line,
                                         progress: e.progress, remaining: max(0, e.duration - e.position))
        item.episode = parts.number
        item.episodeTitle = parts.title
        item.duration = e.duration > 0 ? e.duration : nil
        if parts.number == nil { item.year = meta?.year ?? TitleParser.parse(e.item.fileName).year.map(String.init) }
        return item
    }

    /// The metadata Home's card has (ThumbLoader): by file name, cached on
    /// disk after the first lookup. None for addon items: their names and
    /// episode labels come with them.
    private static func meta(for item: MediaItem) async -> MediaMeta? {
        guard item.addonRef == nil else { return nil }
        return await MetadataService.shared.lookup(filename: item.resolvedURL?.lastPathComponent ?? item.title)
    }

    /// The picture's file name next to the snapshot: the frame saved when
    /// you stopped watching (ThumbnailStore), else the title's art. Named by
    /// the entry and the picture's version, so a newer frame is a new file,
    /// and so a new snapshot, which reloads the widget.
    private static func picture(for e: HistoryEntry, meta: MediaMeta?, in dir: WidgetStore) async -> String? {
        let base = hash(e.id)
        let frame = ThumbnailStore.url(for: e.id)
        if let saved = (try? frame.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            let name = "\(base)-\(Int(saved.timeIntervalSince1970)).jpg"
            if dir.exists(name) { return name }
            return await Task.detached(priority: .utility) { () -> String? in
                guard let data = try? Data(contentsOf: frame),
                      let img = ImageCache.downsample(data, maxPixel: ContinueSnapshot.picturePixels) else { return nil }
                return save(img, name, in: dir)
            }.value
        }
        let art = e.item.addonRef == nil ? (meta?.wideArt ?? e.item.artwork) : e.item.artwork
        guard let art, let url = URL(string: art) else { return nil }
        let name = "\(base)-\(hash(art)).jpg"
        if dir.exists(name) { return name }
        // ImageCache: from its disk copy when Home has shown the art before.
        guard let img = await ImageCache.shared.image(url, maxPixel: ContinueSnapshot.picturePixels) else { return nil }
        return await Task.detached(priority: .utility) { save(img, name, in: dir) }.value
    }

    /// A portrait poster for the shelf widget (1.24.0): the title's poster
    /// (an addon item's own art is its poster), small: a third of a large
    /// widget's width at 3x.
    private static func poster(for e: HistoryEntry, meta: MediaMeta?, in dir: WidgetStore) async -> String? {
        let art = e.item.addonRef == nil ? meta?.poster : (e.item.artwork ?? meta?.poster)
        guard let art, let url = URL(string: art) else { return nil }
        let name = "\(hash(e.id))-p-\(hash(art)).jpg"
        if dir.exists(name) { return name }
        guard let img = await ImageCache.shared.image(url, maxPixel: posterPixels) else { return nil }
        return await Task.detached(priority: .utility) { save(img, name, in: dir) }.value
    }

    static let posterPixels: CGFloat = 330

    nonisolated private static func save(_ img: UIImage, _ name: String, in dir: WidgetStore) -> String? {
        guard let jpeg = img.jpegData(compressionQuality: 0.8), (try? dir.write(jpeg, name)) != nil else { return nil }
        return name
    }

    /// Pictures no entry uses any more.
    static func sweep(_ dir: URL, keeping: Set<String>) { sweep(.folder(dir), keeping: keeping) }

    static func sweep(_ dir: WidgetStore, keeping: Set<String>) {
        for f in dir.names() where f.hasSuffix(".jpg") && !keeping.contains(f) { dir.remove(f) }
    }

    /// Stable across launches (Swift's hashValue isn't), short enough for a file name.
    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Siri learns the show names for "Play the next episode of <show>"
    /// only when the app says they changed.
    private static func updateShortcuts() {
        let shows = HistoryStore.shared.continueWatching.map(HistoryStore.showKey)
        guard shows != shortcutShows else { return }
        shortcutShows = shows
        FolioShortcuts.updateAppShortcutParameters()
    }
}

// MARK: - Shows

/// A show for Siri and Shortcuts: one per Continue Watching card (a film
/// there counts too), then the library's series. The id is the show's key
/// (HistoryStore.showKey), which for a library series is its group's id.
struct ShowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Show"
    static let defaultQuery = ShowQuery()

    let id: String
    let name: String
    /// The episode it continues with, or how many episodes a series has.
    let detail: String?

    var displayRepresentation: DisplayRepresentation {
        if let detail { return DisplayRepresentation(title: "\(name)", subtitle: "\(detail)") }
        return DisplayRepresentation(title: "\(name)")
    }
}

struct ShowQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ShowEntity] {
        let all = await ShowCatalog.shows()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [ShowEntity] { await ShowCatalog.shows() }

    @MainActor
    func entities(matching string: String) async throws -> [ShowEntity] {
        let q = string.trimmingCharacters(in: .whitespaces)
        return await ShowCatalog.shows().filter { q.isEmpty || $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

@MainActor
enum ShowCatalog {
    static func shows() async -> [ShowEntity] {
        var seen = Set<String>(), out: [ShowEntity] = []
        for e in HistoryStore.shared.continueWatching {
            let key = HistoryStore.showKey(e)
            guard seen.insert(key).inserted else { continue }
            out.append(ShowEntity(id: key, name: name(of: e), detail: HeroCard.line(e.item, meta: nil)))
        }
        for g in LibraryOrganizer.groups(await ContinueQueue.libraryFiles()) where g.isSeries && seen.insert(g.id).inserted {
            out.append(ShowEntity(id: g.id, name: g.title, detail: "\(g.count) episodes"))
        }
        return out
    }

    /// The show's name, not the episode's: an addon item carries it as its
    /// title; a file's comes from its name ("MobLand S01E03…" → MobLand).
    static func name(of e: HistoryEntry) -> String {
        if e.item.addonRef != nil { return e.item.displayTitle }
        let p = TitleParser.parse(e.item.fileName)
        if p.episode != nil, !p.title.isEmpty { return p.title }
        if let t = e.item.anime?.title, !t.isEmpty { return t }
        return e.item.displayTitle
    }

    /// Plays the show's Continue Watching card; for a library series with
    /// none, the episode its title page would highlight (LibraryGroup.nextUp).
    static func play(_ id: String) async -> Bool {
        if let e = HistoryStore.shared.continueWatching.first(where: { HistoryStore.showKey($0) == id }) {
            IntentPlayback.start(e.item)
            return true
        }
        guard let g = LibraryOrganizer.groups(await ContinueQueue.libraryFiles()).first(where: { $0.id == id }) else { return false }
        let f = g.nextUp
        var item = HistoryStore.shared.entry(forURL: f.path)?.item ?? HistoryStore.libraryItem(f.path)
        let p = TitleParser.parse(f.lastPathComponent)
        if item.anime == nil, p.episode != nil { item.anime = AnimeHint(title: p.title, episode: p.episode) }
        IntentPlayback.start(item)
        return true
    }
}

@MainActor
enum IntentPlayback {
    /// An intent that opens Folio runs while Folio is still opening: the
    /// player waits (up to 3 s) for its window, which it's shown over. The
    /// intent itself doesn't wait: Siri closes as soon as the intent ends.
    static func start(_ item: MediaItem) {
        Task { @MainActor in
            var waited = 0
            while waited < 30, !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            ContinueQueue.play(item)
        }
    }

    /// A link (Play URL in Folio, Play in Folio), once Folio is on screen.
    static func play(_ link: String) {
        Task { @MainActor in
            var waited = 0
            while waited < 30, !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            PlayerPresenter.play(MediaItem(url: link, title: "", source: .url))
        }
    }
}

/// What Siri says when an intent can't play anything. On success an intent
/// says nothing: a spoken answer kept Siri's orb and its card up over the
/// player, and over a full-screen video it often couldn't be swiped away
/// (it took leaving the app). The player opening is the answer.
enum FolioIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingToContinue
    case showGone(String)
    case kidsProfile
    case notPlayable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .kidsProfile: return "Folio is in the kids profile. Open Folio to choose something."
        case .notPlayable: return "Folio plays links to video streams: http, https, rtsp, rtmp, smb, sftp or ftp."
        case .nothingToContinue: return "There's nothing to continue in Folio."
        case .showGone(let name): return "\(name) isn't in Folio's Continue Watching or library any more."
        }
    }
}

// MARK: - Intents

struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description: IntentDescription? = IntentDescription("Resumes what you watched last in Folio, as its Continue Watching row does.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !KidsProfile.isOnNow else { throw FolioIntentError.kidsProfile }
        guard let e = HistoryStore.shared.continueWatching.first else { throw FolioIntentError.nothingToContinue }
        dlog("intents", "continue watching: \(ShowCatalog.name(of: e))")
        IntentPlayback.start(e.item)
        return .result()
    }
}

struct PlayNextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Next Episode"
    static let description: IntentDescription? = IntentDescription("Plays a show's next episode in Folio, from where you left off.")
    static let openAppWhenRun = true

    @Parameter(title: "Show", requestValueDialog: "Which show?")
    var show: ShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play the next episode of \(\.$show)")
    }

    init() {}
    init(show: ShowEntity) { self.show = show }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !KidsProfile.isOnNow else { throw FolioIntentError.kidsProfile }
        guard await ShowCatalog.play(show.id) else { throw FolioIntentError.showGone(show.name) }
        dlog("intents", "next episode of \(show.name)")
        return .result()
    }
}

// MARK: - Airing (1.21.0)

/// A show you track (TrackingStore), for "When's the next episode of <show>?".
struct TrackedShowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tracked Show"
    static let defaultQuery = TrackedShowQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TrackedShowQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TrackedShowEntity] {
        await TrackingStore.shared.whenLoaded()
        return identifiers.compactMap { id in TrackingStore.shared.show(id: id).map(Self.entity) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TrackedShowEntity] {
        await TrackingStore.shared.whenLoaded()
        return TrackingStore.shared.shows.map(Self.entity)
    }

    @MainActor
    func entities(matching string: String) async throws -> [TrackedShowEntity] {
        await TrackingStore.shared.whenLoaded()
        let q = string.trimmingCharacters(in: .whitespaces)
        return TrackingStore.shared.shows
            .filter { q.isEmpty || $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(Self.entity)
    }

    private static func entity(_ s: TrackedShow) -> TrackedShowEntity { TrackedShowEntity(id: s.id, name: s.name) }
}

/// Answers out loud and stays where you are: nothing to open, so Folio isn't
/// brought to the front.
struct NextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "When's the Next Episode"
    static let description: IntentDescription? = IntentDescription("Says when the next episode of a show you track in Folio airs, in your time zone.")
    static let openAppWhenRun = false

    @Parameter(title: "Show", requestValueDialog: "Which show?")
    var show: TrackedShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("When's the next episode of \(\.$show)?")
    }

    init() {}
    init(show: TrackedShowEntity) { self.show = show }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TrackingStore.shared
        await store.whenLoaded()
        guard let s = store.show(id: show.id) else {
            return .result(dialog: "\(show.name) isn't tracked in Folio any more.")
        }
        // An old schedule is fetched again first, for up to 5 s (Siri doesn't wait long).
        if s.updated.map({ Date().timeIntervalSince($0) > TrackingStore.staleAge }) ?? true {
            Task { await store.refresh(only: [s.id], reason: "Siri") }
            var waited = 0
            repeat {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            } while store.refreshing && waited < 50
        }
        let answer = AiringFormat.spoken(store.show(id: s.id) ?? s)
        dlog("intents", "next episode of \(s.name): \(answer)")
        return .result(dialog: "\(answer)")
    }
}

/// Play URL in Folio (1.27.0): for Shortcuts, the Action Button, and a
/// shortcut shown in the share sheet. Plays at once: you set it up.
struct PlayURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Play URL in Folio"
    static let description: IntentDescription? = IntentDescription("Plays a link to a video stream in Folio's player.")
    static let openAppWhenRun = true

    @Parameter(title: "URL", requestValueDialog: "Which link?")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$url) in Folio")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !KidsProfile.isOnNow else { throw FolioIntentError.kidsProfile }
        guard SharedPlayLink.isPlayable(url) else { throw FolioIntentError.notPlayable }
        dlog("intents", "play URL: \(url.scheme ?? "?")://\(url.host ?? "")")
        IntentPlayback.play(url.absoluteString)
        return .result()
    }
}

struct FolioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueWatchingIntent(), phrases: [
            "Continue watching in \(.applicationName)",
            "Continue watching on \(.applicationName)",
            "Resume \(.applicationName)",
        ], shortTitle: "Continue Watching", systemImageName: "play.rectangle.fill")
        AppShortcut(intent: PlayNextEpisodeIntent(), phrases: [
            "Play the next episode of \(\.$show) in \(.applicationName)",
            "Play the next episode of \(\.$show) on \(.applicationName)",
            "Continue \(\.$show) in \(.applicationName)",
            "Play the next episode in \(.applicationName)",
        ], shortTitle: "Play Next Episode", systemImageName: "forward.end.fill")
        AppShortcut(intent: NextEpisodeIntent(), phrases: [
            "When's the next episode of \(\.$show) in \(.applicationName)",
            "When's the next episode of \(\.$show) on \(.applicationName)",
            "When does \(\.$show) air in \(.applicationName)",
            "When's the next episode in \(.applicationName)",
        ], shortTitle: "Next Episode", systemImageName: "bell")
        AppShortcut(intent: PlayURLIntent(), phrases: [
            "Play a link in \(.applicationName)",
            "Play a URL in \(.applicationName)",
        ], shortTitle: "Play URL", systemImageName: "link")
    }
}

// MARK: - The Resume intent's hook

/// What the Resume intent does in Folio, set as the app starts (1.28.6:
/// it was set a turn of the main loop after the history was first read, so
/// an intent run on a cold start found nothing to call).
@MainActor
enum ResumeSetup {
    static func start() {
        ResumeHook.run = {
            guard !KidsProfile.isOnNow, let e = HistoryStore.shared.continueWatching.first else {
                dlog("intents", "Resume: nothing to continue\(KidsProfile.isOnNow ? " (kids profile)" : "")")
                return
            }
            dlog("intents", "Resume: \(ShowCatalog.name(of: e))")
            IntentPlayback.start(e.item)
        }
        ResumeHook.tapped = { dlog("intents", "Resume control: its intent ran in Folio") }
        // Every widget and control drawn anew once a launch: free while
        // Folio is in front, and the way out of any state they were stuck in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            // Only in front (1.28.7): a launch in the background (a
            // download, the airing refresh) would spend the widgets' budget.
            guard UIApplication.shared.applicationState == .active else { return }
            WidgetCenter.shared.reloadAllTimelines()
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
        }
    }
}
