import Foundation

/// Continue Watching resumes the show, not just the one file: the queue is
/// rebuilt from where the episode lives, so Up Next and "play next" work.
///   - library files: the show's episodes in the library, in episode order
///   - WebDAV: the media files in the same folder, in name order
///   - Discover (addon) episodes: the rest of that season, each stream found
///     just before it plays, from the same addon and release group
/// Anything else (a pasted link) plays on its own.
enum ContinueQueue {
    @MainActor
    static func play(_ item: MediaItem) {
        Task { @MainActor in
            let t0 = Date()
            let (queue, index) = await build(item)
            dlog("player", String(format: "continue: %d item(s) in queue, starting at %d (built in %.0f ms)", queue.count, index + 1, Date().timeIntervalSince(t0) * 1000))
            PlayerPresenter.play(queue: queue, index: index)
        }
    }

    @MainActor
    static func build(_ item: MediaItem) async -> ([MediaItem], Int) {
        switch item.source {
        case .local:
            return local(item) ?? ([item], 0)
        case .webdav(let serverID):
            return await webdav(item, serverID: serverID) ?? ([item], 0)
        case .addon:
            return await addon(item) ?? ([item], 0)
        case .url:
            if item.streamPick != nil { return await addon(item) ?? ([item], 0) }
            return ([item], 0)
        }
    }

    @MainActor
    private static func local(_ item: MediaItem) -> ([MediaItem], Int)? {
        let path = (item.resolvedURL ?? URL(fileURLWithPath: item.historyKey ?? item.url)).standardizedFileURL.path
        let files = LocalMediaStore.shared.files
        guard let file = files.first(where: { $0.standardizedFileURL.path == path }),
              let group = LibraryOrganizer.groups(files).first(where: { $0.files.contains(file) }), group.isSeries, group.files.count > 1 else { return nil }
        let list = group.files.sorted(by: LibraryOrganizer.episodeOrder)
        let queue = list.map { u -> MediaItem in
            if u == file { return item }                       // keeps resume position, subtitles, hints
            var m = MediaItem(url: u.path, title: TitleParser.clean(u.lastPathComponent), source: .local)
            m.historyKey = u.path
            let p = TitleParser.parse(u.lastPathComponent)
            if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
            return m
        }
        return (queue, list.firstIndex(of: file) ?? 0)
    }

    @MainActor
    private static func webdav(_ item: MediaItem, serverID: UUID) async -> ([MediaItem], Int)? {
        guard let server = ServerStore.shared.servers.first(where: { $0.id == serverID }),
              let fileURL = URL(string: item.url) else { return nil }
        let client = WebDAVClient(server: server)
        let folder = fileURL.deletingLastPathComponent()
        // Don't keep the user waiting on a slow server: 4 s, then play the one file.
        let listing: [DAVItem]? = await withTaskGroup(of: [DAVItem]?.self) { g in
            g.addTask { try? await client.list(folder) }
            g.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        guard let items = listing else { dlog("player", "continue: WebDAV folder listing timed out"); return nil }
        let media = items.filter(\.isMedia).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let subs = items.filter(\.isSubtitle)
        guard media.count > 1, let index = media.firstIndex(where: { $0.url.absoluteString == item.url || $0.url.standardized == fileURL.standardized }) else { return nil }
        let clean = UserDefaults.standard.bool(forKey: SettingsKey.cleanTitles)
        let queue: [MediaItem] = media.enumerated().map { i, m in
            if i == index { return item }
            var mi = client.mediaItem(for: m, cleanTitles: clean)
            let base = (m.name as NSString).deletingPathExtension.lowercased()
            mi.subtitles = subs.filter { $0.name.lowercased().hasPrefix(base) }.map { ExternalSubtitle(url: $0.url.absoluteString, lang: nil, title: $0.name) }
            return mi
        }
        return (queue, index)
    }

    @MainActor
    private static func addon(_ item: MediaItem) async -> ([MediaItem], Int)? {
        guard let pick = item.streamPick else { return nil }
        let c = pick.context
        guard c.type != "movie", c.metaId.hasPrefix("tt") else { return nil }
        let parts = c.videoId.split(separator: ":")
        guard parts.count >= 3, let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]) else { return nil }
        let eps = await IMDbSource.episodes(id: c.metaId, season: season).sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
        let rest = eps.filter { ($0.episode ?? 0) > episode }
        guard !rest.isEmpty else { return nil }
        let queue = [item] + rest.map { v in
            AddonPlayback.placeholder(PlayContext(name: c.name, poster: c.poster, type: c.type, metaId: c.metaId, isAnime: c.isAnime,
                                                  videoId: v.id, videoLabel: v.label, episode: v.episode), pick: pick)
        }
        return (queue, 0)
    }
}
