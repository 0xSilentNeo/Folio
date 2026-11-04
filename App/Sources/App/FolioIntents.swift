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
            MainActor.assumeIsolated { writeInBackground() }
        }
        // The first snapshot after an install or an update, before anything
        // changes. On the next turn of the main loop: this runs while
        // HistoryStore.shared is still being made.
        DispatchQueue.main.async { MainActor.assumeIsolated { schedule() } }
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
        guard let dir = ContinueSnapshot.directory(create: true) else {
            if !toldNoGroup {
                toldNoGroup = true
                dlog("widget", "\(FolioGroup.status): the widget shows Open Folio")
            }
            return
        }
        if !toldGroup {
            toldGroup = true
            dlog("widget", FolioGroup.status)
        }
        // The kids profile shows an empty widget: Continue Watching is grown-up history.
        let entries = KidsProfile.isOnNow ? [] : Array(HistoryStore.shared.continueWatching.prefix(ContinueSnapshot.limit))
        var items: [ContinueSnapshot.Item] = []
        for e in entries {
            let meta = await meta(for: e.item)
            var item = item(for: e, meta: meta)
            item.picture = await picture(for: e, meta: meta, in: dir)
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
            sweep(dir, keeping: Set(items.compactMap(\.picture)))
            WidgetCenter.shared.reloadAllTimelines()
            dlog("widget", "snapshot: \(items.count) item(s), \(items.filter { $0.picture != nil }.count) with a picture")
        }
        updateShortcuts()
    }

    /// One widget row: what Home's card shows for the entry.
    static func item(for e: HistoryEntry, meta: MediaMeta?) -> ContinueSnapshot.Item {
        // A film's line is its synopsis: the widget shows one line of it.
        let line = HeroCard.line(e.item, meta: meta).map { $0.count > 200 ? String($0.prefix(200)) : $0 }
        return ContinueSnapshot.Item(id: e.id, title: meta?.name ?? e.item.displayTitle, line: line,
                                     progress: e.progress, remaining: max(0, e.duration - e.position))
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
    private static func picture(for e: HistoryEntry, meta: MediaMeta?, in dir: URL) async -> String? {
        let base = hash(e.id)
        let frame = ThumbnailStore.url(for: e.id)
        if let saved = (try? frame.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            let name = "\(base)-\(Int(saved.timeIntervalSince1970)).jpg"
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
            return await Task.detached(priority: .utility) { () -> String? in
                guard let data = try? Data(contentsOf: frame),
                      let img = ImageCache.downsample(data, maxPixel: ContinueSnapshot.picturePixels) else { return nil }
                return save(img, name, in: dir)
            }.value
        }
        let art = e.item.addonRef == nil ? (meta?.wideArt ?? e.item.artwork) : e.item.artwork
        guard let art, let url = URL(string: art) else { return nil }
        let name = "\(base)-\(hash(art)).jpg"
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        // ImageCache: from its disk copy when Home has shown the art before.
        guard let img = await ImageCache.shared.image(url, maxPixel: ContinueSnapshot.picturePixels) else { return nil }
        return await Task.detached(priority: .utility) { save(img, name, in: dir) }.value
    }

    nonisolated private static func save(_ img: UIImage, _ name: String, in dir: URL) -> String? {
        guard let jpeg = img.jpegData(compressionQuality: 0.8),
              (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }

    /// Pictures no entry uses any more.
    static func sweep(_ dir: URL, keeping: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasSuffix(".jpg") && !keeping.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
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
}

/// What Siri says when an intent can't play anything. On success an intent
/// says nothing: a spoken answer kept Siri's orb and its card up over the
/// player, and over a full-screen video it often couldn't be swiped away
/// (it took leaving the app). The player opening is the answer.
enum FolioIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingToContinue
    case showGone(String)
    case kidsProfile

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .kidsProfile: return "Folio is in the kids profile. Open Folio to choose something."
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
    }
}
