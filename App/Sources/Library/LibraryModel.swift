import Foundation
import SwiftUI

/// How a library list is ordered: Home's library, its folders and the
/// WebDAV browser, all through one sort menu (LibrarySortMenu). The raw
/// values are the ones saved before 1.19.0 ("date" was Home's "Date added"
/// and the browser's "Recently Added"), so saved choices still read back.
enum LibrarySort: String, CaseIterable, Codable {
    case recent = "date", name, size

    var title: String {
        switch self {
        case .recent: return "Recently Added"
        case .name: return "Name"
        case .size: return "Size"
        }
    }

    /// The direction a sort starts in when you pick it: newest and largest
    /// first, names A to Z.
    var startsAscending: Bool { self == .name }

    /// The order in words, shown under the checked sort as the Files app
    /// does ("Name / Ascending", "Date / Newest to Oldest" — iOS 26.2, lab run).
    func direction(ascending: Bool) -> String {
        switch self {
        case .recent: return ascending ? "Oldest to Newest" : "Newest to Oldest"
        case .name: return ascending ? "Ascending" : "Descending"
        case .size: return ascending ? "Smallest to Largest" : "Largest to Smallest"
        }
    }

    static var current: LibrarySort {
        get { LibrarySort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .name }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "librarySort") }
    }
    static var ascending: Bool {
        get { UserDefaults.standard.object(forKey: "librarySortAsc") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "librarySortAsc") }
    }
}

/// One tile on Home: a movie (one file) or a series (its episodes merged),
/// the way the WebDAV browser script folds releases into seasons.
struct LibraryGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let files: [URL]            // episode order
    let isSeries: Bool
    let date: Date
    let size: Int64
    /// A folder in Media whose files are different titles: shown as one
    /// folder tile (four of its pictures in a 2 × 2 grid), not merged.
    var folder: URL? = nil

    var count: Int { files.count }
    var seasons: [Int] { Array(Set(files.compactMap { TitleParser.parse($0.lastPathComponent).season })).sorted() }

    /// The file a tap should land on (see `nextUp(in:)`).
    @MainActor var nextUp: URL { Self.nextUp(in: files) }

    /// The episode watched last; if that one is finished, the episode after
    /// it. Nothing watched yet: the first unfinished, else the first.
    /// (Until 1.14.1 this took the FIRST resumable episode, so an episode
    /// left half-watched long ago kept the highlight.)
    @MainActor static func nextUp(in files: [URL]) -> URL {
        let h = HistoryStore.shared
        let watched = files.compactMap { f in h.entry(forURL: f.path).map { (file: f, entry: $0) } }
        if let last = watched.max(by: { $0.entry.updated < $1.entry.updated }) {
            guard last.entry.isFinished else { return last.file }
            if let i = files.firstIndex(of: last.file) {
                if let next = files[(i + 1)...].first(where: { h.entry(forURL: $0.path)?.isFinished != true }) { return next }
            }
            return last.file
        }
        return files.first(where: { h.entry(forURL: $0.path)?.isFinished != true }) ?? files[0]
    }
}

enum LibraryOrganizer {
    private static let infoLock = NSLock()
    private nonisolated(unsafe) static var infoCache: [String: (date: Date, size: Int64)] = [:]

    /// Date added and size; cached (read once per library scan, not on every redraw).
    static func info(_ url: URL) -> (date: Date, size: Int64) {
        infoLock.lock()
        if let c = infoCache[url.path] { infoLock.unlock(); return c }
        infoLock.unlock()
        let r = read(url)
        infoLock.lock(); infoCache[url.path] = r; infoLock.unlock()
        return r
    }

