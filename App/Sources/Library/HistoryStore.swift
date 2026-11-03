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
    /// Over 92% watched, or less than 90 s left (the end credits) of anything
    /// 10 minutes or longer. Until 1.20.2 the 90 s rule held for any length,
    /// so a clip shorter than 90 s counted as watched before it began.
    var isFinished: Bool {
        watched == true || duration > 0 && (position / duration > 0.92 || duration >= 600 && duration - position < 90)
    }
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
        // The widget's copy of Continue Watching follows these entries (1.20.3, FolioIntents.swift).
        ContinueSnapshotWriter.watch(self)
    }

    /// One card per show: the most recently watched resumable episode of each.
    /// Library files are also matched by file name, so a reinstall (new
    /// container path) never makes a second card for the same file.
    var continueWatching: [HistoryEntry] {
        if let c = index.continueWatching { return c }
        let c = Self.pickContinueWatching(entries)
        lookup?.continueWatching = c
        return c
    }

    /// Groups history entries that belong to the same show (or the same file).
    /// One card per show: the episode furthest along in the show (latest
    /// season, then episode), not the one played last; the show itself is
    /// placed by its latest play. Playing an older season from the library
    /// used to replace the newer one you were watching from Real-Debrid
    /// (4 Nov report). Films and unnumbered files: the one played last.
    static func pickContinueWatching(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var best: [String: (entry: HistoryEntry, latest: Date)] = [:]
        for e in entries where e.canResume {
            let k = showKey(e)
            guard let cur = best[k] else { best[k] = (e, e.updated); continue }
            best[k] = (furtherAlong(e, than: cur.entry) ? e : cur.entry, max(cur.latest, e.updated))
        }
        return best.values.sorted { $0.latest > $1.latest }.map(\.entry)
    }

    private static func furtherAlong(_ a: HistoryEntry, than b: HistoryEntry) -> Bool {
        if let x = episodeNumber(a), let y = episodeNumber(b), x != y { return x > y }
        return a.updated > b.updated
    }

    /// (season, episode): an addon item's from its id ("tt…:3:2"), a file's from its name.
    static func episodeNumber(_ e: HistoryEntry) -> EpisodeNumber? {
        if let ref = e.item.addonRef {
            let id = ref.split(separator: "|", omittingEmptySubsequences: false).dropFirst(2).first ?? ""
            let parts = id.split(separator: ":")
            if parts.count >= 3, let s = Int(parts[parts.count - 2]), let ep = Int(parts[parts.count - 1]) { return EpisodeNumber(season: s, episode: ep) }
        }
        let raw = (e.item.url as NSString).lastPathComponent
        let p = TitleParser.parse(raw.removingPercentEncoding ?? raw)
        guard let ep = p.episode else { return nil }
        return EpisodeNumber(season: p.season ?? 1, episode: ep)
    }

    struct EpisodeNumber: Comparable {
        let season: Int, episode: Int
        static func < (a: Self, b: Self) -> Bool { (a.season, a.episode) < (b.season, b.episode) }
    }

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

    /// The item as history keeps it: WebDAV credentials live in the Keychain
    /// and are added back at play time.
    private static func stored(_ item: MediaItem) -> MediaItem {
        var stored = item
        if case .webdav = item.source { stored.headers.removeValue(forKey: "Authorization") }
        return stored
    }

    func record(_ item: MediaItem, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite else { return }
        let entry = HistoryEntry(item: Self.stored(item), position: position, duration: duration, updated: Date())
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

    /// Library files that were deleted (files, or everything in a deleted
    /// folder): their entries go. Their Continue Watching cards stayed and
    /// failed to play (review, 2 Nov). By path only, never by name: a file
    /// of the same name elsewhere keeps its progress.
    func forget(deleted urls: [URL]) {
        let gone = urls.map { $0.standardizedFileURL.path }
        let before = entries.count
        entries.removeAll { e in
            guard case .local = e.item.source else { return false }
            let p = URL(fileURLWithPath: e.item.historyKey ?? e.item.url).standardizedFileURL.path
            return gone.contains { p == $0 || p.hasPrefix($0 + "/") }
        }
        if entries.count != before {
            dlog("history", "forgot \(before - entries.count) entr\(before - entries.count == 1 ? "y" : "ies") of deleted files")
            scheduleSave()
        }
    }

    func markWatched(_ entry: HistoryEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].position = entries[i].duration
        entries[i].watched = true
        scheduleSave()
    }

    /// Library files, played or not.
    func isWatched(_ file: URL) -> Bool { isWatched(key: file.path) }

    /// Any item by its history key (a library file's path, a WebDAV file's URL).
    func isWatched(key: String) -> Bool { entry(forURL: key)?.isFinished == true }

    func setWatched(_ files: [URL], _ watched: Bool) {
        setWatched(files.map(\.path), watched, item: Self.libraryItem)
    }

    /// Marks items watched (finished, also when never played) or unwatched
    /// (their entry goes: no progress, no resume point). `item` makes the
    /// history item for a key that has no entry yet.
    func setWatched(_ keys: [String], _ watched: Bool, item: (String) -> MediaItem) {
        for key in keys {
            if let e = entry(forURL: key), let i = entries.firstIndex(where: { $0.id == e.id }) {
                if watched {
                    entries[i].watched = true
                    entries[i].position = entries[i].duration
                    entries[i].updated = Date()
                } else {
                    entries.remove(at: i)
                }
            } else if watched {
                entries.append(HistoryEntry(item: Self.stored(item(key)), position: 0, duration: 0, updated: Date(), watched: true))
            }
        }
        scheduleSave()
    }

    /// A library file as a history item.
    static func libraryItem(_ path: String) -> MediaItem {
        let name = (path as NSString).lastPathComponent
        var m = MediaItem(url: path, title: TitleParser.clean(name), source: .local)
        m.historyKey = path
        return m
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
