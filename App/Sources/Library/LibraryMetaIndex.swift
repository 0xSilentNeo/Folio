import Foundation

/// The library metadata of every title in the library at once (1.22.0), for
/// what needs all of it before any tile is on screen: the filters' genres and
/// years, the kids profile's ratings, "Pick something for me".
///
/// One lookup per title (a show's first episode), through MetadataService,
/// which tiles use too: what's saved comes back at once, the rest is looked
/// up three at a time, off the main thread. The answers are published a
/// batch at a time, not one by one, so Home isn't redrawn for each.
@MainActor
final class LibraryMetaIndex: ObservableObject {
    static let shared = LibraryMetaIndex()

    /// By the file name looked up.
    @Published private(set) var metas: [String: MediaMeta] = [:]
    /// Every title of the library has been looked up once.
    @Published private(set) var complete = false

    /// Names looked up, with when (an answer of nothing is asked again after
    /// 10 minutes: IMDb may have been out of reach).
    private var looked: [String: Date] = [:]
    /// A title's key (LibraryOrganizer.titleKey) → the file name its metadata is under.
    private var nameByTitle: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var again = false
    private var files: [URL] = []

    /// The metadata of the title `file` belongs to.
    func meta(for file: URL) -> MediaMeta? {
        if let m = metas[file.lastPathComponent] { return m }
        return nameByTitle[LibraryOrganizer.titleKey(file)].flatMap { metas[$0] }
    }

    /// The file each title is looked up by: its first in episode order.
    nonisolated static func lookupFiles(_ files: [URL]) -> [URL] {
        var first: [String: URL] = [:]
        var order: [String] = []
        for f in files {
            let k = LibraryOrganizer.titleKey(f)
            if let have = first[k] {
                if LibraryOrganizer.episodeOrder(f, have) { first[k] = f }
            } else {
                first[k] = f
                order.append(k)
            }
        }
        return order.compactMap { first[$0] }
    }

    /// The library changed (or Home appeared): looks up what's new.
    func update(_ files: [URL]) {
        self.files = files
        guard task == nil else { again = true; return }
        let reps = Self.lookupFiles(files)
        for f in reps { nameByTitle[LibraryOrganizer.titleKey(f)] = f.lastPathComponent }
        let now = Date()
        let names = reps.map(\.lastPathComponent).filter { n in
            guard let at = looked[n] else { return true }
            return metas[n] == nil && now.timeIntervalSince(at) > 600
        }
        guard !names.isEmpty else { complete = true; return }
        complete = false
        let t0 = Date()
        task = Task { [weak self] in
            var found = 0
            for start in stride(from: 0, to: names.count, by: 12) {
                let batch = Array(names[start..<min(start + 12, names.count)])
                let answers = await ForYou.each(batch, limit: 3) { name in (name, await MetadataService.shared.lookup(filename: name)) }
                guard let self, !Task.isCancelled else { return }
                let at = Date()
                var add = self.metas
                for (name, meta) in answers {
                    self.looked[name] = at
                    if let meta { add[name] = meta; found += 1 }
                }
                if add != self.metas { self.metas = add }
            }
            guard let self else { return }
            dlog("library", "metadata index: \(found) of \(names.count) title(s) found in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            self.task = nil
            self.complete = true
            if self.again { self.again = false; self.update(self.files) }
        }
    }

    // MARK: Facts for the filters

    /// A Home entry's titles: a folder's, one per title in it; else the entry itself.
    static func titles(of g: LibraryGroup) -> [[URL]] {
        guard g.folder != nil else { return [g.files] }
        var byKey: [String: [URL]] = [:], order: [String] = []
        for f in g.files {
            let k = LibraryOrganizer.titleKey(f)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(f)
        }
        return order.map { byKey[$0]! }
    }

    /// One title's facts: its watched state (from the history) and the
    /// metadata's genres and year.
    func facts(_ files: [URL]) -> LibraryFilter.Facts {
        let h = HistoryStore.shared
        let entries = files.map { h.entry(forURL: $0.path) }
        let meta = files.first.flatMap(meta(for:))
        return LibraryFilter.Facts(watch: LibraryFilter.watchState(watched: entries.map { $0?.isFinished == true },
                                                                   resumable: entries.map { $0?.canResume == true }),
                                   genres: meta?.genres ?? [],
                                   year: LibraryFilter.year(meta: meta?.year, fileName: files.first?.lastPathComponent))
    }

    func facts(of g: LibraryGroup) -> [LibraryFilter.Facts] { Self.titles(of: g).map(facts) }

    /// The kids profile lets the entry through: a folder only when every title in it is allowed.
    func kidsAllow(_ g: LibraryGroup, _ limits: KidsRules.Limits) -> Bool {
        Self.titles(of: g).allSatisfy { files in KidsRules.allows(files.first.flatMap(meta(for:)), limits: limits) }
    }
}
