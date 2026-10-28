import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: String { item.id }
    var item: MediaItem
    var position: Double
    var duration: Double
    var updated: Date
    /// Marked as watched by hand (1.17.0), also for files never played (no
    /// duration known). Optional so older history files still load.
    var watched: Bool?

    var progress: Double { watched == true ? 1 : duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var isFinished: Bool { watched == true || duration > 0 && (position / duration > 0.92 || duration - position < 90) }
    var canResume: Bool { position > 15 && !isFinished }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// Not @Published: changes are announced by hand so the player's position
    /// saves (every few seconds) don't re-render the library while it plays.
    private(set) var entries: [HistoryEntry] = [] {
        willSet { if deferPublishing { changedWhileDeferred = true } else { objectWillChange.send() } }
        didSet { lookup = nil }
    }

    /// Where each entry is, by URL, id and (library files) file name, and the
    /// Continue Watching list: built once after a change, not per question.
    ///
    /// 28 Oct: every lookup went through the whole history, twice for a
    /// library file with no entry — and a title page asks hundreds of times
    /// while it's built (its highlighted episode, each row's progress and
    /// watched mark, Home's rows). Your phone's log, MobLand's page from tap
    /// to built: 6 ms on 1.14, 96 ms on 1.16.1 (the highlight follows the
    /// episode watched last since 1.15.0), ~300 ms since 1.17.0 (watched
    /// marks); the simulator's profile had this lookup on top.
    private struct Lookup {
        var byKey: [String: Int] = [:]          // item.url or id → first entry with it
        var byID: [String: Int] = [:]           // id → first entry with it
        var byMediaName: [String: Int] = [:]    // a library file's name → first library entry with it
        var continueWatching: [HistoryEntry]?
    }
    private var lookup: Lookup?

    private var index: Lookup {
        if let l = lookup { return l }
        var l = Lookup()
        for (i, e) in entries.enumerated() {
            if l.byKey[e.item.url] == nil { l.byKey[e.item.url] = i }
            if l.byKey[e.id] == nil { l.byKey[e.id] = i }
            if l.byID[e.id] == nil { l.byID[e.id] = i }
            if Self.isLibraryFile(e.item.url) {
                let name = (e.item.url as NSString).lastPathComponent
                if l.byMediaName[name] == nil { l.byMediaName[name] = i }
            }
        }
        lookup = l
        return l
    }
    /// True while the player is open; the library catches up when it closes.
    var deferPublishing = false {
        didSet {
            if !deferPublishing && changedWhileDeferred { changedWhileDeferred = false; objectWillChange.send() }
        }
    }
    private var changedWhileDeferred = false
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    /// One card per show: the most recently watched resumable episode of each.
    /// Library files are also matched by file name, so a reinstall (new
    /// container path) never makes a second card for the same file.
    var continueWatching: [HistoryEntry] {
        if let c = index.continueWatching { return c }
        var seen = Set<String>()
        let c = entries.filter { $0.canResume }
            .sorted { $0.updated > $1.updated }
            .filter { seen.insert(Self.showKey($0)).inserted }
        lookup?.continueWatching = c
        return c
    }

    /// Groups history entries that belong to the same show (or the same file).
    static func showKey(_ e: HistoryEntry) -> String {
        if let ref = e.item.addonRef {
            let parts = ref.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 2 { return "a|" + parts[1] }
        }
        let raw = (e.item.url as NSString).lastPathComponent
        let name = raw.removingPercentEncoding ?? raw
        let p = TitleParser.parse(name)
        if p.episode != nil, !p.title.isEmpty { return "s|" + p.title.lowercased() }
        if let t = e.item.anime?.title, !t.isEmpty { return "s|" + t.lowercased() }
        if e.item.url.contains("/Documents/Media/") { return "f|" + name }
        return "i|" + e.id
    }

    var recent: [HistoryEntry] { entries.sorted { $0.updated > $1.updated } }

    func entry(for key: String) -> HistoryEntry? {
        index.byID[key].map { entries[$0] }
    }

    /// The first entry whose URL or id is `url`; for a library file, else the
    /// first library entry with its file name (library files keep their
    /// progress across a reinstall, which changes the container path).
    func entry(forURL url: String) -> HistoryEntry? {
        let l = index
        if let i = l.byKey[url] { return entries[i] }
        guard Self.isLibraryFile(url) else { return nil }
        return l.byMediaName[(url as NSString).lastPathComponent].map { entries[$0] }
    }

    /// A file in the library's folder. NSString's own search: a URL's path
    /// is an NSString underneath, and String.contains went through
    /// Foundation's generic Swift search on it, character by character (the
    /// same profile: two thirds of the time left in these lookups).
    private static func isLibraryFile(_ path: String) -> Bool {
        (path as NSString).range(of: "/Documents/Media/").location != NSNotFound
    }

    func record(_ item: MediaItem, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite else { return }
        var stored = item
        if case .webdav = item.source {
            // Credentials live in the Keychain; re-added at play time.
            stored.headers.removeValue(forKey: "Authorization")
        }
        let entry = HistoryEntry(item: stored, position: position, duration: duration, updated: Date())
        if let i = entries.firstIndex(where: { $0.id == item.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        if entries.count > 500 {
            entries = Array(entries.sorted { $0.updated > $1.updated }.prefix(500))
        }
        scheduleSave()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func markWatched(_ entry: HistoryEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].position = entries[i].duration
        entries[i].watched = true
        scheduleSave()
    }

    /// Library files, played or not.
    func isWatched(_ file: URL) -> Bool { entry(forURL: file.path)?.isFinished == true }

    func setWatched(_ files: [URL], _ watched: Bool) {
        for f in files {
            if let e = entry(forURL: f.path), let i = entries.firstIndex(where: { $0.id == e.id }) {
                if watched {
                    entries[i].watched = true
                    entries[i].position = entries[i].duration
                    entries[i].updated = Date()
                } else {
                    entries.remove(at: i)            // unwatched: no progress, no resume point
                }
            } else if watched {
                var m = MediaItem(url: f.path, title: TitleParser.clean(f.lastPathComponent), source: .local)
                m.historyKey = f.path
                entries.append(HistoryEntry(item: m, position: 0, duration: 0, updated: Date(), watched: true))
            }
        }
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries
        let url = fileURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flush() {
        saveWork?.perform()
        saveWork = nil
    }
}
