import Foundation

/// SMB, Jellyfin and Plex items at play time (1.20.3, 2 Nov).
///
/// Items are made and saved without their login; preparedForPlayback adds
/// it from the Keychain just before the player gets the queue:
/// - Jellyfin: the X-Emby-Token header (a header, so it's never in an
///   address that mpv or the log prints),
/// - Plex: the X-Plex-Token header,
/// - SMB: the password in the smb:// address, which mpv's FFmpeg needs
///   there (the log hides passwords in addresses).
/// The address is made again from the server's current one, so a server
/// that moved keeps its history: that is keyed by server and item.
enum ServerPlayback {
    static func historyKey(kind: ServerItemRef.Kind, server: UUID, item: String) -> String {
        "\(kind.rawValue):\(server.uuidString):\(item)"
    }

    @MainActor
    static func prepared(_ item: MediaItem, _ ref: ServerItemRef) -> MediaItem {
        guard let server = MediaServerStore.shared.server(id: ref.serverID) else { return item }
        // Only the login this kind uses (1.30.4): each was a Keychain read, per item of the queue.
        let smb = ref.kind == .smb
        return prepared(item, ref, server: server, token: smb ? nil : server.token, password: smb ? server.password : nil)
    }

    /// The same with the login given (tests, and no Keychain read).
    static func prepared(_ item: MediaItem, _ ref: ServerItemRef, server: MediaServer, token: String?, password: String?) -> MediaItem {
        var m = item
        switch ref.kind {
        case .jellyfin:
            if let base = server.baseURL, let u = JellyfinAPI.streamURL(base: base, itemID: ref.id) { m.url = u.absoluteString }
            if let token { m.headers["X-Emby-Token"] = token }
        case .plex:
            if let base = server.baseURL, let part = ref.part, let u = PlexAPI.partURL(base: base, part: part) { m.url = u.absoluteString }
            if let token { m.headers["X-Plex-Token"] = token }
        case .smb:
            guard let host = server.smbHost else { return m }
            let user = server.username, pass = password
            m.url = SMBURL.address(host: host, path: ref.id, user: user, password: pass)
            m.subtitles = m.subtitles.map { s in
                guard s.url.hasPrefix("smb:"), let path = URL(string: s.url)?.path else { return s }
                var t = s
                t.url = SMBURL.address(host: host, path: path, user: user, password: pass)
                return t
            }
        }
        return m
    }

    /// An SMB file to play, its subtitle files given; without the password.
    static func smbItem(server: MediaServer, path: String, name: String, cleanTitles: Bool, subtitles: [(path: String, name: String)] = []) -> MediaItem {
        let host = server.smbHost ?? ""
        let folder = (SMBURL.parent(path) as NSString).lastPathComponent
        var m = MediaItem(url: SMBURL.address(host: host, path: path),
                          title: cleanTitles ? TitleParser.clean(name) : (name as NSString).deletingPathExtension,
                          subtitle: folder.isEmpty ? nil : folder, source: .url)
        m.historyKey = historyKey(kind: .smb, server: server.id, item: path)
        m.remote = ServerItemRef(kind: .smb, serverID: server.id, id: path, parent: SMBURL.parent(path))
        let parsed = TitleParser.parse(name)
        if parsed.episode != nil { m.anime = AnimeHint(title: parsed.title, episode: parsed.episode) }
        m.subtitles = subtitles.map { ExternalSubtitle(url: SMBURL.address(host: host, path: $0.path), lang: nil, title: $0.name) }
        return m
    }

    /// Subtitle files whose names start with the video's ("Film.en.srt" for "Film.mkv").
    static func matchingSubtitles(for name: String, in names: [String]) -> [String] {
        // "Ep 1.mkv" doesn't take "Ep 10.srt" (review, 5 Nov; WebDAV's rule since 1.20.3).
        names.filter { TitleParser.isSubtitle($0) && SubtitleMatch.belongs($0, to: name) }
    }
}

/// Continue Watching for server items: the rest of the season or folder,
/// as ContinueQueue does for WebDAV.
enum ServerQueue {
    @MainActor
    static func build(_ item: MediaItem) async -> ([MediaItem], Int)? {
        guard let ref = item.remote, let parent = ref.parent, let server = MediaServerStore.shared.server(id: ref.serverID) else { return nil }
        // Episodes only (1.30.4): a film's parent was its whole library (a
        // folder of films on SMB), listed again to queue every film after it.
        // Items get an episode hint only as episodes.
        guard item.anime != nil else { return nil }
        let clean = UserDefaults.standard.object(forKey: SettingsKey.cleanTitles) as? Bool ?? true
        let device = JellyfinAPI.deviceModel
        // Don't keep the user waiting on a slow server: 4 s, then the one file.
        let built: [MediaItem]? = await withTaskGroup(of: [MediaItem]?.self) { g in
            g.addTask { try? await siblings(server: server, ref: ref, parent: parent, clean: clean, device: device) }
            g.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        guard let list = built, list.count > 1, let index = list.firstIndex(where: { $0.id == item.id }) else { return nil }
        var queue = list
        queue[index] = item             // keeps its resume point and hints
        return (queue, index)
    }

    private static func siblings(server: MediaServer, ref: ServerItemRef, parent: String, clean: Bool, device: String) async throws -> [MediaItem] {
        switch ref.kind {
        case .jellyfin:
            guard let c = JellyfinClient(server: server, device: device) else { return [] }
            let entries = try await c.children(at: parent, episodes: true).filter(\.isPlayable)
            return CatalogOrder.sorted(entries, by: .name, ascending: true).map { JellyfinClient.mediaItem(for: $0, parent: parent, server: server, base: c.base) }
        case .plex:
            guard let c = PlexClient(server: server) else { return [] }
            let entries = try await c.children(at: parent).filter(\.isPlayable)
            return CatalogOrder.sorted(entries, by: .name, ascending: true).map { PlexClient.mediaItem(for: $0, parent: parent, server: server, base: c.base) }
        case .smb:
            guard let c = SMBClient.shared(for: server) else { return [] }
            let entries = try await c.list(parent)
            let names = entries.filter { $0.kind == .file }.map(\.name)
            return names.filter(TitleParser.isMedia)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { name in
                    let subs = ServerPlayback.matchingSubtitles(for: name, in: names).map { (path: SMBPath.join(parent, $0), name: $0) }
                    return ServerPlayback.smbItem(server: server, path: SMBPath.join(parent, name), name: name, cleanTitles: clean, subtitles: subs)
                }
        }
    }
}

enum SMBPath {
    /// "/" + "Media" → "/Media"; "/Media" + "Film.mkv" → "/Media/Film.mkv".
    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}
