import Foundation

/// Heuristic release-name parser shared by the library (clean titles) and the
/// intro/outro lookup (title + episode).
enum TitleParser {
    struct Parsed: Equatable {
        var title: String
        var season: Int?
        var episode: Int?
        var year: Int?
        var resolution: String?
        /// A side release of the show: "OAD", "OVA", "ONA", "Special" (its
        /// episode numbers are its own, not the show's) or "Movie".
        var extra: String? = nil
        /// "Movie 02 - Jiyuu no Tsubasa": 2 and "Jiyuu no Tsubasa".
        var part: Int? = nil
        var subtitle: String? = nil
    }

    static let mediaExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "mts", "wmv", "flv", "ogv", "3gp",
        "mpg", "mpeg", "vob", "rmvb", "divx", "hevc", "iso",
        "mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "alac", "wma", "ape", "mka",
    ]
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup"]

    static func isMedia(_ name: String) -> Bool {
        mediaExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isSubtitle(_ name: String) -> Bool {
        subtitleExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Parsed] = [:]

    /// Cached: the library parses every file name on every redraw.
    static func parse(_ rawName: String) -> Parsed {
        cacheLock.lock()
        if let p = cache[rawName] { cacheLock.unlock(); return p }
        cacheLock.unlock()
        let p = parseUncached(rawName)
        cacheLock.lock()
        if cache.count > 5000 { cache.removeAll() }
        cache[rawName] = p
        cacheLock.unlock()
        return p
    }

    private static func parseUncached(_ rawName: String) -> Parsed {
        var name = rawName
        let ext = (name as NSString).pathExtension.lowercased()
        if mediaExtensions.contains(ext) || subtitleExtensions.contains(ext) {
            name = (name as NSString).deletingPathExtension
        }

        var resolution: String?
        if let r = firstMatch(#"(?i)\b(2160p|1080p|720p|480p|4k)\b"#, in: name) { resolution = r.uppercased() == "4K" ? "2160p" : r.lowercased() }

        // Drop bracketed groups: [SubsPlease], (1080p), {tags}
        name = name.replacingOccurrences(of: #"\[[^\]]*\]|\{[^}]*\}"#, with: " ", options: .regularExpression)

        // "Show Movie 01 - Name": a film of the series, not episode 1.
        if let m = match(#"(?i)^\s*(.+?)\s+(?:the\s+)?movie\s*(\d{1,2})\s*[-–:]\s*(.+?)\s*$"#, in: name) {
            let title = m.groups[0].replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–_."))
            var sub = m.groups[2].replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
            if let r = sub.range(of: #"(?i)[ \(](2160p|1080p|720p|480p|4k|web[ .-]?dl|webrip|bluray|bdrip|x264|x265|hevc)\b.*$"#, options: .regularExpression) { sub.removeSubrange(r) }
            sub = sub.trimmingCharacters(in: CharacterSet(charactersIn: " -–_."))
            if !title.isEmpty {
                return Parsed(title: title, season: nil, episode: nil, year: nil, resolution: resolution,
                              extra: "Movie", part: Int(m.groups[1]), subtitle: sub.isEmpty ? nil : sub)
            }
        }

        var season: Int?
        var episode: Int?
        var year: Int?
        var cut = name.endIndex

        func noteCut(_ r: Range<String.Index>) { if r.lowerBound < cut { cut = r.lowerBound } }

        if let m = match(#"(?i)\bS(\d{1,2})[ ._-]?E(\d{1,4})"#, in: name) {
            season = Int(m.groups[0]); episode = Int(m.groups[1]); noteCut(m.range)
        } else if let m = match(#"(?i)\b(\d{1,2})x(\d{2,3})\b"#, in: name) {
            season = Int(m.groups[0]); episode = Int(m.groups[1]); noteCut(m.range)
        } else if let m = match(#"(?i)\b(?:episode|ep|e)[ ._]?(\d{1,4})\b"#, in: name) {
            episode = Int(m.groups[0]); noteCut(m.range)
        } else if let m = match(#"\s[-–]\s(\d{1,4})(?:v\d)?(?:\s|$|\()"#, in: name) {
            // "Show - 05", "Show - 12v2"
            episode = Int(m.groups[0]); noteCut(m.range)
        }

        if let m = match(#"(?i)\bS(?:eason)?[ ._]?(\d{1,2})\b"#, in: name), season == nil {
            season = Int(m.groups[0]); noteCut(m.range)
        }

        if let m = match(#"[\(\. _](19\d{2}|20\d{2})(?:[\)\. _]|$)"#, in: name) {
            year = Int(m.groups[0])
            noteCut(m.range)
        }

        // Cut at the first technical tag.
        if let r = name.range(of: #"(?i)[ ._\(](2160p|1080p|720p|480p|4k|web[ .-]?dl|webrip|bluray|bdrip|brrip|hdtv|x264|x265|h\.?264|h\.?265|hevc|10bit|dual[ .-]audio|multi)\b"#, options: .regularExpression) {
            noteCut(r)
        }

        var title = String(name[..<cut])
        title = title.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\([^)]*\)?"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–_."))
        if title.isEmpty {
            title = (rawName as NSString).deletingPathExtension
        }

        // "Plain Title 9" style trailing number as an episode.
        if episode == nil, let m = match(#"^(.*\D)\s(\d{1,3})$"#, in: title), let n = Int(m.groups[1]), n > 0, n < 1900 {
            title = m.groups[0].trimmingCharacters(in: .whitespaces)
            episode = n
        }

        var extra: String?
        if let m = match(#"(?i)\b(OAD|OVA|ONA|Specials?)$"#, in: title) {
            let w = m.groups[0].uppercased()
            extra = w.hasPrefix("SPECIAL") ? "Special" : w
        }

        return Parsed(title: title, season: season, episode: episode, year: year, resolution: resolution, extra: extra)
    }

    /// The title without a trailing OAD / OVA / ONA / Special marker (the show it belongs to).
    static func baseTitle(_ p: Parsed) -> String {
        guard p.extra != nil, p.extra != "Movie" else { return p.title }
        return p.title.replacingOccurrences(of: #"(?i)\s*\b(OAD|OVA|ONA|Specials?)$"#, with: "", options: .regularExpression)
    }

    /// Short episode tag for lists: "S2 · E1", "E26", "OAD 5", "Movie 2".
    /// `season`/`episode`: the numbers metadata mapped an absolute episode to.
    static func tag(_ p: Parsed, season: Int? = nil, episode: Int? = nil) -> String? {
        if p.extra == "Movie" { return p.part.map { "Movie \($0)" } ?? "Movie" }
        if let x = p.extra, let e = p.episode { return "\(x) \(e)" }
        if let e = episode ?? p.episode {
            if let s = season ?? p.season { return "S\(s) · E\(e)" }
            return "E\(e)"
        }
        return nil
    }

    /// Short display title, e.g. "Frieren · S01E05" or "Dune (2021)".
    static func clean(_ rawName: String) -> String {
        let p = parse(rawName)
        var s = p.title
        if p.extra == "Movie" {
            s += " · " + (tag(p) ?? "Movie") + (p.subtitle.map { " · " + $0 } ?? "")
        } else if let e = p.episode {
            if let season = p.season {
                s += String(format: " · S%02dE%02d", season, e)
            } else {
                s += String(format: " · E%02d", e)
            }
        } else if let y = p.year {
            s += " (\(y))"
        }
        return s
    }

    // MARK: Regex helpers

    struct Match { let range: Range<String.Index>; let groups: [String] }

    static func match(_ pattern: String, in s: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: ns), let r = Range(m.range, in: s) else { return nil }
        var groups: [String] = []
        if m.numberOfRanges > 1 {
            for i in 1..<m.numberOfRanges {
                if let gr = Range(m.range(at: i), in: s) { groups.append(String(s[gr])) } else { groups.append("") }
            }
        }
        return Match(range: r, groups: groups)
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let m = match(pattern, in: s) else { return nil }
        return m.groups.first ?? String(s[m.range])
    }
}
