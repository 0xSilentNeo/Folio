import SwiftUI

/// One watched state for a title, whichever page shows it (1.30.0).
///
/// The library's title page read only a file's own history entry and
/// Discover's only the `addon:<id>` one, so a show watched from your own
/// files looked unwatched in Discover and "Continue Season" began at E1
/// (UX audit). Both pages now ask here: an episode or film is watched, or in
/// progress, when either its library file or its addon entry says so.
///
/// The two are linked by TitleIdentity's form ("tt…" for a film, "tt…:1:5"
/// for an episode): an addon entry has it in its key, a library file gets
/// it from the title Folio matched it to and its season and episode.
enum WatchedState {
    // MARK: Identity

    /// A library file's identity, or nil when it isn't certain.
    /// `imdb` and `type`: the title the library matched the file to.
    /// An episode needs its season: the one in the file's name, else the
    /// one IMDb numbers it with (`metaSeason`, `metaEpisode`: an absolute
    /// number, "Show - 26" → S2 E1). A side release (OVA, Special, a
    /// series' film) has numbers of its own: none.
    static func identity(imdb: String?, type: String?, parsed: TitleParser.Parsed, metaSeason: Int?, metaEpisode: Int?) -> String? {
        guard let imdb, imdb.hasPrefix("tt"), parsed.extra == nil else { return nil }
        guard let episode = parsed.episode else { return type == "movie" ? imdb : nil }
        guard type != "movie" else { return nil }
        if let season = parsed.season { return "\(imdb):\(season):\(episode)" }
        if let s = metaSeason, let e = metaEpisode { return "\(imdb):\(s):\(e)" }
        return nil
    }

    /// The history key of the addon entry with this identity.
    static func addonKey(_ identity: String) -> String { "addon:" + identity }

    /// An addon video's identity ("tt…:1:5", a film's "tt…"); nil for ids
    /// that aren't IMDb's (kitsu:…): those stay on their own.
    static func identity(videoID: String) -> String? { TitleIdentity.fromAddonKey(addonKey(videoID)) }

    // MARK: Combining

    /// The one entry that speaks for all of an episode's entries: a finished
    /// one when any is (watched anywhere is watched), else one with a place
    /// to resume, else whatever there is; the most recent of each.
    static func combined(_ entries: [HistoryEntry?]) -> HistoryEntry? {
        let all = entries.compactMap { $0 }
        func latest(_ list: [HistoryEntry]) -> HistoryEntry? { list.max { $0.updated < $1.updated } }
        return latest(all.filter(\.isFinished)) ?? latest(all.filter(\.canResume)) ?? latest(all)
    }

    /// Where to start what's about to be played when the place is kept by
    /// its other side (the file, for a stream; the addon entry, for a
    /// file): nil when it has a place of its own (the player resumes from
    /// that), or when it's watched on either side (it plays from the start).
    static func carriedPosition(own: HistoryEntry?, others: [HistoryEntry?]) -> Double? {
        guard own?.canResume != true, let c = combined([own] + others), c.canResume else { return nil }
        return c.position
    }

    /// Where "Continue" starts: the first that isn't watched, else the first.
    static func firstUnwatched(_ watched: [Bool]) -> Int { watched.firstIndex(of: false) ?? 0 }

    /// LibraryGroup.nextUp's rule over any entries: the one watched last;
    /// if that one is finished, the first unfinished after it. Nothing
    /// watched yet: the first unfinished, else the first.
    static func nextUp<T>(_ items: [T], entry: (T) -> HistoryEntry?) -> T? {
        guard !items.isEmpty else { return nil }
        let entries = items.map(entry)
        let seen = entries.indices.filter { entries[$0] != nil }
        if let last = seen.max(by: { entries[$0]!.updated < entries[$1]!.updated }) {
            guard entries[last]!.isFinished else { return items[last] }
            if let next = entries.indices.dropFirst(last + 1).first(where: { entries[$0]?.isFinished != true }) { return items[next] }
            return items[last]
        }
        return items[0]
    }

    // MARK: Marking

    /// The keys to mark for one item: its own, and those of its other side
    /// that have an entry already. Marking never makes an entry for
    /// something that was only ever on the other side.
    static func markKeys(own: [String], others: [String], exists: (String) -> Bool) -> [String] {
        own + others.filter { !own.contains($0) && exists($0) }
    }

    /// The history item of an addon episode or film that was never played,
    /// so it can be marked watched: as AddonPlayback keeps one, without a stream.
    static func addonItem(key: String, name: String, poster: String?, type: String, metaID: String, label: String?) -> MediaItem {
        var item = MediaItem(url: "", title: name, subtitle: label, source: .url)
        item.artwork = poster
        item.historyKey = key
        item.addonRef = "\(type)|\(metaID)|\(key.hasPrefix("addon:") ? String(key.dropFirst("addon:".count)) : key)"
        return item
    }

    // MARK: Accessibility

    /// What a row or tile says after its name: "Watched", "In progress", or nothing.
    static func spoken(_ entry: HistoryEntry?) -> String {
        guard let entry else { return "" }
        if entry.isFinished { return "Watched" }
        return entry.progress > 0.01 ? "In progress" : ""
    }

    // MARK: The library's files of a title

    /// Each file's identity, for those that have one. From what's already
    /// known (the library's metadata index and saved lookups): no requests.
    @MainActor
    static func identities(of files: [URL]) async -> [URL: String] {
        var out: [URL: String] = [:]
        for f in files {
            guard let title = LibraryMetaIndex.shared.meta(for: f), title.id.hasPrefix("tt") else { continue }
            let p = TitleParser.parse(f.lastPathComponent)
            var known: MediaMeta?
            if p.episode != nil, p.season == nil, p.extra == nil {
                known = await MetadataService.shared.known(filename: f.lastPathComponent)
                if known?.id != title.id { known = nil }
            }
            if let id = identity(imdb: title.id, type: title.type, parsed: p, metaSeason: known?.episodeSeason, metaEpisode: known?.episodeNumber) {
                out[f] = id
            }
        }
        return out
    }

    /// The library's files of one IMDb title, by identity (Discover's page:
    /// built once when it loads and when the library changes, not per row).
    @MainActor
    static func libraryFiles(imdb: String) async -> [String: [URL]] {
        guard imdb.hasPrefix("tt") else { return [:] }
        let files = LocalMediaStore.shared.files.filter { LibraryMetaIndex.shared.meta(for: $0)?.id == imdb }
        var out: [String: [URL]] = [:]
        for (file, id) in await identities(of: files) { out[id, default: []].append(file) }
        return out.mapValues { $0.sorted { $0.path < $1.path } }
    }
}

/// The watched mark of an episode row, on both title pages (1.30.0): the
/// library's eye. Discover's rows had a checkmark and the word.
struct WatchedGlyph: View {
    /// False where the row says "Watched" as its accessibility value.
    var spoken = true
    var body: some View {
        Image(systemName: "eye.fill").font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("Watched")
            .accessibilityHidden(!spoken)
    }
}
