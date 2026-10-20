import Foundation

// Stremio addon protocol models (https://github.com/Stremio/stremio-addon-sdk/tree/master/docs/api).
// Decoding is deliberately lenient: community addons vary a lot.

private extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
    func flexInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }
    func flexStrings(_ key: Key) -> [String]? {
        if let a = try? decodeIfPresent([String].self, forKey: key) { return a }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return [s] }
        return nil
    }
}

struct AddonManifest: Codable, Hashable {
    struct Resource: Codable, Hashable {
        var name: String
        var types: [String]?
        var idPrefixes: [String]?

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                name = s; types = nil; idPrefixes = nil
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            types = c.flexStrings(.types)
            idPrefixes = c.flexStrings(.idPrefixes)
        }
    }

    struct Extra: Codable, Hashable {
        var name: String
        var isRequired: Bool?
        var options: [String]?
    }

    struct Catalog: Codable, Hashable {
        var type: String
        var id: String
        var name: String?
        var extra: [Extra]?
        var extraRequired: [String]?
        var extraSupported: [String]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            id = try c.decode(String.self, forKey: .id)
            name = c.flexString(.name)
            extra = try? c.decodeIfPresent([Extra].self, forKey: .extra)
            extraRequired = c.flexStrings(.extraRequired)
            extraSupported = c.flexStrings(.extraSupported)
        }

        var requiredExtras: Set<String> {
            Set((extra ?? []).filter { $0.isRequired == true }.map(\.name) + (extraRequired ?? []))
        }
        var supportsSearch: Bool {
            (extra ?? []).contains { $0.name == "search" } || (extraSupported ?? []).contains("search")
        }
        var genreOptions: [String] {
            (extra ?? []).first { $0.name == "genre" }?.options ?? []
        }
        /// Shown on the Discover page (needs no required extras).
        var isBrowsable: Bool { requiredExtras.isEmpty || requiredExtras == ["genre"] && !genreOptions.isEmpty }
    }

    var id: String
    var version: String?
    var name: String
    var description: String?
    var logo: String?
    var types: [String]
    var catalogs: [Catalog]
    var resources: [Resource]
    var idPrefixes: [String]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = c.flexString(.version)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        description = c.flexString(.description)
        logo = c.flexString(.logo)
        types = c.flexStrings(.types) ?? []
        catalogs = (try? c.decodeIfPresent([Catalog].self, forKey: .catalogs)) ?? []
        resources = (try? c.decodeIfPresent([Resource].self, forKey: .resources)) ?? []
        idPrefixes = c.flexStrings(.idPrefixes)
    }

    func supports(resource: String, type: String, id: String) -> Bool {
        for r in resources where r.name == resource {
            let types = r.types ?? self.types
            let prefixes = r.idPrefixes ?? self.idPrefixes
            guard types.isEmpty || types.contains(type) else { continue }
            if let prefixes, !prefixes.isEmpty, !prefixes.contains(where: { id.hasPrefix($0) }) { continue }
            return true
        }
        return false
    }

    func has(resource: String) -> Bool { resources.contains { $0.name == resource } }
}

struct InstalledAddon: Codable, Identifiable, Hashable {
    var id: String { transportURL }
    var transportURL: String      // .../manifest.json
    var manifest: AddonManifest

    var baseURL: String {
        var s = transportURL
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        return s
    }
}

struct MetaVideo: Codable, Hashable, Identifiable {
    var id: String
    var title: String?
    var season: Int?
    var episode: Int?
    var released: String?
    var thumbnail: String?
    var overview: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.flexString(.title) ?? c.flexString(.name)
        season = c.flexInt(.season)
        episode = c.flexInt(.episode) ?? c.flexInt(.number)
        released = c.flexString(.released)
        thumbnail = c.flexString(.thumbnail)
        overview = c.flexString(.overview) ?? c.flexString(.description)
    }

    enum CodingKeys: String, CodingKey { case id, title, name, season, episode, number, released, thumbnail, overview, description }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(released, forKey: .released)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encodeIfPresent(overview, forKey: .overview)
    }

    var label: String {
        if let s = season, let e = episode { return "S\(s) · E\(e)" + (title.map { " — \($0)" } ?? "") }
        return title ?? id
    }
}

struct MetaItem: Codable, Hashable, Identifiable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var posterShape: String?
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var imdbRating: String?
    var runtime: String?
    var genres: [String]?
    var videos: [MetaVideo]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decode(String.self, forKey: .type)) ?? "movie"
        name = c.flexString(.name) ?? id
        poster = c.flexString(.poster)
        posterShape = c.flexString(.posterShape)
        background = c.flexString(.background)
        logo = c.flexString(.logo)
        description = c.flexString(.description)
        releaseInfo = c.flexString(.releaseInfo) ?? c.flexString(.year)
        imdbRating = c.flexString(.imdbRating)
        runtime = c.flexString(.runtime)
        genres = c.flexStrings(.genres) ?? c.flexStrings(.genre)
        videos = try? c.decodeIfPresent([MetaVideo].self, forKey: .videos)
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description, releaseInfo, year, imdbRating, runtime, genres, genre, videos
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encodeIfPresent(posterShape, forKey: .posterShape)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try c.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(genres, forKey: .genres)
        try c.encodeIfPresent(videos, forKey: .videos)
    }

    var isAnime: Bool {
        id.hasPrefix("kitsu:") || id.hasPrefix("mal:") || id.hasPrefix("anilist:") || id.hasPrefix("anidb:")
            || (genres ?? []).contains { $0.lowercased() == "anime" }
    }

    var seasons: [Int] {
        Array(Set((videos ?? []).compactMap(\.season))).sorted { a, b in
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }
    }
}

struct AddonStream: Codable, Hashable, Identifiable {
    struct Hints: Codable, Hashable {
        struct ProxyHeaders: Codable, Hashable {
            var request: [String: String]?
        }
        var notWebReady: Bool?
        var bingeGroup: String?
        var filename: String?
        var videoSize: Double?
        var proxyHeaders: ProxyHeaders?
    }
    struct Sub: Codable, Hashable {
        var id: String?
        var url: String
        var lang: String?
    }

    var id: String { (url ?? infoHash ?? externalUrl ?? "") + (name ?? "") + (title ?? "") }
    var url: String?
    var ytId: String?
    var infoHash: String?
    var fileIdx: Int?
    var externalUrl: String?
    var name: String?
    var title: String?
    var description: String?
    var behaviorHints: Hints?
    var subtitles: [Sub]?

    enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, fileIdx, externalUrl, name, title, description, behaviorHints, subtitles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.flexString(.url)
        ytId = c.flexString(.ytId)
        infoHash = c.flexString(.infoHash)
        fileIdx = c.flexInt(.fileIdx)
        externalUrl = c.flexString(.externalUrl)
        name = c.flexString(.name)
        title = c.flexString(.title)
        description = c.flexString(.description)
        behaviorHints = try? c.decodeIfPresent(Hints.self, forKey: .behaviorHints)
        subtitles = try? c.decodeIfPresent([Sub].self, forKey: .subtitles)
    }

    var isPlayable: Bool { url != nil }
    var displayTitle: String { (description ?? title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var displayName: String { (name ?? "Stream").replacingOccurrences(of: "\n", with: " ") }
}

struct AddonSubtitle: Codable, Hashable {
    var id: String?
    var url: String
    var lang: String?
}
