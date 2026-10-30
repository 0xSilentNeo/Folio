import Foundation
import SwiftUI

/// A WebDAV server's library as last listed: every folder under the start
/// folder and the media files in it. One per server, saved in Application
/// Support/LibraryIndex/<server id>.json; Search Library and the Real-Debrid
/// entry on Home read it.
struct LibraryIndex: Codable, Equatable, Sendable {
    /// Bumped when the file's layout changes; an older file is rebuilt.
    static let schemaVersion = 1
    var schema = LibraryIndex.schemaVersion
    /// The account it belongs to (address, user name, start folder). Another
    /// account means another library: the saved one is thrown away.
    var account: String
    /// The start folder's key.
    var root: String
    /// When the last refresh finished.
    var refreshed: Date?
    /// The last time the server was asked, and how it answered.
    var lastCheck: Check?
    var folders: [String: Folder] = [:]

    struct Check: Codable, Equatable, Sendable {
        var date: Date
        var ok: Bool
        var unauthorized: Bool
    }

    struct Folder: Codable, Equatable, Sendable {
        var name: String
        /// As the parent's listing gave them (getetag, getlastmodified).
        var etag: String?
        var modified: Date?
        var added: Date?
        /// When this folder itself was last listed.
        var listed: Date
        var subfolders: [String]
        var files: [File]
    }

    struct File: Codable, Equatable, Hashable, Sendable {
        var url: URL
        var name: String
        var size: Int64?
        var added: Date?
    }

    /// Folders are keyed by their address with one trailing slash.
    static func key(_ url: URL) -> String {
        var s = url.standardized.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        return s
    }

    static func account(_ server: WebDAVServer) -> String {
        [server.baseURL.trimmingCharacters(in: .whitespaces).lowercased(), server.username, server.rootPath].joined(separator: "|")
    }

    /// Every media file, folder by folder from the start folder.
    var allFiles: [File] {
        var out: [File] = []
        var stack = [root]
        var seen = Set<String>()
        while let k = stack.popLast() {
            guard seen.insert(k).inserted, let f = folders[k] else { continue }
            out += f.files
            stack += f.subfolders.reversed()
        }
        return out
    }
}

/// Lists a server's folders into a LibraryIndex, keeping what hasn't changed.
///
/// The rule, each refresh:
/// - The start folder is always listed: additions, removals and renames show
///   up in its listing (and in each listed folder's).
/// - A subfolder is listed again only when its parent's listing shows it new
///   (or renamed), with a different `getetag`, or — without one — a different
///   `getlastmodified`; when its saved listing is older than 24 hours; or on
///   a full refresh (pull to refresh).
/// - Otherwise its saved listing is kept, with everything under it. A folder
///   whose listing fails keeps what was saved for it.
/// - Folders gone from their parent's listing go, with what was under them.
///
/// Why: a debrid service's release folders never change after they're added
/// (a torrent's files are fixed), so an unchanged name and date mean an
/// unchanged folder; RFC 4918 §15.6/§15.7 give getetag and getlastmodified
/// as the properties that change when a resource does. Whether a server's
/// folder dates really change with their contents is checked and logged on
/// each listing (`[index] … contents changed but … didn't`). The 24 hours
/// match the WebDAV browser script's `index_refresh_hours`.
struct LibraryIndexer: Sendable {
    var list: @Sendable (URL) async throws -> [DAVItem]
    /// The WebDAV browser script lists at most 3 folders at once.
    var maxConcurrent = 3
    var maxAge: TimeInterval = 24 * 3600
    var maxDepth = 6
    var maxFolders = 3000

    struct Report: Equatable, Sendable {
        var listed = 0
        var kept = 0
        var failed = 0
        var unauthorized = false
        var rootFailed = false
        /// Folders listed again whose files or subfolders changed although
        /// their getetag / getlastmodified hadn't.
        var changedWithoutSign = 0
        var ms = 0
    }

    private struct Listed: Sendable {
        let url: URL
        let depth: Int
        let items: [DAVItem]?
        let error: String?
        let unauthorized: Bool
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        if case .unauthorized? = error as? WebDAVError { return true }
        return false
    }

