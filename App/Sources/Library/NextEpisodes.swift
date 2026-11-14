import Foundation

/// The episodes that come after one, wherever they are on its server
/// (1.23.2). A queue is the files of the episode's own folder, but a debrid
/// service keeps every torrent in a folder of its own: a show added episode
/// by episode is one folder per episode, so the queue held the one file and
/// the player closed at its end instead of going on (5 Nov report: The
/// Gentlemen S02E01, E02, E03 and E06 in four folders on Real-Debrid,
/// "continue: 1 item(s) in queue" each time it was played).
enum NextEpisodes {
    /// What makes two files the same show: the parsed title, letters and
    /// digits only ("The.Gentlemen" and "The Gentlemen" are one).
    static func showKey(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The release group, what follows the name's last "-": "…H.265-FLUX" → "flux".
    static func group(_ name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        guard let r = base.range(of: "-", options: .backwards) else { return nil }
        let g = base[r.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty, g.count <= 24, !g.contains(" "), !g.contains(".") else { return nil }
        return g.lowercased()
    }

    private static let sample = try! NSRegularExpression(pattern: #"(?i)\bsample\b"#)

    /// The episodes after `url` (`name` is its file name) among `files`, in
    /// season and episode order, one file each, `limit` at most. An episode
    /// with copies in several releases gets the one most like this file:
    /// the same release group, then the same resolution, then the same folder.
    /// Seasons have to agree: an episode numbered without a season ("Show -
    /// 04") goes on only to others numbered without one.
    static func after(_ name: String, url: URL, in files: [LibraryIndex.File], limit: Int = 40) -> [LibraryIndex.File] {
        let p = TitleParser.parse(name)
        guard let episode = p.episode, p.extra == nil else { return [] }
        let key = showKey(p.title)
        guard !key.isEmpty else { return [] }
        let season = p.season ?? 0
        let myGroup = group(name)
        let me = url.standardized, myFolder = url.deletingLastPathComponent().standardized
        struct Pick { let file: LibraryIndex.File; let score: Int; let season: Int; let episode: Int }
        var best: [String: Pick] = [:]
        for f in files where TitleParser.isMedia(f.name) && f.url.standardized != me {
            let q = TitleParser.parse(f.name)
            guard let e = q.episode, q.extra == nil, (q.season == nil) == (p.season == nil),
                  showKey(q.title) == key else { continue }
            let s = q.season ?? 0
            guard s > season || (s == season && e > episode) else { continue }
            let path = f.url.path
            guard sample.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) == nil else { continue }
            var score = 0
            if let myGroup, group(f.name) == myGroup { score += 4 }
            if let r = p.resolution, q.resolution == r { score += 2 }
            if f.url.deletingLastPathComponent().standardized == myFolder { score += 1 }
            let k = "\(s):\(e)"
            if let b = best[k], b.score > score || (b.score == score && b.file.name.localizedStandardCompare(f.name) != .orderedDescending) { continue }
            best[k] = Pick(file: f, score: score, season: s, episode: e)
        }
        return best.values
            .sorted { $0.season != $1.season ? $0.season < $1.season : $0.episode < $1.episode }
            .prefix(limit).map(\.file)
    }

    /// A library's episodes by show (showKey of the parsed title), so the
    /// episodes after one are looked for among its show's files only
    /// (1.30.4, Continue Watching's next-episode cards).
    static func byShow(_ files: [LibraryIndex.File]) -> [String: [LibraryIndex.File]] {
        var out: [String: [LibraryIndex.File]] = [:]
        for f in files where TitleParser.isMedia(f.name) {
            let p = TitleParser.parse(f.name)
            guard p.episode != nil else { continue }
            let k = showKey(p.title)
            if !k.isEmpty { out[k, default: []].append(f) }
        }
        return out
    }
}

/// The episodes after a history entry's, for Continue Watching's card of a
/// show whose last episode was watched to its end (1.30.4), from what's on
/// the phone, without asking a server: the library's files (the show's
/// episodes, as its queue has them) and a WebDAV server's saved library
/// (NextEpisodes.after: the same release first, in any of its folders).
/// Tapping the card plays it as any other card (ContinueQueue.play).
@MainActor
enum ContinueNext {
    static let limit = 12

    static func after(_ e: HistoryEntry) -> [MediaItem] {
        switch e.item.source {
        case .local:
            let files = LocalMediaStore.shared.files
            return local(e.item, files: files.isEmpty ? scanned : files)
        case .webdav(let id):
            guard let server = ServerStore.shared.server(id: id), let shows = showFiles(server) else { return [] }
            let clean = UserDefaults.standard.object(forKey: SettingsKey.cleanTitles) as? Bool ?? true
            return webdav(e.item, shows: shows) { webdavItem($0, serverID: id, cleanTitles: clean) }
        default:
            return []
        }
    }

    /// The library's episodes after `item`'s, in its show's order.
    static func local(_ item: MediaItem, files: [URL]) -> [MediaItem] {
        guard !files.isEmpty, let rel = HistoryStore.libraryRelative(item.historyKey ?? item.url) else { return [] }
        for g in LibraryOrganizer.groups(files) where g.isSeries {
            guard let i = g.files.firstIndex(where: { HistoryStore.libraryRelative($0.path) == rel }) else { continue }
            return g.files.dropFirst(i + 1).prefix(limit).map(ContinueQueue.libraryItem)
        }
        return []
    }

    /// The server's episodes after `item`'s (`shows`: its library by show).
    static func webdav(_ item: MediaItem, shows: [String: [LibraryIndex.File]], make: (LibraryIndex.File) -> MediaItem) -> [MediaItem] {
        guard let url = URL(string: item.url) else { return [] }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let p = TitleParser.parse(name)
        guard p.episode != nil, let files = shows[NextEpisodes.showKey(p.title)] else { return [] }
        return NextEpisodes.after(name, url: url, in: files, limit: limit).map(make)
    }

    /// A file of the saved library as the browser's item (WebDAVClient.mediaItem)
    /// without its login: that's added at play time (preparedForPlayback),
    /// and reading it from the Keychain here would be once per card.
    static func webdavItem(_ f: LibraryIndex.File, serverID: UUID, cleanTitles: Bool) -> MediaItem {
        var m = MediaItem(url: f.url.absoluteString,
                          title: cleanTitles ? TitleParser.clean(f.name) : (f.name as NSString).deletingPathExtension,
                          subtitle: f.url.deletingLastPathComponent().lastPathComponent.removingPercentEncoding,
                          source: .webdav(serverID: serverID))
        let p = TitleParser.parse(f.name)
        if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
        return m
    }

    // MARK: Saved libraries by show

    private struct Stamp: Equatable {
        var account: String
        var refreshed: Date?
        var folders: Int
    }

    private static var shows: [UUID: (stamp: Stamp, files: [String: [LibraryIndex.File]])] = [:]
    private static var building: [UUID: Stamp] = [:]
    private static var loadAsked: Set<UUID> = []
    /// The library as prepare() listed it, until LocalMediaStore has.
    private static var scanned: [URL] = []

    /// Every source read now (HistoryStore.continueEntry): the library
    /// listed, and the saved libraries of the servers `entries` played from.
    static func prepare(_ entries: [HistoryEntry]) async {
        if LocalMediaStore.shared.files.isEmpty { scanned = await ContinueQueue.libraryFiles() }
        var ids = Set<UUID>()
        for e in entries { if case .webdav(let id) = e.item.source { ids.insert(id) } }
        for server in ServerStore.shared.servers where ids.contains(server.id) {
            await LibraryIndexStore.shared.load(server)
            guard let index = LibraryIndexStore.shared.state(server.id).index else { continue }
            let stamp = Stamp(account: index.account, refreshed: index.refreshed, folders: index.folders.count)
            guard shows[server.id]?.stamp != stamp else { continue }
            let files = index.allFiles
            let map = await Task.detached(priority: .userInitiated) { NextEpisodes.byShow(files) }.value
            shows[server.id] = (stamp, map)
        }
    }

    /// A server's saved library by show, worked out off the main thread once
    /// per refresh of it (~1,500 names on Real-Debrid in the 14 Nov log);
    /// Continue Watching is told when it's ready. The last one meanwhile.
    static func showFiles(_ server: WebDAVServer) -> [String: [LibraryIndex.File]]? {
        let id = server.id
        guard let index = LibraryIndexStore.shared.state(id).index else {
            // Not read yet this launch: read from disk now; the card follows.
            if loadAsked.insert(id).inserted { Task { await LibraryIndexStore.shared.load(server) } }
            return nil
        }
        let stamp = Stamp(account: index.account, refreshed: index.refreshed, folders: index.folders.count)
        if let s = shows[id], s.stamp == stamp { return s.files }
        if building[id] != stamp {
            building[id] = stamp
            let files = index.allFiles
            Task { @MainActor in
                let map = await Task.detached(priority: .utility) { NextEpisodes.byShow(files) }.value
                guard building[id] == stamp else { return }        // a newer one is on its way
                building[id] = nil
                shows[id] = (stamp, map)
                HistoryStore.shared.nextSourcesChanged()
            }
        }
        // Not another account's.
        guard let last = shows[id], last.stamp.account == stamp.account else { return nil }
        return last.files
    }
}
