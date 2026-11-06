import Foundation

struct ExternalSubtitle: Codable, Hashable {
    var url: String
    var lang: String?
    var title: String?
}

/// Hints for intro/outro lookup.
struct AnimeHint: Codable, Hashable {
    var title: String?
    var episode: Int?
    var malId: Int?
    var anilistId: Int?
    var kitsuId: Int?
    var anidbId: Int?

    /// Known to be anime: an anime database's id, not just a title and number.
    var hasAnimeID: Bool { malId != nil || anilistId != nil || kitsuId != nil || anidbId != nil }
}

/// Saved in history, so a new case here must still read old entries.
/// SMB, Jellyfin and Plex items are `.url` with a `remote` reference (1.20.3,
/// 2 Nov): a new case would need every switch over sources to learn it
/// (Continue Watching, Home's icons) in the same change.
enum MediaSource: Codable, Hashable {
    case local
    case url
    case webdav(serverID: UUID)
    case addon(name: String)
}

/// Where an item lives on an SMB share, a Jellyfin server or a Plex server
/// (1.20.3, 2 Nov). The login stays in the Keychain: preparedForPlayback adds
/// it back, and it is left out whenever the item is saved (history).
struct ServerItemRef: Codable, Hashable {
    /// Also MediaServer.Kind.
    enum Kind: String, Codable, CaseIterable { case smb, jellyfin, plex }
    var kind: Kind
    var serverID: UUID
    /// The item on its server: a Jellyfin item id, a Plex rating key, or an
    /// SMB path from the share ("/Media/Films/Dune.mkv").
    var id: String
    /// Plex: the file to play ("/library/parts/…"). It changes when the file
    /// is replaced, so it isn't the history key.
    var part: String?
    /// Where the item's siblings are listed (its season or folder), so
    /// Continue Watching can play on with the rest of them.
    var parent: String?

    /// Headers that carry a server's login.
    static let secretHeaders: Set<String> = ["authorization", "x-emby-token", "x-mediabrowser-token", "x-plex-token"]

    /// `address` without a password (SMB plays from smb://user:pass@host/…).
    static func withoutPassword(_ address: String) -> String {
        guard var c = URLComponents(string: address), c.password != nil else { return address }
        c.password = nil
        return c.string ?? address
    }
}

struct MediaItem: Codable, Hashable, Identifiable {
    var id: String { historyKey ?? url }

    var url: String
    var title: String
    var subtitle: String?
    var artwork: String?
    var headers: [String: String] = [:]
    var subtitles: [ExternalSubtitle] = []
    var source: MediaSource = .url
    var anime: AnimeHint?
    /// Security-scoped bookmark for files opened from outside the sandbox.
    var bookmark: Data?
    /// Stable key for resume/history (e.g. addon video id) when the URL is
    /// a short-lived stream link.
    var historyKey: String?
    /// Re-openable reference for addon items: "<type>|<metaId>|<videoId>".
    var addonRef: String?
    var durationHint: Double?
    /// Play Season: an episode whose stream is resolved when its turn comes.
    var streamPick: StreamPick?
    /// An SMB, Jellyfin or Plex item (1.20.3). Optional, so history saved
    /// before it still reads.
    var remote: ServerItemRef?

    init(url: String, title: String, subtitle: String? = nil, source: MediaSource = .url) {
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.source = source
    }

    var resolvedURL: URL? {
        if let bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return u
            }
        }
        if url.hasPrefix("/") {
            let u = URL(fileURLWithPath: url)
            // The app's container path changes on reinstall; a library file is
            // found again by name under the current Documents/Media.
            if !FileManager.default.fileExists(atPath: u.path), url.contains("/Documents/") {
                let rel = url.components(separatedBy: "/Documents/").last ?? u.lastPathComponent
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let candidate = docs.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                let byName = MPVFiles.mediaDir.appendingPathComponent(u.lastPathComponent)
                if FileManager.default.fileExists(atPath: byName.path) { return byName }
            }
            return u
        }
        return URL(string: url)
    }

    /// Path/URL string handed to mpv.
    var mpvPath: String {
        guard let u = resolvedURL else { return url }
        return u.isFileURL ? u.path : u.absoluteString
    }

    /// Re-attaches credentials that are not persisted in history.
    @MainActor
    func preparedForPlayback() -> MediaItem {
        var m = self
        if case .webdav(let id) = source, let server = ServerStore.shared.server(id: id), let auth = server.authHeader {
            m.headers["Authorization"] = auth
        }
        if let remote { m = ServerPlayback.prepared(m, remote) }
        return m
    }

    /// The item as it may be written down: a server item without its token
    /// headers or the password in its address and subtitle addresses.
    var withoutServerLogin: MediaItem {
        guard remote != nil else { return self }
        var m = self
        m.headers = m.headers.filter { !ServerItemRef.secretHeaders.contains($0.key.lowercased()) }
        m.url = ServerItemRef.withoutPassword(m.url)
        m.subtitles = m.subtitles.map { var s = $0; s.url = ServerItemRef.withoutPassword(s.url); return s }
        return m
    }

    /// Written by hand only to leave a server item's login out
    /// (`withoutServerLogin`): history is a plain file, and the player saves
    /// the item it plays, login included. Reading stays synthesized. Every
    /// stored property must be written here (MediaItemCodingTests checks).
    func encode(to encoder: Encoder) throws {
        let m = withoutServerLogin
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(m.url, forKey: .url)
        try c.encode(m.title, forKey: .title)
        try c.encodeIfPresent(m.subtitle, forKey: .subtitle)
        try c.encodeIfPresent(m.artwork, forKey: .artwork)
        try c.encode(m.headers, forKey: .headers)
        try c.encode(m.subtitles, forKey: .subtitles)
        try c.encode(m.source, forKey: .source)
        try c.encodeIfPresent(m.anime, forKey: .anime)
        try c.encodeIfPresent(m.bookmark, forKey: .bookmark)
        try c.encodeIfPresent(m.historyKey, forKey: .historyKey)
        try c.encodeIfPresent(m.addonRef, forKey: .addonRef)
        try c.encodeIfPresent(m.durationHint, forKey: .durationHint)
        try c.encodeIfPresent(m.streamPick, forKey: .streamPick)
        try c.encodeIfPresent(m.remote, forKey: .remote)
    }

    var displayTitle: String { title.isEmpty ? (resolvedURL?.lastPathComponent ?? url) : title }
    /// The file's own name (last path component, percent-decoded).
    var fileName: String {
        let name = resolvedURL?.lastPathComponent ?? (url as NSString).lastPathComponent
        return name.isEmpty ? displayTitle : (name.removingPercentEncoding ?? name)
    }
}
