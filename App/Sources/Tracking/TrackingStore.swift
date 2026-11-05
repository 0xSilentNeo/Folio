import Foundation

/// The shows you track, saved as tracking.json in Application Support.
///
/// Read and written on a queue of its own (JSON off the main thread), one
/// entry at a time (decodeLossy): an entry this version can't read is
/// skipped, not the whole list. After every change the notifications are
/// planned again, the Airing widget's snapshot is written and Siri learns
/// the names.
@MainActor
final class TrackingStore: ObservableObject {
    static let shared = TrackingStore()

    @Published private(set) var shows: [TrackedShow] = []
    /// A refresh is running (the Tracking screen's spinner).
    @Published private(set) var refreshing = false

    /// A schedule older than this is fetched again when the app comes to the front.
    nonisolated static let staleAge: TimeInterval = 6 * 3600

    private let file: URL
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var shortcutNames: [String]?
    /// Saving happens in order on this queue; the first thing on it is the load.
    private static let io = DispatchQueue(label: "dev.silentneo.folio.tracking", qos: .utility)

    private init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tracking.json")
        let file = file
        loadTask = Task {
            let loaded = await withCheckedContinuation { c in Self.io.async { c.resume(returning: Self.read(file)) } }
            self.finishLoading(loaded)
        }
    }

    /// Waits for the saved list (a background launch refreshes right away).
    func whenLoaded() async { await loadTask?.value }

    func show(id: String) -> TrackedShow? { shows.first { $0.id == id } }

    /// The tracked show this page's show is, if it's tracked (any id in common).
    func tracked(like candidate: TrackedShow) -> TrackedShow? { shows.first { $0.isSameShow(as: candidate) } }

    // MARK: Tracking

    func track(_ candidate: TrackedShow) {
        guard tracked(like: candidate) == nil else { return }
        var s = candidate
        s.added = Date()
        shows.append(s)
        dlog("tracking", "tracking \(s.name) (\(s.id), \(s.anime == true ? "anime" : "series"))")
        changed()
        AiringNotifications.askPermissionIfNeeded()
        Task { await refresh(only: [s.id], reason: "tracked") }
    }

    func untrack(_ id: String) {
        guard let i = shows.firstIndex(where: { $0.id == id }) else { return }
        dlog("tracking", "stopped tracking \(shows[i].name)")
        shows.remove(at: i)
        changed()
    }

    /// The Track button.
    func toggle(_ candidate: TrackedShow) {
        if let s = tracked(like: candidate) { untrack(s.id) } else { track(candidate) }
    }

    /// A title page found the series has ended (1.22.6): the tracked show
    /// learns it, and stops being tracked when nothing more will air.
    func seriesEnded(like candidate: TrackedShow) {
        guard let i = shows.firstIndex(where: { $0.isSameShow(as: candidate) }), shows[i].seriesEnded != true else { return }
        shows[i].seriesEnded = true
        let id = shows[i].id
        dlog("tracking", "\(shows[i].name): the series has ended")
        dropOver(reason: "its title page")
        // Its schedule may be a sequel's (another series): asked again.
        if shows.contains(where: { $0.id == id }) { Task { await refresh(only: [id], reason: "series ended") } }
    }

    /// Stops tracking the shows with nothing more to air (TrackedShow.isOver).
    private func dropOver(reason: String) {
        let now = Date()
        let over = shows.filter { $0.isOver(at: now) }
        guard !over.isEmpty else { changed(); return }
        for s in over { dlog("tracking", "stopped tracking \(s.name): it has ended and nothing more will air (\(reason))") }
        shows.removeAll { $0.isOver(at: now) }
        changed()
    }

    // MARK: Refresh

    /// Fetches the schedules older than `maxAge` (all with `force`; just
    /// `only` when given), one show at a time. A show whose source can't be
    /// reached keeps what it had, and is asked again next time.
    func refresh(force: Bool = false, maxAge: TimeInterval = TrackingStore.staleAge, only ids: Set<String>? = nil, reason: String) async {
        await whenLoaded()
        while let running = refreshTask {
            await running.value
            // That run may not have had these: go on only for what was asked for by name or forced.
            if !force && ids == nil { return }
        }
        let now = Date()
        let due = shows.filter { s in
            if let ids { return ids.contains(s.id) }
            return force || s.updated.map { now.timeIntervalSince($0) > maxAge } ?? true
        }
        guard !due.isEmpty else { return }
        let task = Task {
            await run(due, reason: reason)
            refreshTask = nil
            refreshing = false
        }
        refreshTask = task
        refreshing = true
        // A background refresh that runs out of time cancels its caller: stop between shows.
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func run(_ due: [TrackedShow], reason: String) async {
        dlog("tracking", "refreshing \(due.count) show(s) (\(reason))")
        var found = 0, missing = 0, failed = 0
        for var s in due {
            guard !Task.isCancelled else { break }
            // Shows tracked before 1.22.6 don't know whether the series has
            // ended: IMDb's details say so. From the cache a title page left,
            // else asked (1.23.0: until then only a cached page counted, so
            // Dragon Ball tracked from the library kept Beerus's dates).
            if s.seriesEnded == nil, let imdb = s.imdb {
                var ended = IMDbSource.cachedDetails(id: imdb)?.hasEnded == true
                if !ended, let d = await IMDbSource.details(id: imdb, type: "series") { ended = d.hasEnded }
                if ended {
                    s.seriesEnded = true
                    if let i = shows.firstIndex(where: { $0.id == s.id }) { shows[i].seriesEnded = true }
                }
            }
            // An ended series' AniList entry, learned from a fetch (its id is
            // the IMDb one), may be a sequel that's another series: until
            // 1.22.6 Dragon Ball kept Dragon Ball Super: Beerus's. Looked up
            // again by name, without following sequels.
            var repaired = false
            if s.seriesEnded == true, s.imdb != nil, s.source == .anilist {
                s.anilist = nil; s.mal = nil; s.source = nil
                repaired = true
            }
            let outcome = await AiringService.shared.fetch(s)
            // Stopped tracking while it was asked.
            guard let i = shows.firstIndex(where: { $0.id == s.id }) else { continue }
            if repaired { shows[i].anilist = nil; shows[i].mal = nil; shows[i].source = nil }
            switch outcome {
            case .found(let f):
                shows[i].apply(f, at: Date())
                found += 1
            case .notFound:
                shows[i].markNotFound(at: Date())
                // The other series' episodes it had go with its ids.
                if repaired { shows[i].next = nil; shows[i].later = [] }
                missing += 1
            case .unreachable:
                failed += 1
            }
        }
        dlog("tracking", "refreshed: \(found) found, \(missing) not found, \(failed) not reached\(Task.isCancelled ? " (stopped: out of time)" : "")")
        dropOver(reason: "refresh")
    }

    // MARK: Saving

    private func finishLoading(_ loaded: [TrackedShow]) {
        // Anything tracked in the moment before the file was read stays.
        let extra = shows.filter { s in !loaded.contains { $0.id == s.id } }
        shows = loaded + extra
        dlog("tracking", "\(loaded.count) tracked show(s)")
        changed(save: !extra.isEmpty)
    }

    /// After every change: save, plan the notifications, update the widget and Siri.
    private func changed(save: Bool = true) {
        if save { self.save() }
        AiringNotifications.reschedule(shows)
        AiringSnapshotWriter.schedule(shows)
        AiringBackground.schedule(shows)
        // Siri learns the names for "When's the next episode of <show>?" only when told.
        let names = shows.map(\.name)
        if names != shortcutNames {
            shortcutNames = names
            FolioShortcuts.updateAppShortcutParameters()
        }
    }

    private func save() {
        let list = shows, file = file
        Self.io.async {
            do {
                try JSONEncoder().encode(list).write(to: file, options: .atomic)
            } catch {
                dlog("tracking", "tracking.json not saved: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func read(_ file: URL) -> [TrackedShow] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        if let list = decode(data) { return list }
        // Not a list at all: kept aside rather than overwritten by the next save.
        let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: file, to: aside)
        dlog("tracking", "tracking.json unreadable: moved aside")
        return []
    }

    /// The saved list, skipping entries this version can't read.
    nonisolated static func decode(_ data: Data) -> [TrackedShow]? {
        JSONDecoder().decodeLossy(TrackedShow.self, from: data)
    }
}
