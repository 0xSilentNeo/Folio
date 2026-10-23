import Foundation
import SwiftUI

/// How the library is ordered (Home, All, title pages).
enum LibrarySort: String, CaseIterable {
    case name, date, size
    var title: String { self == .name ? "Name" : self == .date ? "Date added" : "Size" }
    var icon: String { self == .name ? "textformat" : self == .date ? "calendar" : "internaldrive" }

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

    var count: Int { files.count }
    var seasons: [Int] { Array(Set(files.compactMap { TitleParser.parse($0.lastPathComponent).season })).sorted() }

    /// The file a tap should land on: the one being watched, else the first unfinished, else the first.
    @MainActor var nextUp: URL {
        let h = HistoryStore.shared
        if let e = files.first(where: { h.entry(forURL: $0.path)?.canResume == true }) { return e }
        if let e = files.first(where: { h.entry(forURL: $0.path)?.isFinished != true }) { return e }
        return files[0]
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
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey, .fileSizeKey])
        let r = (date: v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0))
        infoLock.lock(); infoCache[url.path] = r; infoLock.unlock()
        return r
    }

    /// Re-reads file info for a fresh scan (off the main thread).
    static func warmInfo(_ urls: [URL]) {
        infoLock.lock(); infoCache = [:]; infoLock.unlock()
        for u in urls { _ = info(u) }
    }

    static func episodeOrder(_ a: URL, _ b: URL) -> Bool {
        let pa = TitleParser.parse(a.lastPathComponent), pb = TitleParser.parse(b.lastPathComponent)
        if (pa.season ?? 0) != (pb.season ?? 0) { return (pa.season ?? 0) < (pb.season ?? 0) }
        if (pa.episode ?? 0) != (pb.episode ?? 0) { return (pa.episode ?? 0) < (pb.episode ?? 0) }
        return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }

    static func groups(_ files: [URL], sort: LibrarySort = .current, ascending: Bool = LibrarySort.ascending) -> [LibraryGroup] {
        var buckets: [String: [URL]] = [:]
        var order: [String] = []
        for f in files {
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
        out.sort { a, b in
            let less: Bool
            switch sort {
            case .name: less = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .date: less = a.date < b.date
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
            case .date: less = info(a).date < info(b).date
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
