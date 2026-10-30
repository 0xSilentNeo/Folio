import Foundation
import SwiftUI

/// Which film or series a release folder is, for its poster in the
/// Real-Debrid library (and the collage of Home's Real-Debrid entry).
///
/// The scoring is the WebDAV browser script's (webdav-browser-posters.lua,
/// PS.pick, lines 5519-5554): an exact name (or original name) scores 3, a
/// related one (one contains the other, 4+ letters) 1; the same year +2, a
/// year apart +1; the kind the release looks like (a season or episode
/// marker: series; a year and none: film) +1.5; TMDB's popularity up to
/// +0.9; anime releases: TMDB's Animation genre +2, Japanese +0.5.
///
/// The candidates come from TMDB's /search/multi when a TMDB key is set
/// (what the script searches), else from IMDb's search (the library's own
/// source). Differences from the script, and why:
/// - A minimum confidence (the script has none and always shows its closest
///   result): an exact name with a year that agrees (or no year to check), or
///   a related name with the same year and the right kind. An exact name
///   shared by several titles of the same kind, with no year to choose, is
///   a match only when TMDB rates one at least 3× as popular as the next.
///   Anything else gets the placeholder, and the log says why.
/// - No AniList and no box sets (another provider; collections need their
///   own lookups).
/// - "Anime" is a release named the fansub way ("[Group] Title …").
enum ReleaseMatch {
    enum Kind: String, Codable, Sendable { case movie, series }

    struct Candidate: Sendable {
        let id: String              // "tt…" (IMDb) or "tmdb:<movie|tv>:<id>"
        let name: String
        let originalName: String?
        let year: Int?
        let kind: Kind
        let popularity: Double
        let poster: String?
        let animation: Bool
        let japanese: Bool
    }

    struct Result: Codable, Equatable, Sendable {
        var imdbID: String?
        var name: String?
        var year: Int?
        var poster: String?
        var score: Double
        var source: String
        var confident: Bool
        /// Why it is (or isn't) a match, for the log.
        var why: String
        var date: Date
    }

    /// Lower-cased letters and digits only, accents folded, "&" read as
    /// "and" (PS.norm / PS.pnorm).
    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    static func kind(of r: ReleaseName) -> Kind? {
        if r.label != nil { return .series }
        if r.year != nil { return .movie }
        return nil
    }

    /// The best candidate and whether it's a confident match.
    static func pick(_ release: ReleaseName, _ candidates: [Candidate], source: String, now: Date = Date()) -> Result {
        let want = norm(release.title)
        let year = release.year.flatMap(Int.init)
        let kind = kind(of: release)
        let anime = release.raw.hasPrefix("[")
        struct Scored { let c: Candidate; let score: Double; let exact: Bool; let related: Bool }
        let scored: [Scored] = candidates.filter { $0.poster != nil }.map { c in
            let nm = norm(c.name), on = norm(c.originalName ?? "")
            let exact = nm == want || (!on.isEmpty && on == want)
            let related = exact || (want.count >= 4 && ((!nm.isEmpty && (nm.contains(want) || want.contains(nm)))
                                                       || (!on.isEmpty && (on.contains(want) || want.contains(on)))))
            var score: Double = exact ? 3 : related ? 1 : 0
            if anime { score += (c.animation ? 2 : 0) + (c.japanese ? 0.5 : 0) }
            if let year, let cy = c.year { score += cy == year ? 2 : abs(cy - year) == 1 ? 1 : 0 }
            if let kind, c.kind == kind { score += 1.5 }
            score += min(0.9, c.popularity / 1000)
            return Scored(c: c, score: score, exact: exact, related: related)
        }
        // Highest score; ties keep the source's own order (as the script does).
        guard let best = scored.enumerated().max(by: { a, b in a.element.score < b.element.score || (a.element.score == b.element.score && a.offset > b.offset) })?.element,
              best.related else {
            return Result(imdbID: nil, name: nil, year: nil, poster: nil, score: 0, source: source, confident: false,
                          why: candidates.isEmpty ? "no results" : "no result with that name", date: now)
        }
        let yearDiff = year.flatMap { y in best.c.year.map { abs($0 - y) } }
        var confident = false
        var why: String
        if best.exact {
            if let d = yearDiff, d > 1 {
                why = "exact name but \(best.c.year!) vs \(year!)"
            } else if year == nil {
                // No year to choose between titles of the same name.
                let same = scored.filter { $0.exact && (kind == nil || $0.c.kind == kind) }.sorted { $0.c.popularity > $1.c.popularity }
                if same.count <= 1 {
                    confident = true; why = "exact name, the only one"
                } else if source == "TMDB", same[0].c.id == best.c.id, same[0].c.popularity >= 3 * max(same[1].c.popularity, 0.001) {
                    confident = true; why = "exact name, \(same.count) titles, this one far more popular"
                } else {
                    why = "\(same.count) titles with this name and no year to choose"
                }
            } else {
                confident = true; why = yearDiff == 0 ? "exact name and year" : "exact name, a year apart"
            }
        } else if yearDiff == 0, let kind, best.c.kind == kind {
            confident = true; why = "related name, same year and kind"
        } else {
            why = "only a related name (\(best.c.name))"
        }
        return Result(imdbID: best.c.id.hasPrefix("tt") ? best.c.id : nil, name: best.c.name, year: best.c.year, poster: best.c.poster,
                      score: (best.score * 10).rounded() / 10, source: source, confident: confident,
                      why: why + String(format: ", score %.1f", best.score), date: now)
    }
}

