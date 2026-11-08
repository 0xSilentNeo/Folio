import Foundation

/// A title saved to watch later (1.26.0): what its tile needs, kept as it
/// was when it was added, so the list shows at once, offline too.
struct WatchlistItem: Codable, Identifiable, Hashable, Sendable {
    /// The title's id: an IMDb id ("tt…"), or "anilist:…", "tmdb:…", an addon's.
    var id: String
    var type: String
    var name: String
    var poster: String?
    var background: String?
    var year: String?
    var rating: String?
    var genres: [String]?
    var added: Date

    init(meta: MetaItem, added: Date = Date()) {
        id = meta.id
        type = meta.type
        name = meta.name
        poster = meta.poster
        background = meta.background
        year = meta.releaseInfo
        rating = meta.imdbRating
        genres = meta.genres
        self.added = added
    }

    /// The tile and the title page's starting point.
    var meta: MetaItem {
        var m = MetaItem(id: id, type: type, name: name, poster: poster, description: nil, releaseInfo: year, imdbRating: rating, genres: genres)
        m.background = background
        return m
    }

    var isSeries: Bool { type != "movie" }
}
