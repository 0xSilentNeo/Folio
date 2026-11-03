import Foundation

/// What the kids profile (1.22.0) lets through: every list in the app asks
/// this one type, so Discover, search, the library and the title pages
/// agree.
///
/// - The content rating Folio already reads (IMDb's title page, an addon's
///   meta) decides. IMDb gives the rating of the phone's region, so the
///   other systems (Australia's M, the UK's 12A, Germany's FSK 12, ages
///   like "13+") are put on one ladder with the US ones.
/// - With no rating it knows, the genres: Family or Kids, or Animation
///   (not anime) with no grown-up genre, count as "all ages".
/// - Anything else is unknown, and unknown is hidden.
enum KidsRules {
    /// The ladder every rating is put on. A film or show is let through when
    /// its level is at most the limit's.
    enum Level: Int, Comparable {
        case preschool, youngKids, allAges, parentalGuidance, teens, adults
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    enum FilmLimit: String, CaseIterable, Identifiable {
        case g = "G", pg = "PG", pg13 = "PG-13"
        var id: String { rawValue }
        var level: Level { self == .g ? .allAges : self == .pg ? .parentalGuidance : .teens }
    }

    enum ShowLimit: String, CaseIterable, Identifiable {
        case tvY = "TV-Y", tvY7 = "TV-Y7", tvG = "TV-G", tvPG = "TV-PG"
        var id: String { rawValue }
        var level: Level {
            switch self {
            case .tvY: return .preschool
            case .tvY7: return .youngKids
            case .tvG: return .allAges
            case .tvPG: return .parentalGuidance
            }
        }
    }

    struct Limits: Equatable {
        var film: FilmLimit = .pg
        var show: ShowLimit = .tvPG
        func level(isSeries: Bool) -> Level { isSeries ? show.level : film.level }
    }

    enum Verdict: Equatable {
        case allowed
        /// Rated above the limit (the rating as the title has it).
        case above(String)
        /// No rating or genre to go by.
        case unknown
    }

    // MARK: Ratings

    /// Ratings by name, after `normalized`. Numbers ("12", "16+") are ages
    /// (see `ageLevel`).
    private static let named: [String: Level] = [
        // US TV
        "TV-Y": .preschool, "TV-Y7": .youngKids, "TV-Y7-FV": .youngKids, "TV-Y7FV": .youngKids, "TV-G": .allAges,
        "TV-PG": .parentalGuidance, "TV-14": .teens, "TV-MA": .adults,
        // US films (GP and M/PG were PG's earlier names)
        "G": .allAges, "PG": .parentalGuidance, "GP": .parentalGuidance, "M/PG": .parentalGuidance,
        "PG-13": .teens, "PG13": .teens, "R": .adults, "NC-17": .adults, "NC17": .adults, "X": .adults,
        // Australia (M is "recommended for 15 and over", not restricted)
        "M": .teens, "MA15+": .adults, "R18+": .adults, "X18+": .adults,
        // UK, Ireland, Canada, New Zealand, Japan, Korea, Brazil, Spain, Belgium
        "U": .allAges, "UC": .allAges, "12A": .teens, "12PG": .teens, "15A": .adults, "16": .adults, "R18": .adults,
        "14A": .teens, "18A": .adults, "R13": .teens, "R15": .adults, "R16": .adults, "RP13": .teens, "RP16": .adults,
        "PG12": .teens, "R15+": .adults, "ALL": .allAges, "L": .allAges, "TP": .allAges, "APTA": .allAges, "AL": .allAges, "KT": .allAges,
    ]

    /// Ratings that say nothing about the content.
    private static let unrated: Set<String> = ["NOT RATED", "NOTRATED", "UNRATED", "NR", "APPROVED", "PASSED", "E", "EXEMPT", "CTC", "TBC", "N/A", "-"]

