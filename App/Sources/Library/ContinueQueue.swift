import Foundation

/// Continue Watching resumes the show, not just the one file: the queue is
/// rebuilt from where the episode lives, so Up Next and "play next" work.
///   - library files: the show's episodes in the library, in episode order
///   - WebDAV: the media files in the same folder, in name order
///   - Discover (addon) episodes: the rest of that season, each stream found
///     just before it plays, from the same addon and release group
///   - SMB, Jellyfin and Plex: the rest of the folder or season (ServerQueue)
/// Anything else (a pasted link) plays on its own.
enum ContinueQueue {
    /// The queue being built. A newer tap replaces it, and a player opened
    /// meanwhile (another card, a file) isn't replaced when a slow server's
    /// listing comes back (review, 5 Nov).
    @MainActor private static var pending: Task<Void, Never>?

    @MainActor
    static func play(_ item: MediaItem) {
        pending?.cancel()
        let before = PlayerPresenter.current.map(ObjectIdentifier.init)
        pending = Task { @MainActor in
            let t0 = Date()
            if case .webdav = item.source {
                // The player opens at once and the folder's other files join
                // its queue when the listing comes (1.23.2): the listing took
                // 1.2 s on Real-Debrid ("built in 1212 ms", 5 Nov log) before
                // the file was even asked for.
                let it = await webdavAddress(item)
                guard !Task.isCancelled, PlayerPresenter.current.map(ObjectIdentifier.init) == before else { return }
                PlayerPresenter.play(queue: [it], index: 0)
                let opened = PlayerPresenter.current.map(ObjectIdentifier.init)
                let (queue, index) = await build(it)
                guard !Task.isCancelled, let player = PlayerPresenter.current, ObjectIdentifier(player) == opened else { return }
                dlog("player", String(format: "continue: %d item(s) in queue, starting at %d (built in %.0f ms, the player already open)", queue.count, index + 1, Date().timeIntervalSince(t0) * 1000))
                if queue.count > 1 { player.model.adoptQueue(queue, index: index) }
                return
            }
            let (queue, index) = await build(item)
            guard !Task.isCancelled else { return }
            guard PlayerPresenter.current.map(ObjectIdentifier.init) == before else {
                dlog("player", "continue: another player opened while the queue was built; not replaced")
                return
            }
            dlog("player", String(format: "continue: %d item(s) in queue, starting at %d (built in %.0f ms)", queue.count, index + 1, Date().timeIntervalSince(t0) * 1000))
            PlayerPresenter.play(queue: queue, index: index)
        }
    }

    /// A WebDAV episode saved under its download address (1.23.1 and older
    /// put a prepared next episode's download address in the episode, so
    /// history kept it: the 5 Nov log played "syd3-4.download.real-debrid.com
    /// /d/…" from Continue Watching as a queue of one, an address that
    /// expires). Its WebDAV address is found again in the server's library by
    /// file name, and its history entry moves there with its position.
    @MainActor
    static func webdavAddress(_ item: MediaItem) async -> MediaItem {
        guard case .webdav(let id) = item.source, let server = ServerStore.shared.servers.first(where: { $0.id == id }),
              let u = URL(string: item.url), let base = URL(string: server.baseURL),
              let host = u.host?.lowercased(), host != base.host?.lowercased() else { return item }
        await LibraryIndexStore.shared.load(server)
        let name = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
        guard let f = LibraryIndexStore.shared.state(id).index?.allFiles.first(where: { $0.name == name }) else {
            dlog("player", "continue: \(name) was saved under a download address and isn't in \(server.name)'s library")
            return item
        }
        var it = item
        it.url = f.url.absoluteString
        if let e = HistoryStore.shared.entry(for: item.id) {
            HistoryStore.shared.record(it, position: e.position, duration: e.duration)
            HistoryStore.shared.remove(e)
        }
        dlog("player", "continue: \(name) was saved under a download address; its WebDAV address on \(server.name) instead")
        return it
    }

    @MainActor
    static func build(_ item: MediaItem) async -> ([MediaItem], Int) {
        switch item.source {
        case .local:
            return local(item, files: await libraryFiles()) ?? ([item], 0)
        case .webdav(let serverID):
            return await webdav(item, serverID: serverID) ?? ([item], 0)
        case .addon:
            return await addon(item) ?? ([item], 0)
        case .url:
            if item.streamPick != nil { return await addon(item) ?? ([item], 0) }
            if item.remote != nil { return await ServerQueue.build(item) ?? ([item], 0) }
            return ([item], 0)
        }
    }

    /// The library's files. Opened from the widget or Siri as Folio starts,
    /// LocalMediaStore may not have listed them yet (it lists them off the
    /// main thread): listed here then, or a show's other episodes would be
    /// missing from the queue (1.20.3).
    @MainActor
    static func libraryFiles() async -> [URL] {
        let files = LocalMediaStore.shared.files
        if !files.isEmpty { return files }
        return await Task.detached(priority: .userInitiated) { LocalMediaStore.scan() }.value
    }

    @MainActor
    private static func local(_ item: MediaItem, files: [URL]) -> ([MediaItem], Int)? {
        let path = (item.resolvedURL ?? URL(fileURLWithPath: item.historyKey ?? item.url)).standardizedFileURL.path
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
