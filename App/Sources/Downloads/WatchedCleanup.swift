import Combine
import Foundation
import UIKit

/// "Delete watched downloads" (Settings → Downloads, 1.22.0): a file Folio
/// downloaded whose history entry is finished leaves the library a day or
/// a week after it was finished (the entry's last update).
/// LocalMediaStore.delete takes its history entry and saved frames with it.
///
/// Never a file you added yourself (only DownloadLedger's files and the
/// download list's finished ones), never one not finished, and never while
/// the player is open. Checked at launch, on coming back to the screen, and
/// when the history changes.
@MainActor
enum WatchedCleanup {
    private static var subscription: AnyCancellable?
    private static var pending: DispatchWorkItem?
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        // The history announces once when the player closes (deferPublishing).
        subscription = HistoryStore.shared.objectWillChange
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { WatchedCleanup.run() } }
        DownloadLedger.prune()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WatchedCleanup.schedule() }
        }
        schedule()
    }

    /// A few seconds on: launch and coming back have more pressing work.
    static func schedule() {
        pending?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { WatchedCleanup.run() } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    static func run(now: Date = Date()) {
        let days = UserDefaults.standard.integer(forKey: SettingsKey.downloadDeleteWatched)
        guard days > 0 else { return }
        // What's playing may be one of them.
        guard !HistoryStore.shared.deferPublishing else { return }
        var downloads = DownloadLedger.all
        for d in DownloadManager.shared.items where d.state == .done {
            if let rel = MediaPath.relative(d.destination.path) { downloads.insert(rel) }
        }
        guard !downloads.isEmpty else { return }
        let entries = libraryEntries(HistoryStore.shared.entries)
        let delay = TimeInterval(days) * 86_400
        let due = downloads.filter { isDue(entries[$0], now: now, delay: delay) }
        guard !due.isEmpty else { return }
        // Their subtitles came with them (DownloadButton, Download all): they go too.
        let subtitles = downloads.filter { sub in
            TitleParser.isSubtitle(sub) && due.contains { video in
                (sub as NSString).deletingLastPathComponent == (video as NSString).deletingLastPathComponent
                    && SubtitleMatch.belongs((sub as NSString).lastPathComponent, to: (video as NSString).lastPathComponent)
            }
        }
        let media = MPVFiles.mediaDir
        let gone = due.union(subtitles)
        let urls = gone.map { media.appendingPathComponent($0) }
        Task {
            // Checked off the main thread: the ledger can be long.
            let existing = await Task.detached(priority: .utility) { urls.filter { FileManager.default.fileExists(atPath: $0.path) } }.value
            guard !existing.isEmpty, UserDefaults.standard.integer(forKey: SettingsKey.downloadDeleteWatched) > 0,
                  !HistoryStore.shared.deferPublishing else { return }
            dlog("downloads", "deleting \(due.count) watched download(s), finished over \(days) day(s) ago")
            LocalMediaStore.shared.delete(existing)
            DownloadLedger.remove(gone)
        }
    }

    // MARK: Rules

    /// Asked first (1.30.4): turned on, or made shorter (7 days to 1), it
    /// deletes files at once. Until then only turning it on asked.
    nonisolated static func asksBeforeDeleting(old: Int, new: Int) -> Bool {
        new > 0 && (old <= 0 || new < old)
    }

    /// A download whose entry is finished, finished at least `delay` ago.
    nonisolated static func isDue(_ entry: HistoryEntry?, now: Date, delay: TimeInterval) -> Bool {
        guard delay > 0, let entry, entry.isFinished else { return false }
        return now.timeIntervalSince(entry.updated) >= delay
    }

    /// Library entries by their Media path. By path, never by name alone
    /// (HistoryStore.entry(forURL:) falls back to the name): two shows'
    /// "Episode 1.mkv" are different files. Two entries for one file: the newer.
    nonisolated static func libraryEntries(_ entries: [HistoryEntry]) -> [String: HistoryEntry] {
        var out: [String: HistoryEntry] = [:]
        for e in entries {
            guard case .local = e.item.source, let rel = MediaPath.relative(e.item.historyKey ?? e.item.url) else { continue }
            if let old = out[rel], old.updated >= e.updated { continue }
            out[rel] = e
        }
        return out
    }
}

/// A library file's path inside Media ("Show/Episode 1.mkv"). It stays the
/// same when a reinstall moves the app's container, which changes every
/// absolute path.
enum MediaPath {
    static func relative(_ path: String) -> String? {
        var p = path
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        let ns = p as NSString
        let r = ns.range(of: "/Documents/Media/")
        guard r.location != NSNotFound else { return nil }
        let rest = ns.substring(from: r.location + r.length)
        return rest.isEmpty ? nil : rest
    }
}

/// The library files Folio downloaded (1.22.0), by Media path: the only
/// files "Delete watched downloads" may delete. Kept apart from the
/// download list, which Clear finished empties.
@MainActor
enum DownloadLedger {
    private static var paths: Set<String> = load()
    private static var saveWork: DispatchWorkItem?

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("downloaded-files.json")
    }

    static var all: Set<String> { paths }

    static func add(_ url: URL) {
        guard let rel = MediaPath.relative(url.path), paths.insert(rel).inserted else { return }
        save()
    }

    static func remove(_ rels: Set<String>) {
        let before = paths.count
        paths.subtract(rels)
        if paths.count != before { save() }
    }

    /// Forgets files that are gone (deleted from the library or in Files),
    /// checked off the main thread: a file you add later at the same place
    /// isn't taken for Folio's.
    static func prune() {
        let list = paths, media = MPVFiles.mediaDir
        guard !list.isEmpty else { return }
        Task {
            let missing = await Task.detached(priority: .utility) {
                Set(list.filter { !FileManager.default.fileExists(atPath: media.appendingPathComponent($0).path) })
            }.value
            if !missing.isEmpty { remove(missing) }
        }
    }

    private static func load() -> Set<String> {
        guard let d = try? Data(contentsOf: file), let list = JSONDecoder().decodeLossy(String.self, from: d) else { return [] }
        return Set(list)
    }

    private static func save() {
        saveWork?.cancel()
        let snapshot = paths.sorted(), url = file
        let w = DispatchWorkItem { if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) } }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: w)
    }
}
