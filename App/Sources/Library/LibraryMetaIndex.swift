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

    /// The title `file` belongs to was matched by hand, or its match was
    /// dropped (1.29.0, Fix Match): what's kept for its files goes, and
    /// they're looked up again.
    func forget(titleOf file: URL) {
        let key = MetadataService.pinKey(TitleParser.parse(file.lastPathComponent))
        for f in files where MetadataService.pinKey(TitleParser.parse(f.lastPathComponent)) == key {
            metas[f.lastPathComponent] = nil
            looked[f.lastPathComponent] = nil
        }
        update(files)
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
        // Set only when it changes (1.28.2): a published value announces
        // even an equal one, and Home redrew whole on every return to it.
        guard !names.isEmpty else { if !complete { complete = true }; return }
        complete = false
        let t0 = Date()
        task = Task { [weak self] in
            var found = 0
            // Published at most every 1.5 s, and at the end (1.30.4): a batch
            // at a time, a first index of 1,000 titles redrew Home 84 times.
            var pending: [String: MediaMeta] = [:]
            var published = Date.distantPast
            for start in stride(from: 0, to: names.count, by: 12) {
                let batch = Array(names[start..<min(start + 12, names.count)])
                let answers = await ForYou.each(batch, limit: 3) { name in (name, await MetadataService.shared.lookup(filename: name)) }
                guard let self, !Task.isCancelled else { return }
                let at = Date()
                for (name, meta) in answers {
                    self.looked[name] = at
                    if let meta { pending[name] = meta; found += 1 }
                }
                if at.timeIntervalSince(published) >= LibraryMetaIndex.publishEvery {
                    self.publish(&pending)
                    published = at
                }
            }
            guard let self else { return }
            self.publish(&pending)
            dlog("library", "metadata index: \(found) of \(names.count) title(s) found in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            self.task = nil
            self.complete = true
            if self.again { self.again = false; self.update(self.files) }
        }
    }

    static let publishEvery: TimeInterval = 1.5

    /// Answers waiting into `metas`, but not a name forgotten meanwhile (Fix
    /// Match): it's looked up again.
    private func publish(_ pending: inout [String: MediaMeta]) {
        guard !pending.isEmpty else { return }
        var add = metas
        for (name, meta) in pending where looked[name] != nil { add[name] = meta }
        pending = [:]
        if add != metas { metas = add }
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

    /// The filter menu's genres and years (1.28.2): from the metadata alone,
    /// no history lookups, and kept until the library or its metadata
    /// changes. Home built every title's full facts for them on every redraw.
    private var optionsMemo: (key: Int, genres: [String], years: [String])?

    func filterOptions(of groups: [LibraryGroup]) -> (genres: [String], years: [String]) {
        var h = Hasher()
        h.combine(metas.count)
        for g in groups { h.combine(g.id); h.combine(g.files.count) }
        let key = h.finalize()
        if let m = optionsMemo, m.key == key { return (m.genres, m.years) }
        let facts = groups.flatMap { Self.titles(of: $0) }.map { files -> LibraryFilter.Facts in
            let meta = files.first.flatMap(meta(for:))
            return LibraryFilter.Facts(watch: .unwatched, genres: meta?.genres ?? [],
                                       year: LibraryFilter.year(meta: meta?.year, fileName: files.first?.lastPathComponent))
        }
        let genres = LibraryFilter.genres(in: facts), years = LibraryFilter.years(in: facts)
        optionsMemo = (key, genres, years)
        return (genres, years)
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

    /// A queue for the kids profile (1.23.0): only files whose title it
    /// allows, and the one tapped. Without it a film's queue was the whole
    /// library, and autoplay went on to an R-rated film (review, 5 Nov).
    /// Outside the profile, the list as it is.
    func kidsQueue(_ files: [URL], keeping tapped: URL) -> [URL] {
        guard let limits = KidsProfile.shared.activeLimits else { return files }
        return files.filter { $0 == tapped || KidsRules.allows(meta(for: $0), limits: limits) }
    }

    /// The kids profile lets the entry through: a folder only when every title in it is allowed.
    func kidsAllow(_ g: LibraryGroup, _ limits: KidsRules.Limits) -> Bool {
        Self.titles(of: g).allSatisfy { files in KidsRules.allows(files.first.flatMap(meta(for:)), limits: limits) }
    }
}
