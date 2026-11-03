import Foundation

/// Home's library filters (1.22.0): watched state, genre and year, next to
/// the sort menu. Saved like the sort (AppStorage), so they stay set.
///
/// Genre and year are the library metadata's (MetadataService, read
/// through LibraryMetaIndex); the year falls back to the one in the
/// release's name, as the title page shows it. A title with neither is
/// under "Unknown". A folder of different titles is shown when any title in
/// it matches.
struct LibraryFilter: Equatable {
    enum Watch: String, CaseIterable, Identifiable {
        case all, unwatched, inProgress, watched
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .unwatched: return "Unwatched"
            case .inProgress: return "In Progress"
            case .watched: return "Watched"
            }
        }
        var icon: String {
            switch self {
            case .all: return "square.stack"
            case .unwatched: return "circle"
            case .inProgress: return "circle.lefthalf.filled"
            case .watched: return "eye"
            }
        }
    }

    static let unknown = "Unknown"

    var watch: Watch = .all
    /// nil: any genre; `unknown`: titles without one.
    var genre: String?
    /// nil: any year; `unknown`: titles without one.
    var year: String?

    /// From what AppStorage keeps ("" is "any").
    init(watch: String, genre: String, year: String) {
        self.watch = Watch(rawValue: watch) ?? .all
        self.genre = genre.isEmpty ? nil : genre
        self.year = year.isEmpty ? nil : year
    }
    init(watch: Watch = .all, genre: String? = nil, year: String? = nil) {
        self.watch = watch; self.genre = genre; self.year = year
    }

    var isActive: Bool { watch != .all || genre != nil || year != nil }

    /// "Unwatched · Comedy · 2019": what the active chip says.
    var summary: String {
        [watch == .all ? nil : watch.title, genre.map { $0 == Self.unknown ? "Unknown genre" : $0 },
         year.map { $0 == Self.unknown ? "Unknown year" : $0 }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Matching

    /// What the filters look at for one title.
    struct Facts: Equatable {
        enum Watch: Equatable { case unwatched, inProgress, watched }
        var watch: Watch
        var genres: [String] = []
        var year: String?
    }

    func matches(_ f: Facts) -> Bool {
        switch watch {
        case .all: break
        case .unwatched: guard f.watch == .unwatched else { return false }
        case .inProgress: guard f.watch == .inProgress else { return false }
        case .watched: guard f.watch == .watched else { return false }
        }
        if let genre {
            if genre == Self.unknown { guard f.genres.isEmpty else { return false } }
            else { guard f.genres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) else { return false } }
        }
        if let year {
            if year == Self.unknown { guard f.year == nil else { return false } }
            else { guard f.year == year else { return false } }
        }
        return true
    }

    /// A folder's titles: shown when any of them matches.
    func matches(any facts: [Facts]) -> Bool { facts.contains(where: matches) }

    /// Every file watched: watched. One part-way, or some watched and some
    /// not: in progress. Nothing started: unwatched.
    static func watchState(watched: [Bool], resumable: [Bool]) -> Facts.Watch {
        guard !watched.isEmpty else { return .unwatched }
        if watched.allSatisfy({ $0 }) { return .watched }
        if resumable.contains(true) || watched.contains(true) { return .inProgress }
        return .unwatched
    }

    /// The year as the filter lists it: the first four digits of the
    /// metadata's ("2017–2023" is 2017), else the release name's.
    static func year(meta: String?, fileName: String?) -> String? {
        if let m = meta, let r = m.range(of: #"\d{4}"#, options: .regularExpression) { return String(m[r]) }
        return fileName.flatMap { TitleParser.parse($0).year }.map(String.init)
    }

    // MARK: Menus

    /// The genres in the library, A to Z, Unknown last (only when a title has none).
    static func genres(in facts: [Facts]) -> [String] {
        var seen: [String: String] = [:]
        for f in facts { for g in f.genres where seen[g.lowercased()] == nil { seen[g.lowercased()] = g } }
        let list = seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return list + (facts.contains { $0.genres.isEmpty } ? [unknown] : [])
    }

    /// The years in the library, newest first, Unknown last.
    static func years(in facts: [Facts]) -> [String] {
        let list = Set(facts.compactMap(\.year)).sorted(by: >)
        return list + (facts.contains { $0.year == nil } ? [unknown] : [])
    }

    /// Why nothing is shown, in a sentence.
    func emptyMessage(kidsHidden: Int) -> String {
        var what = "titles"
        switch watch {
        case .all: break
        case .unwatched: what = "unwatched titles"
        case .inProgress: what = "titles in progress"
        case .watched: what = "watched titles"
        }
        var s = "No \(what)"
        if let genre { s += genre == Self.unknown ? " without a genre" : " in \(genre)" }
        if let year { s += year == Self.unknown ? " without a year" : " from \(year)" }
        s += "."
        if kidsHidden > 0 { s += " The kids profile hides \(kidsHidden) more." }
        return s
    }
}
