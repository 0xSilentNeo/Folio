import Foundation
import UIKit
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
    /// A Continue Watching card for the episode after a finished one
    /// (1.30.4): the finished episode's history id. Such a card is made by
    /// pickContinueWatching and never saved.
    var follows: String?

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
        didSet { lookup = nil; version &+= 1 }
    }

    /// Goes up with every change to the entries: what's worked out from
    /// them can be kept until it moves (Home's tiles, 1.28.2).
    private(set) var version = 0

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
        var byLibrary: [String: Int] = [:]      // a library file's path inside Media → its entry (1.23.2)
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
            if let rel = Self.libraryRelative(e.id) ?? Self.libraryRelative(e.item.url) {
                if let j = l.byLibrary[rel], !Self.better(e, than: entries[j]) { continue }
                l.byLibrary[rel] = i
            }
        }
        lookup = l
        return l
    }
    /// True while the player is open; the library catches up when it closes.
    var deferPublishing = false {
        didSet {
            if !deferPublishing && changedWhileDeferred { changedWhileDeferred = false; objectWillChange.send() }
            if !deferPublishing && deferredSave != nil { flush() }     // the player's last positions, now
        }
    }
    private var changedWhileDeferred = false
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        // 1.28.6: a file that doesn't read whole is read entry by entry and a
        // copy is set aside, where the history started empty and the next
        // save wrote over the only copy. A file that reads is copied once a
        // day (history.backup.json).
        var read: [HistoryEntry]?
        if let data = try? Data(contentsOf: fileURL) {
            let dir = fileURL.deletingLastPathComponent()
            if let whole = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
                read = whole
                let backup = dir.appendingPathComponent("history.backup.json")
                let age = (try? backup.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
                if !whole.isEmpty, (age ?? .infinity) > 86400 {
                    DispatchQueue.global(qos: .utility).async { try? data.write(to: backup, options: .atomic) }
                }
            } else {
                let some = JSONDecoder().decodeLossy(HistoryEntry.self, from: data)
                read = some
                let aside = dir.appendingPathComponent("history.unreadable.json")
                try? data.write(to: aside, options: .atomic)
                dlog("history/error", "history.json didn't read whole (\(data.count) bytes): \(some.map { "\($0.count) entr(ies) kept" } ?? "none readable"); a copy is in \(aside.lastPathComponent)")
                // Nothing readable (a file cut short, 1.28.7): yesterday's copy,
                // where 1.28.6 still started empty.
                if (some ?? []).isEmpty, let old = try? Data(contentsOf: dir.appendingPathComponent("history.backup.json")),
                   let saved = try? JSONDecoder().decode([HistoryEntry].self, from: old), !saved.isEmpty {
                    read = saved
                    dlog("history/error", "history restored from the daily backup: \(saved.count) entr(ies)")
                }
            }
        }
        if let decoded = read {
            let r = Self.rebased(decoded, mediaDir: MPVFiles.mediaDir.path)
            entries = r.entries
            if r.moved > 0 || r.merged > 0 {
                dlog("history", "library files: \(r.moved) entr(ies) moved to this install's folder, \(r.merged) duplicate(s) merged")
                DispatchQueue.main.async { [weak self] in self?.scheduleSave() }
            }
        }
        // The widget's copy of Continue Watching follows these entries (1.20.3, FolioIntents.swift).
        ContinueSnapshotWriter.watch(self)
        // What waits for its 30 s write (scheduleSave) is written as Folio leaves the screen.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HistoryStore.shared.flush() }
        }
    }

    /// One card per show: the most recently watched resumable episode of
    /// each, or the episode after a finished one (pickContinueWatching).
    /// Library files are also matched by file name, so a reinstall (new
    /// container path) never makes a second card for the same file.
    var continueWatching: [HistoryEntry] {
        if let c = index.continueWatching { return c }
        watchNextSources()
        let c = Self.pickContinueWatching(entries, now: Date(), dismissed: dismissed) { ContinueNext.after($0) }
        lookup?.continueWatching = c
        return c
    }

    /// The finished episodes that can bring their show's next episode to
    /// Continue Watching (1.30.4): those played in the last 60 days, so an
    /// update doesn't fill the row with every show ever started.
    static let nextUpWindow: TimeInterval = 60 * 86400

    /// Without next episodes: the resumable ones only, as until 1.30.3.
    static func pickContinueWatching(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        pickContinueWatching(entries, now: Date(), dismissed: [:]) { _ in [] }
    }

    /// Groups history entries that belong to the same show (or the same file).
    /// One card per show: the episode furthest along in the show (latest
    /// season, then episode), not the one played last; the show itself is
    /// placed by its latest play. Playing an older season from the library
    /// used to replace the newer one you were watching from Real-Debrid
    /// (4 Nov report). Films and unnumbered files: the one played last.
    ///
    /// 1.30.4: a show whose last play was a finished episode gets a card
    /// for the episode after it (`next`: the episodes after an entry, in
    /// order, from its own source), unless one further along has a place to
    /// resume. Only resumable entries were ever cards, so a show watched to
    /// the end of an episode left the row: Tulsa King, E02-E07 from
    /// Real-Debrid, E07 closed in its credits (14 Nov report). An IMDb
    /// addon's episodes and the files of the same show are one show (by its
    /// name); when the source played last has no next episode, the show's
    /// other sources are asked. `dismissed`: shows taken off the row with
    /// Remove (continueShow's key → when), until they're played again.
    static func pickContinueWatching(_ entries: [HistoryEntry], now: Date, dismissed: [String: Double],
                                     next: (HistoryEntry) -> [MediaItem]) -> [HistoryEntry] {
        struct Show {
            var resume: Seen?               // furthest along with a place to resume
            var last: Seen?                 // played last
            var finished: [Seen] = []       // finished lately
            var latest = Date.distantPast
            var length: (at: Date, seconds: Double)?
        }
        var shows: [String: Show] = [:]
        // Every finished entry, by id, URL and place in Media, when a next
        // episode is looked for: one already watched is passed over.
        var done: Set<String>?
        func isDone(_ m: MediaItem) -> Bool {
            if done == nil {
                var d = Set<String>()
                for e in entries where e.isFinished {
                    d.insert(e.id)
                    d.insert(e.item.url)
                    if let rel = libraryRelative(e.id) { d.insert("lib|" + rel) }
                }
                done = d
            }
            guard let d = done else { return false }
            return d.contains(m.id) || d.contains(m.url) || libraryRelative(m.id).map { d.contains("lib|" + $0) } == true
        }
        for e in entries {
            let resumable = e.canResume
            guard resumable || e.isFinished && now.timeIntervalSince(e.updated) <= nextUpWindow else { continue }
            let show = continueShow(e)
            let seen = Seen(entry: e, number: show.number)
            var s = shows[show.key] ?? Show()
            if resumable {
                if s.resume.map({ furtherAlong(seen, than: $0) }) ?? true { s.resume = seen }
            } else {
                s.finished.append(seen)
            }
            if s.last.map({ playedLater(seen, than: $0) }) ?? true { s.last = seen }
            s.latest = max(s.latest, e.updated)
            if e.duration > 0, s.length.map({ e.updated > $0.at }) ?? true { s.length = (e.updated, e.duration) }
            shows[show.key] = s
        }
        var out: [(entry: HistoryEntry, at: Date)] = []
        for (key, s) in shows {
            if let d = dismissed[key], s.latest.timeIntervalSince1970 <= d { continue }
            if let last = s.last, last.entry.isFinished, let after = last.number {
                let watched = Set(s.finished.compactMap(\.number))
                // The source played last first, then the show's others.
                var tried = Set<String>()
                var found: (item: MediaItem, number: EpisodeNumber)?
                var sources: [Seen] = [last]
                sources += s.finished.sorted { $0.entry.updated > $1.entry.updated }
                if let r = s.resume { sources.append(r) }
                for src in sources {
                    if found != nil || tried.count >= 3 { break }
                    guard tried.insert(sourceKey(src.entry)).inserted else { continue }
                    for m in next(src.entry) {
                        guard let n = episodeNumber(item: m), n > after, !watched.contains(n), !isDone(m) else { continue }
                        found = (m, n)
                        break
                    }
                }
                if let f = found {
                    if let r = s.resume, let rn = r.number, rn >= f.number {
                        out.append((r.entry, s.latest))
                    } else {
                        // Its length isn't known before it plays: the show's last one, for "… left" on the widget.
                        let card = HistoryEntry(item: f.item, position: 0, duration: s.length?.seconds ?? 0,
                                                updated: last.entry.updated, follows: last.entry.id)
                        out.append((card, s.latest))
                    }
                    continue
                }
            }
            if let r = s.resume { out.append((r.entry, s.latest)) }
        }
        return out.sorted { $0.at > $1.at }.map(\.entry)
    }

    /// An entry with its (season, episode), worked out once.
    private struct Seen {
        let entry: HistoryEntry
        let number: EpisodeNumber?
    }

    private static func furtherAlong(_ a: Seen, than b: Seen) -> Bool {
        if let x = a.number, let y = b.number, x != y { return x > y }
        return a.entry.updated > b.entry.updated
    }

    /// The newer; at the same moment (marked watched together), the one further along.
    private static func playedLater(_ a: Seen, than b: Seen) -> Bool {
        if a.entry.updated != b.entry.updated { return a.entry.updated > b.entry.updated }
        if let x = a.number, let y = b.number { return x > y }
        return false
    }

    /// Where an entry plays from, for asking each of a show's sources once.
    private static func sourceKey(_ e: HistoryEntry) -> String {
        switch e.item.source {
        case .local: return "local"
        case .webdav(let id): return "webdav|" + id.uuidString
        case .addon(let name): return "addon|" + name
        case .url: return e.item.remote.map { "server|" + $0.serverID.uuidString } ?? "url"
        }
    }

    /// The show an entry belongs to in Continue Watching, and its (season,
    /// episode). An episode is its show's by name (letters and digits, as
    /// NextEpisodes matches files), so an IMDb addon's episodes and the
    /// files of the same show are one card (1.30.4: Tulsa King from an
    /// addon on 13 Nov and from Real-Debrid on 14 Nov were two shows).
    /// Anything else: showKey's.
    static func continueShow(_ e: HistoryEntry) -> (key: String, number: EpisodeNumber?) {
        let number = episodeNumber(e)
        if let ref = e.item.addonRef {
            let parts = ref.split(separator: "|", omittingEmptySubsequences: false)
            if number != nil, parts.count >= 3, parts[0] != "movie", parts[1].hasPrefix("tt") {
                let k = NextEpisodes.showKey(e.item.title)
                if !k.isEmpty { return ("n|" + k, number) }
            }
            return (showKey(e), number)
        }
        let raw = (e.item.url as NSString).lastPathComponent
        let p = TitleParser.parse(raw.removingPercentEncoding ?? raw)
        let title = p.episode != nil && !p.title.isEmpty ? p.title : e.item.anime?.title ?? ""
        let k = NextEpisodes.showKey(title)
        return (k.isEmpty ? showKey(e) : "n|" + k, number)
    }

    /// (season, episode): an addon item's from its id ("tt…:3:2"), a file's from its name.
    static func episodeNumber(_ e: HistoryEntry) -> EpisodeNumber? { episodeNumber(item: e.item) }

    static func episodeNumber(item: MediaItem) -> EpisodeNumber? {
        if let ref = item.addonRef {
            let id = ref.split(separator: "|", omittingEmptySubsequences: false).dropFirst(2).first ?? ""
            let parts = id.split(separator: ":")
            if parts.count >= 3, let s = Int(parts[parts.count - 2]), let ep = Int(parts[parts.count - 1]) { return EpisodeNumber(season: s, episode: ep) }
        }
        let raw = (item.url as NSString).lastPathComponent
        let p = TitleParser.parse(raw.removingPercentEncoding ?? raw)
        guard let ep = p.episode else { return nil }
        return EpisodeNumber(season: p.season ?? 1, episode: ep)
    }

    struct EpisodeNumber: Comparable, Hashable {
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

    /// The entry the player resumes from. A library file is also found by
    /// its place inside Media (1.23.2), as the pages find it: the player
    /// looked only for the exact path, which a reinstall changes, so a page
    /// said "Resume from 12:53" and the file started at 0 (5 Nov log, 19:09:47).
    func entry(for key: String) -> HistoryEntry? {
        let l = index
        if let i = l.byID[key] { return entries[i] }
        if let rel = Self.libraryRelative(key), let i = l.byLibrary[rel] { return entries[i] }
        // A next-episode card has no entry (1.30.4): the widget's and the
        // notifications' links (folio://continue?id=) find it here. Never
        // for an addon key: the title pages ask by those whether one exists.
        if !key.hasPrefix("addon:"), let c = continueWatching.first(where: { $0.follows != nil && $0.id == key }) { return c }
        return nil
    }

    /// What a widget's or a notification's link plays (1.30.4): an entry,
    /// or a next-episode card, which needs the library's files and the
    /// servers' saved libraries, not yet read when the link opened Folio.
    func continueEntry(for id: String) async -> HistoryEntry? {
        if let e = entry(for: id) { return e }
        guard !id.hasPrefix("addon:") else { return nil }
        await ContinueNext.prepare(entries)
        nextSourcesChanged()
        return entry(for: id)
    }

    /// The first entry whose URL or id is `url`; for a library file, else the
    /// entry of the file at the same place inside Media. Until 1.23.2 that was
    /// any library entry with the same file name, so "A/01.mkv" showed
    /// "B/01.mkv"'s progress (review, 2 Nov).
    func entry(forURL url: String) -> HistoryEntry? {
        let l = index
        if let i = l.byKey[url] { return entries[i] }
        guard let rel = Self.libraryRelative(url) else { return nil }
        return l.byLibrary[rel].map { entries[$0] }
    }

    // MARK: Library files across installs (1.23.2)

    /// A library file's path inside Documents/Media: the same after a
    /// reinstall or a sideloaded update (each moves the app's container:
    /// …/DFBF5E79…/Documents/Media/ became …/986B236C…/ when 1.23.0 went on
    /// in the 5 Nov log), and whether the path was written "/private/var/…"
    /// or "/var/…" (both forms are in that log for the same episode).
    nonisolated static func libraryRelative(_ path: String) -> String? {
        let ns = path as NSString
        let r = ns.range(of: "/Documents/Media/")
        guard r.location != NSNotFound else { return nil }
        let rel = ns.substring(from: r.location + r.length)
        return rel.isEmpty ? nil : rel
    }

    /// Of two entries for the same file, the one that says more: one with a
    /// place to resume or finished, then the newer.
    nonisolated static func better(_ a: HistoryEntry, than b: HistoryEntry) -> Bool {
        let am = a.isFinished || a.canResume, bm = b.isFinished || b.canResume
        if am != bm { return am }
        return a.updated > b.updated
    }

    /// Library entries moved to this install's Media folder, and two for one
    /// file made one.
    nonisolated static func rebased(_ list: [HistoryEntry], mediaDir: String) -> (entries: [HistoryEntry], moved: Int, merged: Int) {
        let base = mediaDir.hasSuffix("/") ? mediaDir : mediaDir + "/"
        var out: [HistoryEntry] = []
        var at: [String: Int] = [:]
        var moved = 0, merged = 0
        for var e in list {
            guard let rel = libraryRelative(e.id) ?? libraryRelative(e.item.url) else { out.append(e); continue }
            let path = base + rel
            var changed = false
            if libraryRelative(e.item.url) != nil, e.item.url != path { e.item.url = path; changed = true }
            if let k = e.item.historyKey, libraryRelative(k) != nil, k != path { e.item.historyKey = path; changed = true }
            if changed { moved += 1 }
            if let j = at[rel] {
                merged += 1
                if better(e, than: out[j]) { out[j] = e }
                continue
            }
            at[rel] = out.count
            out.append(e)
        }
        return (out, moved, merged)
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
        // (Whatever the header's case, 1.30.2.)
        if case .webdav = item.source { stored.headers = stored.headers.filter { $0.key.lowercased() != "authorization" } }
        return stored
    }

    /// A look into an entry that was marked watched keeps the mark
    /// (1.30.2): playing a watched episode again replaced the whole entry,
    /// and five seconds in it read as unwatched. Only a look, though: past
    /// the first minute (or 5% of it) it is being watched again, and its
    /// place decides as before, so it can be resumed.
    nonisolated static func carryingWatched(_ new: HistoryEntry, from old: HistoryEntry) -> HistoryEntry {
        guard old.watched == true, !new.isFinished, new.position < max(60, new.duration * 0.05) else { return new }
        var e = new
        e.watched = true
        return e
    }

    func record(_ item: MediaItem, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite else { return }
        let entry = HistoryEntry(item: Self.stored(item), position: position, duration: duration, updated: Date())
        if let i = entries.firstIndex(where: { $0.id == item.id }) {
            entries[i] = Self.carryingWatched(entry, from: entries[i])
        } else if let rel = Self.libraryRelative(item.id), let i = entries.firstIndex(where: { Self.libraryRelative($0.id) == rel }) {
            entries[i] = Self.carryingWatched(entry, from: entries[i])          // the same library file under another path (1.23.2)
        } else {
            entries.append(entry)
            trim()                      // only a new entry can take it over a cap
        }
        scheduleSave()
    }

    /// At most 500 entries in progress and 5,000 watched marks (1.26.0).
    /// The 500 most recent of all used to be kept, so marking a long show
    /// watched, or 500 plays later, silently unmarked older episodes: a
    /// watched mark lives only here (review, 9 Nov).
    private static let openCap = 500
    private static let watchedCap = 5000

    private func trim() {
        guard entries.count > Self.openCap else { return }
        var open = 0, done = 0
        let kept = entries.sorted { $0.updated > $1.updated }.filter { e in
            if e.isFinished { done += 1; return done <= Self.watchedCap }
            open += 1
            return open <= Self.openCap
        }
        if kept.count != entries.count { entries = kept }
    }

    func remove(_ entry: HistoryEntry) {
        // A next-episode card has no entry to remove (1.30.4): its show goes.
        guard entry.follows == nil else { dismiss(entry); return }
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    /// Home's Remove (1.30.4): the card's entry goes, and its show stays off
    /// the row until it's played again. Removing only the entry brought the
    /// next episode's card, or an older episode's, in its place.
    func removeFromContinueWatching(_ entry: HistoryEntry) {
        dismiss(entry)
        if entry.follows == nil { remove(entry) }
    }

    private static let dismissedKey = "continueDismissed"

    /// Shows taken off Continue Watching (continueShow's key → when).
    private lazy var dismissed: [String: Double] = UserDefaults.standard.dictionary(forKey: HistoryStore.dismissedKey) as? [String: Double] ?? [:]

    private func dismiss(_ entry: HistoryEntry) {
        var d = dismissed
        // A next-episode card: by the episode it follows, whose show it's in.
        let shown = entry.follows.flatMap { id in entries.first { $0.id == id } } ?? entry
        d[Self.continueShow(shown).key] = Date().timeIntervalSince1970
        // The 300 latest: one dropped can only bring back a card nothing played since.
        if d.count > 300 {
            for (k, _) in d.sorted(by: { $0.value < $1.value }).prefix(d.count - 300) { d[k] = nil }
        }
        dismissed = d
        UserDefaults.standard.set(d, forKey: Self.dismissedKey)
        lookup?.continueWatching = nil
        if deferPublishing { changedWhileDeferred = true } else { objectWillChange.send() }
    }

    // MARK: Next episodes' sources (1.30.4)

    private var nextWatch: [AnyCancellable] = []

    /// Next-episode cards come from the library's files and the servers'
    /// saved libraries too: worked out again when those change. A listing
    /// of the library also lets entries of files gone from it go, and a
    /// finished download takes its stream's place.
    private func watchNextSources() {
        guard nextWatch.isEmpty else { return }
        nextWatch = [
            LocalMediaStore.shared.$files
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { files in MainActor.assumeIsolated {
                    HistoryStore.shared.forgetMissingLibraryFiles(files)
                    HistoryStore.shared.nextSourcesChanged()
                } },
            LibraryIndexStore.shared.objectWillChange
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { _ in MainActor.assumeIsolated { HistoryStore.shared.nextSourcesChanged() } },
            // Throttled, not debounced: progress changes the list all through a download.
            DownloadManager.shared.$items
                .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
                .receive(on: DispatchQueue.main)        // never inside the read that subscribed
                .sink { items in MainActor.assumeIsolated { HistoryStore.shared.carryToDownloads(items) } },
        ]
    }

    /// Library files deleted or moved in the Files app (1.30.4): their
    /// entries go after a listing of the library, as forget(deleted:) does
    /// for Folio's own Delete. Their cards stayed and failed to play. Only
    /// files in Media (never one opened from elsewhere), each checked on
    /// disk off the main thread (the listing goes two folders deep), and
    /// only from a listing that found files, never in the background (a
    /// locked phone's files may not be readable).
    private func forgetMissingLibraryFiles(_ files: [URL]) {
        guard !files.isEmpty, UIApplication.shared.applicationState != .background else { return }
        let listed = Set(files.compactMap { Self.libraryRelative($0.path) })
        var unlisted = Set<String>()
        for e in entries {
            guard case .local = e.item.source, let rel = Self.libraryRelative(e.item.historyKey ?? e.item.url), !listed.contains(rel) else { continue }
            unlisted.insert(rel)
        }
        guard !unlisted.isEmpty else { return }
        let media = MPVFiles.mediaDir, names = unlisted
        Task {
            let gone = await Task.detached(priority: .utility) {
                names.filter { !FileManager.default.fileExists(atPath: media.appendingPathComponent($0).path) }
            }.value
            guard !gone.isEmpty, UIApplication.shared.applicationState != .background else { return }
            let before = self.entries.count
            self.entries.removeAll { e in
                guard case .local = e.item.source, let rel = Self.libraryRelative(e.item.historyKey ?? e.item.url) else { return false }
                return gone.contains(rel)
            }
            guard self.entries.count != before else { return }
            dlog("history", "forgot \(before - self.entries.count) entr\(before - self.entries.count == 1 ? "y" : "ies") of library files no longer there")
            self.scheduleSave()
        }
    }

    /// Downloads already looked at this launch.
    private var carried = Set<UUID>()

    /// A stream's place carried to its downloaded copy (1.30.4): the
    /// library file started at 0:00 and Continue Watching kept streaming.
    /// Only a place to resume, never a watched mark ("Delete watched
    /// downloads" would take the new file), and only into a copy with no
    /// entry of its own. Saved a second after the stream's, so the copy is
    /// the card (the newer of one episode's two).
    private func carryToDownloads(_ items: [DownloadItem]) {
        var added = 0
        for d in items where d.state == .done {
            guard carried.insert(d.id).inserted else { continue }
            let dest = d.destination.path
            guard Self.libraryRelative(dest) != nil, entry(forURL: dest) == nil,
                  let origin = entry(forURL: d.url.absoluteString), origin.canResume,
                  FileManager.default.fileExists(atPath: dest) else { continue }
            if case .local = origin.item.source { continue }
            var item = Self.libraryItem(dest)
            let p = TitleParser.parse(d.destination.lastPathComponent)
            if p.episode != nil { item.anime = AnimeHint(title: p.title, episode: p.episode) }
            entries.append(HistoryEntry(item: item, position: origin.position, duration: origin.duration, updated: origin.updated.addingTimeInterval(1)))
            added += 1
        }
        guard added > 0 else { return }
        dlog("history", "\(added) download(s) take their stream's place")
        trim()
        scheduleSave()
    }

    /// Continue Watching worked out again; the pages (and the widget) are
    /// told only when that changed it.
    func nextSourcesChanged() {
        guard let old = lookup?.continueWatching else { return }
        lookup?.continueWatching = nil
        guard continueWatching != old else { return }
        if deferPublishing { changedWhileDeferred = true } else { objectWillChange.send() }
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

    /// Home's Mark as watched (1.30.4): the card's episode, and its show's
    /// other episodes in progress (before it: the card is the one furthest
    /// along), so none of them takes its place; the next one does.
    func markWatchedFromContinueWatching(_ entry: HistoryEntry) {
        let show = Self.continueShow(entry).key
        var keys = [entry.item.id]
        for e in entries where e.canResume && e.id != entry.id && Self.continueShow(e).key == show { keys.append(e.id) }
        setWatched(keys, true) { _ in entry.item }
    }

    func markWatched(_ entry: HistoryEntry) {
        // A next-episode card (1.30.4): its episode gets an entry, watched.
        if entry.follows != nil {
            setWatched([entry.item.id], true) { _ in entry.item }
            return
        }
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
    ///
    /// 1.28.2: every key is looked up first, then the list changes once.
    /// Each change cleared the lookup index, so the next key rebuilt it from
    /// the whole history, and each one announced a change: marking a long
    /// show watched hitched.
    func setWatched(_ keys: [String], _ watched: Bool, item: (String) -> MediaItem) {
        let found = keys.map { (key: $0, id: entry(forURL: $0)?.id) }
        var list = entries
        var at: [HistoryEntry.ID: Int] = [:]
        for (i, e) in list.enumerated() where at[e.id] == nil { at[e.id] = i }
        var gone = Set<HistoryEntry.ID>(), added = Set<String>()
        let now = Date()
        for (key, id) in found {
            if let id, let i = at[id] {
                if watched {
                    list[i].watched = true
                    list[i].position = list[i].duration
                    list[i].updated = now
                } else {
                    gone.insert(id)
                }
            } else if watched, added.insert(key).inserted {
                list.append(HistoryEntry(item: Self.stored(item(key)), position: 0, duration: 0, updated: now, watched: true))
            }
        }
        if !gone.isEmpty { list.removeAll { gone.contains($0.id) } }
        entries = list
        trim()
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

    /// Saves one at a time, in order (1.25.0: on the global queue two could
    /// run at once and an older list could be written last).
    private static let saveQueue = DispatchQueue(label: "dev.silentneo.folio.history-save", qos: .utility)

    private static func write(_ list: [HistoryEntry], to url: URL) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// While the player is up (deferPublishing) the file is written at most
    /// every 30 s, not 0.5 s after each change (1.26.1): the player records
    /// its position every 5 s, and each save encoded and rewrote the whole
    /// history, ~1,400 times through a two-hour film. The 30 s write takes
    /// the entries as they are then; leaving the app and closing the player
    /// (flush) write at once.
    private func scheduleSave() {
        if deferPublishing {
            guard deferredSave == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.deferredSave != nil else { return }
                    self.deferredSave = nil
                    self.writeSoon()
                }
            }
            deferredSave = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
            return
        }
        writeSoon()
    }

    private var deferredSave: DispatchWorkItem?

    private func writeSoon() {
        saveWork?.cancel()
        let snapshot = entries
        let url = fileURL
        let work = DispatchWorkItem { Self.write(snapshot, to: url) }
        saveWork = work
        Self.saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The pending save now. Off the main thread (1.25.0: closing the player
    /// encoded and wrote up to 500 entries on it), except when the app is
    /// about to end (`wait`).
    func flush(wait: Bool = false) {
        let deferred = deferredSave != nil
        deferredSave?.cancel()
        deferredSave = nil
        guard saveWork != nil || deferred else { return }
        saveWork?.cancel()
        saveWork = nil
        let snapshot = entries
        let url = fileURL
        if wait {
            Self.saveQueue.sync { Self.write(snapshot, to: url) }
        } else {
            Self.saveQueue.async { Self.write(snapshot, to: url) }
        }
    }
}