    func refresh(_ old: LibraryIndex, rootURL: URL, full: Bool, now: Date = Date(),
                 progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> (LibraryIndex, Report) {
        let start = Date()
        var report = Report()
        var fresh = old
        fresh.root = LibraryIndex.key(rootURL)
        fresh.folders = [:]
        // What the parent's listing said about each folder waiting to be listed.
        var props: [String: (name: String, etag: String?, modified: Date?, added: Date?)] = [:]
        var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
        var seen: Set<String> = [fresh.root]
        let rootFolder = old.folders[fresh.root]
        props[fresh.root] = (rootFolder?.name ?? rootURL.lastPathComponent, rootFolder?.etag, rootFolder?.modified, rootFolder?.added)

        func keep(_ key: String) {
            guard let f = old.folders[key], fresh.folders[key] == nil else { return }
            fresh.folders[key] = f
            report.kept += 1
            for s in f.subfolders where seen.insert(s).inserted || fresh.folders[s] == nil { keep(s) }
        }

        await withTaskGroup(of: Listed.self) { group in
            var running = 0
            while true {
                while running < maxConcurrent, !queue.isEmpty {
                    let next = queue.removeFirst()
                    let list = self.list
                    group.addTask {
                        do { return Listed(url: next.url, depth: next.depth, items: try await list(next.url), error: nil, unauthorized: false) }
                        catch { return Listed(url: next.url, depth: next.depth, items: nil, error: error.localizedDescription,
                                              unauthorized: Self.isUnauthorized(error)) }
                    }
                    running += 1
                }
                guard running > 0, let done = await group.next() else { break }
                running -= 1
                let key = LibraryIndex.key(done.url)
                guard let items = done.items else {
                    report.failed += 1
                    if done.unauthorized { report.unauthorized = true }
                    if key == fresh.root { report.rootFailed = true }
                    LibTrace.index.log("\(done.url.lastPathComponent): listing failed (\(done.error ?? "?")), keeping what was saved")
                    keep(key)
                    progress(report.listed + report.kept, report.listed + report.kept + queue.count + running)
                    continue
                }
                report.listed += 1
                let p = props[key]
                var folder = LibraryIndex.Folder(name: p?.name ?? done.url.lastPathComponent, etag: p?.etag, modified: p?.modified, added: p?.added,
                                                 listed: now, subfolders: [], files: [])
                for item in items {
                    if item.isDirectory {
                        let k = LibraryIndex.key(item.url)
                        guard seen.insert(k).inserted else { continue }
                        folder.subfolders.append(k)
                        guard done.depth + 1 <= maxDepth, seen.count <= maxFolders else { continue }
                        let prev = old.folders[k]
                        let why: String?
                        if full { why = "full refresh" }
                        else if prev == nil { why = "new" }
                        else if let e = item.etag, let pe = prev?.etag { why = e != pe ? "etag changed" : nil }
                        else if let m = item.modified, let pm = prev?.modified { why = m != pm ? "date changed" : nil }
                        else { why = nil }
                        let stale = prev.map { now.timeIntervalSince($0.listed) > maxAge } ?? false
                        if let why = why ?? (stale ? "older than 24 h" : nil) {
                            props[k] = (item.name, item.etag, item.modified, item.added)
                            queue.append((item.url, done.depth + 1))
                            LibTrace.index.log("\(item.name): list (\(why))")
                        } else {
                            keep(k)
                        }
                    } else if item.isMedia {
                        folder.files.append(LibraryIndex.File(url: item.url, name: item.name, size: item.size, added: item.added))
                    }
                }
                // Did the contents change while the folder's own etag / date stayed the same?
                if let prev = old.folders[key], key != fresh.root, prev.etag == folder.etag, prev.modified == folder.modified,
                   prev.etag != nil || prev.modified != nil,
                   Set(prev.files.map(\.url)) != Set(folder.files.map(\.url)) || Set(prev.subfolders) != Set(folder.subfolders) {
                    report.changedWithoutSign += 1
                    LibTrace.index.log("\(folder.name): contents changed but its getetag/getlastmodified didn't")
                }
                fresh.folders[key] = folder
                progress(report.listed + report.kept, report.listed + report.kept + queue.count + running)
            }
        }
        if report.rootFailed && fresh.folders[fresh.root] == nil { keep(fresh.root) }
        fresh.lastCheck = LibraryIndex.Check(date: now, ok: !report.rootFailed, unauthorized: report.unauthorized)
        if !report.rootFailed { fresh.refreshed = now }
        report.ms = Int(Date().timeIntervalSince(start) * 1000)
        return (fresh, report)
    }
}

/// Owns every server's library index for the whole app: loads it from disk,
/// keeps it in memory across screens, refreshes it in the background and
/// saves it. Search Library and Home's Real-Debrid entry read it.
@MainActor
final class LibraryIndexStore: ObservableObject {
    static let shared = LibraryIndexStore()