    /// "Rated PG-13", "pg-13 ", "US: PG-13", "FSK 12" → "PG-13" / "12".
    static func normalized(_ rating: String) -> String {
        var s = rating.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("RATED ") { s.removeFirst(6) }
        // A region in front ("US:", "AU: "), as some addons write it.
        if let colon = s.firstIndex(of: ":"), s.distance(from: s.startIndex, to: colon) <= 3 {
            s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        // An age with its system's name in front ("FSK 12", "K-7", "+13").
        for p in ["FSK ", "FSK-", "FSK", "BBFC ", "K-", "K", "+"] where s.hasPrefix(p) {
            let rest = String(s.dropFirst(p.count))
            if rest.first?.isNumber == true { s = rest; break }
        }
        return s.replacingOccurrences(of: " ", with: "")
    }

    /// A rating's level, or nil for one that says nothing (Not Rated) or that
    /// Folio doesn't know.
    static func level(ofRating rating: String) -> Level? {
        let s = normalized(rating)
        guard !s.isEmpty, !unrated.contains(s), !unrated.contains(rating.uppercased().trimmingCharacters(in: .whitespaces)) else { return nil }
        if let l = named[s] { return l }
        // An age: "12", "16+", "13+".
        let digits = s.hasSuffix("+") ? String(s.dropLast()) : s
        if let age = Int(digits), (0...21).contains(age) { return ageLevel(age) }
        return nil
    }

    /// Ages from the systems that use them (Germany, the Netherlands, Korea,
    /// streaming services' "7+", "13+"): 0 is for everyone, 6 to 10 is
    /// parental guidance, 11 to 14 is teens, 15 and over is adults.
    static func ageLevel(_ age: Int) -> Level {
        switch age {
        case ...5: return .allAges
        case 6...10: return .parentalGuidance
        case 11...14: return .teens
        default: return .adults
        }
    }

    // MARK: Genres

    /// Genres that keep a title out when there's no rating to go by.
    static let grownUpGenres: Set<String> = ["horror", "thriller", "crime", "war", "adult", "romance", "film-noir", "film noir"]
    static let kidsGenres: Set<String> = ["family", "kids", "children"]

    /// With no rating: "all ages" for a family or kids title, or an animated
    /// one that isn't anime, when no grown-up genre is among them.
    static func genreLevel(_ genres: [String]) -> Level? {
        let g = Set(genres.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        guard !g.isEmpty, g.isDisjoint(with: grownUpGenres) else { return nil }
        if !g.isDisjoint(with: kidsGenres) { return .allAges }
        if g.contains("animation") && !g.contains("anime") { return .allAges }
        return nil
    }

    // MARK: Verdicts

    static func verdict(rating: String?, genres: [String]?, isSeries: Bool, limits: Limits) -> Verdict {
        let limit = limits.level(isSeries: isSeries)
        if let r = rating, let l = level(ofRating: r) {
            return l <= limit ? .allowed : .above(r.trimmingCharacters(in: .whitespaces))
        }
        if let g = genres, let l = genreLevel(g) {
            return l <= limit ? .allowed : .unknown
        }
        return .unknown
    }

    static func verdict(_ m: MetaItem, limits: Limits) -> Verdict {
        verdict(rating: m.contentRating, genres: m.genres, isSeries: m.type != "movie", limits: limits)
    }

    static func verdict(_ m: MediaMeta?, limits: Limits) -> Verdict {
        guard let m else { return .unknown }
        return verdict(rating: m.contentRating, genres: m.genres, isSeries: m.type != "movie", limits: limits)
    }

    static func allows(_ m: MetaItem, limits: Limits) -> Bool { verdict(m, limits: limits) == .allowed }
    static func allows(_ m: MediaMeta?, limits: Limits) -> Bool { verdict(m, limits: limits) == .allowed }

    /// By the rating alone, with no guess from the genres: a title with no
    /// rating Folio knows (none, "Not Rated", one it can't read) is unknown.
    /// For lists that aren't asked for by a kids genre, where a genre says
    /// little: For you's titles come from the whole watch history, and an
    /// animated show can be rated 13+ or TV-MA.
    static func ratedVerdict(rating: String?, isSeries: Bool, limits: Limits) -> Verdict {
        guard let r = rating, let l = level(ofRating: r) else { return .unknown }
        return l <= limits.level(isSeries: isSeries) ? .allowed : .above(r.trimmingCharacters(in: .whitespaces))
    }

    /// The limits in words, for the lists that are filtered ("up to PG and TV-PG").
    static func summary(_ limits: Limits) -> String { "up to \(limits.film.rawValue) and \(limits.show.rawValue)" }
}