/// Looks releases up (at most 4 at once) and keeps what was found, on disk
/// in Application Support/ReleaseMatches.json: a release is looked up once,
/// a release with no confident match again after 3 days.
actor ReleaseMatcher {
    static let shared = ReleaseMatcher()

    private var cache: [String: ReleaseMatch.Result] = [:]
    private var inflight: [String: Task<ReleaseMatch.Result?, Never>] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let file: URL
    private var dirty = false

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("ReleaseMatches.json")
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([String: ReleaseMatch.Result].self, from: d) { cache = c }
    }

    static func key(_ r: ReleaseName) -> String {
        [ReleaseMatch.norm(r.title), r.year ?? "", ReleaseMatch.kind(of: r)?.rawValue ?? ""].joined(separator: "|")
    }

    /// What was found before, without asking anyone (Home at launch).
    func saved(_ r: ReleaseName) -> ReleaseMatch.Result? { cache[Self.key(r)] }

    func match(_ r: ReleaseName) async -> ReleaseMatch.Result? {
        let key = Self.key(r)
        let preferred = TMDB.enabled ? "TMDB" : "IMDb"
        if let hit = cache[key] {
            let retry = !hit.confident && (Date().timeIntervalSince(hit.date) > 3 * 86400 || hit.source != preferred)
            if !retry { return hit }
        }
        if let t = inflight[key] { return await t.value }
        let t = Task<ReleaseMatch.Result?, Never> {
            await acquire()
            let result = await Self.lookUp(r)
            release()
            return result
        }
        inflight[key] = t
        let result = await t.value
        inflight[key] = nil
        if let result {
            cache[key] = result
            save()
            dlog("poster", "'\(r.titleWithYear)'\(ReleaseMatch.kind(of: r).map { " (\($0.rawValue))" } ?? ""): \(result.source) "
                 + (result.confident ? "→ \(result.name ?? "?") \(result.year.map(String.init) ?? "") \(result.imdbID ?? "") — \(result.why)"
                                     : "no confident match — \(result.why); placeholder"))
        }
        return result
    }

    private func acquire() async {
        if running < 4 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    /// nil when the search itself failed (offline): nothing is kept then.
    private static func lookUp(_ r: ReleaseName) async -> ReleaseMatch.Result? {
        if TMDB.enabled {
            guard let results = await TMDB.searchMulti(r.title) else { return nil }
            let candidates = results.map { t in
                ReleaseMatch.Candidate(id: "tmdb:\(t.isMovie ? "movie" : "tv"):\(t.id)", name: t.name, originalName: t.originalName, year: t.year,
                                       kind: t.isMovie ? .movie : .series, popularity: t.popularity, poster: t.poster,
                                       animation: t.isAnimation, japanese: t.japanese)
            }
            var result = ReleaseMatch.pick(r, candidates, source: "TMDB")
            // Posters are kept by IMDb id: the same title on Home and here shares one.
            if result.confident, let best = candidates.first(where: { $0.name == result.name && $0.year == result.year && $0.poster == result.poster }) {
                let parts = best.id.split(separator: ":")
                if parts.count == 3, let id = Int(parts[2]) { result.imdbID = await TMDB.imdbID(tmdb: id, isMovie: parts[1] == "movie") }
            }
            return result
        }
        guard let metas = try? await IMDbSource.suggest(r.title) else { return nil }
        let candidates = metas.compactMap { m -> ReleaseMatch.Candidate? in
            guard m.type == "movie" || m.type == "series" else { return nil }
            return ReleaseMatch.Candidate(id: m.id, name: m.name, originalName: m.originalName,
                                          year: m.releaseInfo.flatMap { Int($0.prefix(4)) }, kind: m.type == "movie" ? .movie : .series,
                                          popularity: 0, poster: m.poster, animation: false, japanese: false)
        }
        return ReleaseMatch.pick(r, candidates, source: "IMDb")
    }

    private func save() {
        guard !dirty else { return }
        dirty = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let d = try? JSONEncoder().encode(cache) { try? d.write(to: file, options: .atomic) }
            dirty = false
        }
    }
}

/// A release folder's poster in a list row: the matched title's poster
/// (stored by IMDb id, shared with Home), else a placeholder with the
/// title's initials — never a wrong poster, never a blank box.
struct ReleasePoster: View {
    let release: ReleaseName
    var width: CGFloat = 44
    @State private var image: UIImage?

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentSoft)
                Text(initials).font(.system(size: width * 0.34, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent)
                    .minimumScaleFactor(0.5).padding(4)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        // Only rows on screen look up (a row that scrolls away cancels its lookup).
        .task(id: release.raw) {
            guard UserDefaults.standard.bool(forKey: SettingsKey.metadataFetching) else { return }
            guard let m = await ReleaseMatcher.shared.match(release), m.confident, let poster = m.poster, let url = URL(string: poster) else { return }
            let img = await ImageCache.shared.poster(id: m.imdbID ?? poster, url: url, maxPixel: height * UIScreen.main.scale)
            guard !Task.isCancelled, let img else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
    }

    private var initials: String {
        let words = release.title.split(separator: " ").filter { !ReleaseName.smallWords.contains($0.lowercased()) }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}
