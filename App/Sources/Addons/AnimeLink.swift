import Foundation

/// An AniList anime's IMDb title (1.26.0), for the title page: details,
/// episodes and streams all go by IMDb ids. Found by IMDb's search on the
/// English and the romaji title, a season's own words left out ("Season 2",
/// "Part 2", "2nd Season": IMDb lists a show once, with all its seasons).
enum AnimeLink {
    private static var found: [String: String] = [:]

    @MainActor
    static func imdbID(for meta: MetaItem) async -> String? {
        if let hit = found[meta.id] { return hit }
        // The show's own name first ("Blue Box", not "Blue Box Season 2"),
        // English then romaji. A result counts only when its name is the
        // one asked for: IMDb's first series for "Blue Box Season 2" was
        // "Blues of War Season 2" (simulator, 9 Nov). No match: the page
        // keeps AniList's details rather than another show's.
        var names: [String] = []
        for n in [meta.name, meta.originalName].compactMap({ $0 }) {
            for q in [showName(n), n] where !q.isEmpty && !names.contains(q) { names.append(q) }
        }
        let wanted = Set(names.map(normalized))
        for q in names {
            let results = await IMDbSource.search(q)
            if let pick = results.first(where: { $0.type == "series" && wanted.contains(normalized($0.name)) }) {
                found[meta.id] = pick.id
                dlog("discover", "anime \(meta.name): IMDb \(pick.id) (\(pick.name)) by \"\(q)\"")
                return pick.id
            }
        }
        dlog("discover", "anime \(meta.name): no IMDb title of that name")
        return nil
    }

    /// Letters and digits only, lowercased: "Frieren: Beyond Journey’s End" = "frierenbeyondjourneysend".
    static func normalized(_ s: String) -> String {
        String(s.lowercased().folding(options: .diacriticInsensitive, locale: nil).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The show's name without the season's own words.
    static func showName(_ name: String) -> String {
        var s = name
        let patterns = [
            "\\s*[:\\-–]?\\s*(Season|Part|Cour)\\s+\\d+.*$",
            "\\s*[:\\-–]?\\s*\\d+(st|nd|rd|th)\\s+(Season|Part|Cour).*$",
            "\\s*[:\\-–]?\\s*(Final Season|The Final Chapters?).*$",
            "\\s+(II|III|IV|V)$",
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
