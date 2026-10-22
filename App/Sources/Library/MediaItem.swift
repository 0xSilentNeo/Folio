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
}

enum MediaSource: Codable, Hashable {
    case local
    case url
    case webdav(serverID: UUID)
    case addon(name: String)
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
        return m
    }

    var displayTitle: String { title.isEmpty ? (resolvedURL?.lastPathComponent ?? url) : title }
}