    private static func read(_ url: URL) -> (date: Date, size: Int64) {
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey, .fileSizeKey])
        return (date: v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0))
    }

    /// Re-reads file info for a fresh scan (off the main thread). The library
    /// is scanned each time the app becomes active; only a change in what was
    /// read makes the groups be worked out again (a new generation).
    static func warmInfo(_ urls: [URL]) {
        var fresh: [String: (date: Date, size: Int64)] = [:]
        for u in urls { fresh[u.path] = read(u) }
        infoLock.lock(); defer { infoLock.unlock() }
        let same = fresh.count == infoCache.count
            && fresh.allSatisfy { k, v in infoCache[k].map { $0.date == v.date && $0.size == v.size } ?? false }
        guard !same else { return }
        infoCache = fresh
        infoGeneration += 1
    }

    /// The last groups worked out, for the same files, order and file info.
    /// Home works them out on every redraw (each page opening or closing
    /// redraws it), and so does every title page that opens: 28 Oct profile,
    /// ~15 ms a time in the simulator.
    private nonisolated(unsafe) static var groupsMemo: (files: [URL], sort: LibrarySort, ascending: Bool, generation: Int, groups: [LibraryGroup])?
    private nonisolated(unsafe) static var infoGeneration = 0

    static func episodeOrder(_ a: URL, _ b: URL) -> Bool {
        let pa = TitleParser.parse(a.lastPathComponent), pb = TitleParser.parse(b.lastPathComponent)
        if (pa.season ?? 0) != (pb.season ?? 0) { return (pa.season ?? 0) < (pb.season ?? 0) }
        if (pa.episode ?? 0) != (pb.episode ?? 0) { return (pa.episode ?? 0) < (pb.episode ?? 0) }
        return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }

    private static func key(_ f: URL) -> String {
        let p = TitleParser.parse(f.lastPathComponent)
        return p.episode != nil ? "s|" + p.title.lowercased() : "f|" + f.path
    }

    static func groups(_ files: [URL], sort: LibrarySort = .current, ascending: Bool = LibrarySort.ascending) -> [LibraryGroup] {
        infoLock.lock()
        if let m = groupsMemo, m.sort == sort, m.ascending == ascending, m.generation == infoGeneration, m.files == files {
            infoLock.unlock()
            return m.groups
        }
        let generation = infoGeneration
        infoLock.unlock()
        let g = workOutGroups(files, sort: sort, ascending: ascending)
        infoLock.lock(); groupsMemo = (files, sort, ascending, generation, g); infoLock.unlock()
        return g
    }

    private static func workOutGroups(_ files: [URL], sort: LibrarySort, ascending: Bool) -> [LibraryGroup] {
        // Folders whose files are more than one title become folder tiles.
        let media = MPVFiles.mediaDir.standardizedFileURL.path
        var byFolder: [String: [URL]] = [:]
        for f in files {
            let dir = f.deletingLastPathComponent().standardizedFileURL
            if dir.path != media, dir.deletingLastPathComponent().standardizedFileURL.path == media { byFolder[dir.path, default: []].append(f) }
        }
        var folderGroups: [LibraryGroup] = []
        var inFolders = Set<URL>()
        for (dir, list) in byFolder where list.count > 1 && Set(list.map(key)).count > 1 {
            let sortedList = list.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let infos = sortedList.map(info)
            let u = URL(fileURLWithPath: dir, isDirectory: true)
            folderGroups.append(LibraryGroup(id: "d|" + dir, title: u.lastPathComponent, files: sortedList, isSeries: false,
                                             date: infos.map(\.date).max() ?? .distantPast, size: infos.map(\.size).reduce(0, +), folder: u))
            inFolders.formUnion(list)
        }

        var buckets: [String: [URL]] = [:]
        var order: [String] = []
        for f in files where !inFolders.contains(f) {
            let p = TitleParser.parse(f.lastPathComponent)
            // Only episodes merge; two movies with the same name stay separate tiles.
            let key = p.episode != nil ? "s|" + p.title.lowercased() : "f|" + f.path
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(f)
        }
        var out: [LibraryGroup] = order.map { key in
            let list = buckets[key]!.sorted(by: episodeOrder)
            let p = TitleParser.parse(list[0].lastPathComponent)
            let infos = list.map(info)
            return LibraryGroup(id: key, title: key.hasPrefix("s|") ? p.title : TitleParser.clean(list[0].lastPathComponent),
                                files: list, isSeries: key.hasPrefix("s|"),
                                date: infos.map(\.date).max() ?? .distantPast, size: infos.map(\.size).reduce(0, +))
        }
        out += folderGroups
        out.sort { a, b in
            let less: Bool
            switch sort {
            case .name: less = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .recent: less = a.date < b.date
            case .size: less = a.size < b.size
            }
            return ascending ? less : !less
        }
        return out
    }

    static func sorted(_ files: [URL], sort: LibrarySort = .current, ascending: Bool = LibrarySort.ascending) -> [URL] {
        files.sorted { a, b in
            let less: Bool
            switch sort {
            case .name: less = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            case .recent: less = info(a).date < info(b).date
            case .size: less = info(a).size < info(b).size
            }
            return ascending ? less : !less
        }
    }
}


/// Navigation routes for title pages. Pages are pushed by value, so going
/// back no longer depends on the link that opened them still existing:
/// with view-building links, Home rebuilding its lists (after you watched
/// something, or the library refreshed) could orphan the open title page so
/// neither Back nor the swipe closed it.
enum LibraryRoute: Hashable {
    case group(String)        // LibraryGroup.id
    case file(String)         // file path
    case folder(String)       // folder path
    case settings

    /// The id the page zooms out of on Home (HomeView.destination).
    var zoomID: AnyHashable? {
        switch self {
        case .group(let id): return AnyHashable(id)
        case .folder(let path): return AnyHashable("d|" + path)
        case .settings: return AnyHashable("settings")
        case .file: return nil
        }
    }

    @MainActor @ViewBuilder
    static func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .group(let id):
            if let g = LibraryOrganizer.groups(LocalMediaStore.shared.files).first(where: { $0.id == id }) {
                TitleHeroView(group: g)
            } else {
                ContentUnavailableView("Not in your library any more", systemImage: "film")
            }
        case .file(let path):
            TitleHeroView(file: URL(fileURLWithPath: path))
        case .folder(let path):
            let u = URL(fileURLWithPath: path)
            LocalFolderView(url: u, title: u.lastPathComponent)
        case .settings:
            SettingsView()
        }
    }
}
