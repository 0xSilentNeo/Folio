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

    static func parse(_ rawName: String) -> Parsed {
        var name = rawName
        let ext = (name as NSString).pathExtension.lowercased()
        if mediaExtensions.contains(ext) || subtitleExtensions.contains(ext) {
            name = (name as NSString).deletingPathExtension
        }

        var resolution: String?
        if let r = firstMatch(#"(?i)\b(2160p|1080p|720p|480p|4k)\b"#, in: name) { resolution = r.uppercased() == "4K" ? "2160p" : r.lowercased() }

        // Drop bracketed groups: [SubsPlease], (1080p), {tags}
        name = name.replacingOccurrences(of: #"\[[^\]]*\]|\{[^}]*\}"#, with: " ", options: .regularExpression)

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

        return Parsed(title: title, season: season, episode: episode, year: year, resolution: resolution)
    }

    /// Short display title, e.g. "Frieren · S01E05" or "Dune (2021)".
    static func clean(_ rawName: String) -> String {
        let p = parse(rawName)
        var s = p.title
        if let e = p.episode {
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