    /// What a screen shows for one server.
    struct State: Equatable {
        var index: LibraryIndex?
        /// Media files with what search looks through, worked out once per change.
        var searchable: [Searchable] = []
        var refreshing = false
        var full = false
        var done = 0
        var total = 0
    }

    struct Searchable: Equatable {
        let file: LibraryIndex.File
        /// Lower-cased name and clean title.
        let haystack: String
    }

    @Published private(set) var states: [UUID: State] = [:]
    private var loading: [UUID: Task<Void, Never>] = [:]
    private var refreshes: [UUID: Task<Void, Never>] = [:]

    typealias Summary = IndexSummaries.Summary
    private var summaries: IndexSummaries { IndexSummaries.shared }
    /// Refresh progress reaches the screen at most 4 times a second.
    private var lastProgress: [UUID: Date] = [:]

    /// The WebDAV browser script's listing cache lasts 10 minutes (cache_ttl).
    static let freshFor: TimeInterval = 600

    func state(_ id: UUID) -> State { states[id] ?? State() }

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LibraryIndex", isDirectory: true)
    }
    nonisolated static func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    /// Loads the saved index (off the main thread) if it isn't in memory yet.
    func load(_ server: WebDAVServer) async {
        if states[server.id]?.index != nil { return }
        if let t = loading[server.id] { await t.value; return }
        let id = server.id, account = LibraryIndex.account(server)
        let t = Task {
            let read = await Task.detached(priority: .userInitiated) { Self.read(Self.file(id), account: account) }.value
            guard !Task.isCancelled else { return }        // cleared while reading (account changed)
            if let note = read.note { dlog("index", "\(server.name): \(note)") }
            if let index = read.index, states[id]?.index == nil { apply(index, to: id) }
        }
        loading[id] = t
        await t.value
        if loading[id] == t { loading[id] = nil }
    }

    /// Shows the saved index at once; refreshes in the background when it's
    /// missing or older than 10 minutes.
    func refreshIfNeeded(_ server: WebDAVServer) {
        Task {
            await load(server)
            let s = state(server.id)
            guard !s.refreshing else { return }
            if let r = s.index?.refreshed, Date().timeIntervalSince(r) < Self.freshFor { return }
            await refresh(server, full: s.index == nil)
        }
    }

    /// Lists the server again (`full`: every folder, as pull to refresh).
    func refresh(_ server: WebDAVServer, full: Bool) async {
        if let running = refreshes[server.id] {
            if !full { await running.value; return }
            running.cancel()
        }
        let id = server.id
        let t = Task {
            await load(server)
            let client = WebDAVClient(server: server)
            guard let rootURL = client.url(forPath: server.rootPath) else { return }
            let old = state(id).index ?? LibraryIndex(account: LibraryIndex.account(server), root: LibraryIndex.key(rootURL))
            var s = state(id); s.refreshing = true; s.full = full; s.done = 0; s.total = 1; states[id] = s
            let signpost = LibTrace.index.begin("refresh")
            let indexer = LibraryIndexer(list: { try await client.list($0) })
            let (fresh, report) = await indexer.refresh(old, rootURL: rootURL, full: full) { done, total in
                Task { @MainActor in
                    guard var s = self.states[id], s.refreshing,
                          Date().timeIntervalSince(self.lastProgress[id] ?? .distantPast) > 0.25 || done >= total else { return }
                    self.lastProgress[id] = Date()
                    s.done = done; s.total = max(total, done); self.states[id] = s
                }
            }
            LibTrace.index.end("refresh", signpost)
            guard !Task.isCancelled else { return }
            let files = fresh.allFiles
            dlog("index", "\(server.name): \(full ? "full" : "changes only") refresh in \(report.ms) ms — listed \(report.listed) folder(s), kept \(report.kept), "
                 + "failed \(report.failed)\(report.unauthorized ? " (login refused)" : ""); \(fresh.folders.count) folders, \(files.count) media files"
                 + (report.changedWithoutSign > 0 ? "; \(report.changedWithoutSign) folder(s) changed without a new getetag/getlastmodified" : ""))
            apply(fresh, to: id)
            // Trace: the release names, for the release-name parser's tests.
            if LibTrace.on, let root = fresh.folders[fresh.root] {
                let names = root.subfolders.compactMap { fresh.folders[$0]?.name }.prefix(400)
                LibTrace.index.log("release names in the start folder (\(names.count)):\n" + names.joined(separator: "\n"))
            }
            let url = Self.file(id)
            await Task.detached(priority: .utility) { Self.write(fresh, to: url) }.value
        }
        refreshes[id] = t
        await t.value
        guard refreshes[id] == t else { return }       // a full refresh took over
        refreshes[id] = nil
        if var s = states[id] { s.refreshing = false; states[id] = s }
    }

