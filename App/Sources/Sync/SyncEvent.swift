import Foundation

/// Something you finished watching, as the sync services need it (1.26.0).
struct SyncEvent: Codable, Hashable, Sendable {
    /// For the log and Settings' last-sent line.
    var title: String
    /// The film's or show's IMDb id ("tt…"), when known.
    var imdb: String?
    var season: Int?
    var episode: Int?
    /// A film (no episode).
    var isMovie: Bool
    /// An anime's title and episode number, and any anime database ids known.
    var anime: AnimeHint?
    /// Animation per IMDb, a fansub's file name, or an anime database id:
    /// worth looking up on AniList and MyAnimeList.
    var looksLikeAnime: Bool
    var watchedAt: Date

    /// One line for the log: "The Gentlemen S2E1", "Frieren E5".
    var label: String {
        if isMovie { return title }
        if let s = season, let e = episode { return "\(title) S\(s)E\(e)" }
        if let e = anime?.episode ?? episode { return "\(title) E\(e)" }
        return title
    }

    /// Two events for the same episode or film.
    var key: String { "\(imdb ?? anime?.title ?? title)|\(season ?? 0)|\(episode ?? anime?.episode ?? 0)" }
}