    /// Forgets a server's index (the server was removed, or its address,
    /// user name or start folder changed).
    func clear(_ id: UUID) {
        loading[id]?.cancel()
        loading[id] = nil
        refreshes[id]?.cancel()
        refreshes[id] = nil
        states[id] = nil
        summaries.set(nil, for: id)
        try? FileManager.default.removeItem(at: Self.file(id))
        dlog("index", "index cleared for server \(id.uuidString.prefix(8))")
    }

    private func apply(_ index: LibraryIndex, to id: UUID) {
        var s = state(id)
        s.index = index
        s.searchable = index.allFiles.map { f in
            Searchable(file: f, haystack: (f.name + " " + TitleParser.clean(f.name)).lowercased())
        }
        states[id] = s
        let recent = index.folders.values
            .filter { ReleaseName.folder($0.name) != nil }
            .sorted { ($0.added ?? $0.modified ?? .distantPast) > ($1.added ?? $1.modified ?? .distantPast) }
            .prefix(4).map(\.name)
        let summary = Summary(files: s.searchable.count, bytes: s.searchable.reduce(0) { $0 + ($1.file.size ?? 0) },
                              refreshed: index.refreshed, unauthorized: index.lastCheck?.unauthorized == true,
                              offline: index.lastCheck.map { !$0.ok && !$0.unauthorized } ?? false, recent: Array(recent))
        summaries.set(summary, for: id)
    }

    // MARK: Disk

    /// Reads a saved index; a missing, unreadable, older-layout or other
    /// account's file gives nil and a note for the log (the caller rebuilds).
    nonisolated static func read(_ url: URL, account: String) -> (index: LibraryIndex?, note: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, "no saved index, building one") }
        do {
            let data = try Data(contentsOf: url)
            let index = try JSONDecoder().decode(LibraryIndex.self, from: data)
            guard index.schema == LibraryIndex.schemaVersion else {
                try? FileManager.default.removeItem(at: url)
                return (nil, "saved index has layout \(index.schema), not \(LibraryIndex.schemaVersion): rebuilding")
            }
            guard index.account == account else {
                try? FileManager.default.removeItem(at: url)
                return (nil, "saved index belongs to another account: rebuilding")
            }
            return (index, nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return (nil, "saved index unreadable (\(error.localizedDescription)): rebuilding")
        }
    }

    /// Writes atomically (a crash mid-write leaves the old file).
    nonisolated static func write(_ index: LibraryIndex, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: url, options: .atomic)
        } catch {
            dlog("index", "saving the index failed: \(error.localizedDescription)")
        }
    }
}

/// A few numbers about each server's index, kept in UserDefaults so Home can
/// show its Real-Debrid entry on its very first frame, before the index
/// itself is read from disk (no pop-in, nothing added to launch). Its own
/// object, so Home redraws when these change, not at each step of a refresh.
@MainActor
final class IndexSummaries: ObservableObject {
    static let shared = IndexSummaries()

    struct Summary: Codable, Equatable {
        var files: Int
        var bytes: Int64
        /// The last refresh that worked (nil: never).
        var refreshed: Date?
        var unauthorized: Bool
        /// The last check couldn't reach the server.
        var offline: Bool
        /// The newest release folders' names (Home's collage).
        var recent: [String]
    }

    @Published private(set) var all: [UUID: Summary] = [:]
    private static let key = "libraryIndexSummaries"

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode([String: Summary].self, from: d) {
            all = Dictionary(uniqueKeysWithValues: s.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
    }

    func set(_ summary: Summary?, for id: UUID) {
        guard all[id] != summary else { return }
        all[id] = summary
        let s = Dictionary(uniqueKeysWithValues: all.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.key)
    }
}
