import Foundation

/// A release name read for display, ported from the WebDAV browser script
/// (0xSilentNeo/webdav-browser-mpv, webdav-browser-posters.lua, the `CT`
/// module): files with `CT.parse` (lines 3735-3836), folders with
/// `CT.parse_folder` (3930-4047), groups with `CT.file_group` (3839).
///
/// The one parser for what a release is called on screen: the WebDAV
/// browser, the Real-Debrid library, Search Library, Continue Watching and
/// title pages. (`TitleParser` stays the parser for a file's identity —
/// grouping episodes into shows and metadata lookups.)
///
/// Where this differs from the script, and why:
/// - Attributes: the script shows resolution, HDR/HDR10+, DV, Atmos, Remux
///   and Dual (`CT.chips_for`, 3914). These are read too, plus the source
///   (WEB-DL, BluRay…), HDR10, codec, the audio format and channels, the
///   streaming service and REPACK/PROPER, so entries can always be told
///   apart (`distinguishing`).
/// - Episode files: the script keeps a year that comes before "S01E01" in
///   the title ("Daemons of the Shadow Realm 2026"); here it becomes the
///   year, as it does for films.
/// - Patterns: Lua patterns become regular expressions with the same ASCII
///   classes (`%w` is [A-Za-z0-9], `%a` is [A-Za-z]); lower-casing is ASCII
///   only, as Lua's, so positions in the lower-cased name are positions in
///   the name.
struct ReleaseName: Hashable, Sendable {
    /// What was read: the clean title ("MobLand", "Mashle Magic and Muscles").
    var title: String
    /// Season / episode marker: "S01E03", "E05", "S02", "S01-S03", "Complete".
    var label: String?
    var year: String?
    /// Files: the episode's title from the name ("Stick or Twist").
    var episodeTitle: String?
    /// Release group: "-FLUX", "[SubsPlease]".
    var group: String?
    /// Folders: a name given first in parentheses: "(Demon Slayer) Kimetsu no Yaiba".
    var alt: String?
    var attributes: [Attribute]
    /// The name as given.
    let raw: String

    /// What kind of detail an attribute is, in the order they're shown.
    enum Kind: Int, CaseIterable, Comparable, Sendable {
        case resolution, source, hdr, dolbyVision, codec, audio, channels, service, language, edition
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    struct Attribute: Hashable, Sendable {
        let kind: Kind
        let text: String
    }

    func attribute(_ kind: Kind) -> String? { attributes.first { $0.kind == kind }?.text }

    /// "MobLand", "Dune (2021)", "Show (2026)": the title with its year.
    var titleWithYear: String { year.map { "\(title) (\($0))" } ?? title }

    // MARK: - Files (CT.parse)

    /// A file name; nil when nothing can be read from it (the script then
    /// shows the raw name).
    static func file(_ name: String) -> ReleaseName? {
        cached(name, folder: false) { parseFile(name) }
    }

    private static func parseFile(_ name: String) -> ReleaseName? {
        var base = fixChars(name)
        let ext = (base as NSString).pathExtension.lowercased()
        if TitleParser.mediaExtensions.contains(ext) { base = (base as NSString).deletingPathExtension }
        let lower = asciiLower(base)
        let ns = base as NSString

        var cut: Int?, label: String?, epFrom: Int?, year: String?
        // Season/episode token that starts a word ("class01e02" isn't one).
        if let m = find(#"(?<![a-z0-9])s(\d\d?)[._\s]?e(\d{2,4})"#, lower) {
            label = String(format: "S%02dE%02d", Int(m.groups[0]) ?? 0, Int(m.groups[1]) ?? 0)
            cut = m.start; epFrom = m.end
        }
        if label == nil, let m = find(#"(?<![a-z0-9])(\d\d?)x(\d{2,3})(?![a-z0-9])"#, lower), let s = Int(m.groups[0]), s < 60 {
            label = String(format: "S%02dE%02d", s, Int(m.groups[1]) ?? 0)
            cut = m.start; epFrom = m.end
        }
        if label == nil {
            // "Episode 001 Title", "Ep 10 - Title", "Episode.10"
            let m = find(#"(?<![a-z0-9])episode[\s._-]*(\d{1,4})(?!\d)"#, lower) ?? find(#"(?<![a-z0-9])ep[\s._-]*(\d{1,4})(?!\d)"#, lower)
            if let m { label = String(format: "E%02d", Int(m.groups[0]) ?? 0); cut = m.start; epFrom = m.end }
        }
        if label == nil {
            // Anime: "Show Name - 03 [1080p]", "Show Name - 03 - Title"
            if let m = find(#"\s-\s(\d{2,4})[\s\[(.]"#, lower) ?? find(#"\s-\s(\d{2,4})$"#, lower), let v = Int(m.groups[0]),
               !(m.groups[0].count == 4 && (1900...2099).contains(v)), ![1080, 720, 2160].contains(v) {
                label = String(format: "E%02d", v); cut = m.start; epFrom = m.end - 1
            }
        }
        if label == nil {
            // Absolute numbering: "Show.2009.004.1080p.BD", "Show - 004 [1080p]" → E04. A bare 3-4 digit
            // number counts only after a year or before a quality tag ("The.300.Spartans.1962" stays).
            let skip: Set<Int> = [480, 576, 720, 1080, 1440, 2160, 4320]
            var from = 0, yearSeen: String?, yearPos: Int?
            while let m = find(#"[._\s\-\[(](\d{3,4})[._\s\-\])]"#, lower, from: from) {
                let n = m.groups[0], v = Int(n) ?? 0
                let sep = char(lower, m.start), before = m.start > 0 ? char(lower, m.start - 1) : ""
                if !(sep == "." && (before == "h" || before == "x")) && !skip.contains(v) {
                    if n.count == 4, (1900...2099).contains(v) {
                        if yearSeen == nil { yearSeen = n; yearPos = m.start }
                    } else {
                        let next = substring(lower, m.start + n.utf16.count + 1, 14)
                        let quality = [#"^[\[(]?\d{3,4}p"#, #"^[\[(]?bd"#, #"^[\[(]?web"#, #"^[\[(]?x26"#, #"^[\[(]?hevc"#, #"^[\[(]?blu"#, #"^[\[(]?dvd"#]
                            .contains { find($0, next) != nil }
                        if yearSeen != nil || quality {
                            label = String(format: "E%02d", v)
                            cut = yearPos ?? m.start
                            year = yearSeen
                            break
                        }
                    }
                }
                from = m.start + 1
            }
        }
        if cut == nil {
            var from = 0
            while let m = find(#"[._\s(\[](\d{4})[._\s)\]]"#, lower, from: from) {
                if m.groups[0].hasPrefix("19") || m.groups[0].hasPrefix("20") { year = m.groups[0]; cut = m.start; break }
                from = m.start + 1
            }
        }
        if cut == nil { cut = firstToken(lower) }
        if cut == nil && label == nil { return nil }

        var title = ns.substring(to: min(cut ?? ns.length, ns.length))
        title = replace(#"^\[[^\]]*\]\s*"#, in: title, with: "")
        title = tidy(title)
        // Differs from the script: a year right before the episode token is the year, not part of the title.
        if label != nil, year == nil, let m = find(#"\s((?:19|20)\d\d)$"#, title) {
            year = m.groups[0]
            title = (title as NSString).substring(to: m.start).trimmingCharacters(in: .whitespaces)
        }
        if title.isEmpty && label == nil { return nil }
        let episodeTitle = epFrom.flatMap { $0 <= ns.length ? episodeTitle(ns.substring(from: $0)) : nil }
        return ReleaseName(title: title, label: label, year: year, episodeTitle: episodeTitle, group: fileGroup(base), alt: nil,
                           attributes: attributes(techTail(lower, from: cut ?? 0)), raw: name)
    }

    /// The episode's title from what follows the episode token (CT.ep_title).
    static func episodeTitle(_ rest: String) -> String? {
        let r = replace(#"^[\s._\-:]+"#, in: rest, with: "")
        if find(#"^[eE]\d"#, r) != nil || r.hasPrefix("-") || r.hasPrefix("[") || r.hasPrefix("(") { return nil }
        var words: [String] = []
        for w in replace(#"[._]"#, in: r, with: " ").split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let lw = asciiLower(w).replacingOccurrences(of: #"[\[\]()]"#, with: "", options: .regularExpression)
            if episodeStop.contains(lw) || find(#"^\d{3,4}p$"#, lw) != nil || w.hasPrefix("[") || w.hasPrefix("(") { break }
            if lw.count == 4, let y = Int(lw), (1900...2099).contains(y) { break }
            words.append(w)
            if words.count >= 16 { break }
        }
        var t = replace(#"\s*-\s*$"#, in: words.joined(separator: " "), with: "")
        t = replace(#"^-\s*"#, in: t, with: "")
        t = replace(#"\s+"#, in: t, with: " ").trimmingCharacters(in: .whitespaces)
        return find(#"[A-Za-z]{2}"#, t) == nil ? nil : t
    }

    /// A file's release group: "…x265-VARYG", else "[SubsPlease] …" (CT.file_group).
    static func fileGroup(_ base: String) -> String? {
        if let m = find(#"-([A-Za-z0-9_]+)$"#, base) {
            let g = m.groups[0], lg = asciiLower(g)
            if (2...20).contains(g.count), !groupBlock.contains(lg), find(#"^\d+$"#, g) == nil, find(#"^\d+p$"#, lg) == nil,
               find(#"^[ex]\d+$"#, lg) == nil, find(#"^s\d"#, lg) == nil { return g }
        }
        if let m = find(#"^\[([^\]]+)\]"#, base) {
            let lead = m.groups[0]
            if (2...24).contains(lead.count), find(#"^v\d+$"#, asciiLower(lead)) == nil { return lead }
        }
        return nil
    }

    // MARK: - Folders (CT.parse_folder)

    /// A folder name ("MASHLE.MAGIC.AND.MUSCLES.S01.1080p.BluRay.REMUX.AVC.FLAC.2.0-NAN0");
    /// nil when nothing can be read from it.
    static func folder(_ name: String) -> ReleaseName? {
        cached(name, folder: true) { parseFolder(name) }
    }

    private static func parseFolder(_ name: String) -> ReleaseName? {
        var body = fixChars(stripEpisodeRange(name))
        var group: String?
        for _ in 0..<4 {                                       // leading tags: "[SubsPlease] Show", "[v2] Show"
            guard let m = find(#"^\[([^\]]+)\]"#, body) else { break }
            let lead = m.groups[0], ll = asciiLower(lead)
            if group == nil, (2...24).contains(lead.count), find(#"^v\d+$"#, ll) == nil, find(#"^\d+p$"#, ll) == nil, find(#"^\d+$"#, ll) == nil { group = lead }
            body = replace(#"^\[[^\]]*\]\s*"#, in: body, with: "")
        }
        var alt: String?                                       // "(Demon Slayer) Kimetsu no Yaiba …"
        if let m = find(#"^\((.*?)\)\s*(.+)$"#, body), find(#"[A-Za-z]{2}"#, m.groups[0]) != nil, find(#"^\d+$"#, m.groups[0]) == nil {
            alt = m.groups[0]; body = m.groups[1]
        }
        body = replace(#"^[Bb][Oo][Nn][Dd][\s._]*50[\s._\-]+"#, in: body, with: "")
        body = replace(#"\s*\[[^\]]*\]\s*$"#, in: body, with: "")   // trailing [site] / [hash]
        if let m = find(#"-([A-Za-z0-9_]+)$"#, body) {            // scene style "…-GROUP"
            let g = m.groups[0]
            if group == nil, (2...20).contains(g.count), !groupBlock.contains(asciiLower(g)), find(#"^\d+$"#, g) == nil {
                group = g
                body = (body as NSString).substring(to: m.start)
            }
        }

        let lower = asciiLower(body)
        let ls = lower + "."
        var cut: Int?, season: String?, year: String?
        func mark(_ a: Int?) { if let a, cut == nil || a < cut! { cut = a } }

        if let m = find(#"[._\s(\[\-]s(\d\d?)-s?(\d\d?)[._\s)\]\-]"#, ls) {
            season = String(format: "S%02d-S%02d", Int(m.groups[0]) ?? 0, Int(m.groups[1]) ?? 0); mark(m.start)
        }
        if season == nil, let m = find(#"[._\s(\[\-]s(\d\d?)e(\d{2,3})[._\s)\]\-]"#, ls) {
            season = String(format: "S%02dE%02d", Int(m.groups[0]) ?? 0, Int(m.groups[1]) ?? 0); mark(m.start)
        }
        if season == nil, let m = find(#"[._\s(\[\-]s(\d\d?)[._\s)\]\-]"#, ls) {
            season = String(format: "S%02d", Int(m.groups[0]) ?? 0); mark(m.start)
        }
        if season == nil, let m = find(#"[._\s(\[\-]season[._\s]*(\d\d?)[._\s)\]\-]"#, ls) {
            season = String(format: "S%02d", Int(m.groups[0]) ?? 0); mark(m.start)
        }
        if let m = find(#"[._\s(\[\-]complete[._\s)\]\-]"#, ls) {
            mark(m.start)
            if season == nil { season = "Complete" }
        }
        var from = 0
        while let m = find(#"[._\s(\[](\d{4})[._\s)\]]"#, ls, from: from) {
            if m.groups[0].hasPrefix("19") || m.groups[0].hasPrefix("20") { year = m.groups[0]; mark(m.start); break }
            from = m.start + 1
        }
        mark(firstToken(ls))
        mark(find(#"\s[\[(]"#, ls)?.start)                     // "Show [001-135] (…)": the first bracket ends the title
        if cut == nil && group == nil { return nil }

        let ns = body as NSString
        var title = tidy(ns.substring(to: min(cut ?? ns.length, ns.length)))
        if let m = find(#"\s-\s(\d{1,3})$"#, title) {           // anime "Show - 12"
            title = (title as NSString).substring(to: m.start)
            if season == nil { season = String(format: "E%02d", Int(m.groups[0]) ?? 0) }
        }
        title = stripTail(title)
        if title.isEmpty { return nil }
        return ReleaseName(title: titleCase(title), label: season, year: year, episodeTitle: nil, group: group, alt: alt,
                           attributes: attributes(techTail(lower, from: cut ?? 0)), raw: name)
    }

    /// "Pokemon Horizons Episode 1 to 6 [720p]", "Show Ep 7-16": the range isn't part of the title (CT.strip_ep_range).
    static func stripEpisodeRange(_ name: String) -> String {
        for p in [#"^(.*?)[\s._\-]+[Ee]pisodes?[\s._]*\d+[\s._]*[Tt][Oo][\s._]*\d+"#,
                  #"^(.*?)[\s._\-]+[Ee]pisodes?[\s._]*\d+[\s._]*[\-~]+[\s._]*\d+"#,
                  #"^(.*?)[\s._\-]+[Ee][Pp][\s._]*\d+[\s._]*[\-~]+[\s._]*\d+"#] {
            if let m = find(p, name), m.groups[0].count >= 2 { return m.groups[0] + (name as NSString).substring(from: m.end) }
        }
        return name
    }

    /// Release words at the END of a title: "Silo Season 1", "Bleach - Box 01", "Naruto HD", "Show Eng Dub"
    /// (CT.strip_tail). Never cuts down to nothing or a bare article.
    static func stripTail(_ title: String) -> String {
        var t = title
        for _ in 0..<8 {
            let old = t
            t = replace(#"[\s\-:]+$"#, in: t, with: "")
            for p in [#"\s+seasons?\s*\d+.*$"#, #"\s+box\s*\d+.*$"#, #"\s+usbd$"#, #"\s+hd$"#, #"\s+tl$"#, #"\s+bd$"#, #"\s+remux$"#,
                      #"\s+complete$"#, #"\s+collection$"#, #"\s+eng?l?i?s?h?\s+dub[a-z]*$"#, #"\s+eng?l?i?s?h?\s+sub[a-z]*$"#,
                      #"\s+dual[\s\-]*audio$"#, #"\s+multi[\s\-]*subs?$"#, #"\s+dubbed$"#, #"\s+subbed$"#] {
                guard let m = find(p, asciiLower(t)) else { continue }
                let rest = asciiLower((t as NSString).substring(to: m.start))
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                if rest.isEmpty || ["the", "a", "an"].contains(rest) { continue }
                t = (t as NSString).substring(to: m.start)
            }
            if t == old { break }
        }
        return t
    }

    /// Only names ALL upper or ALL lower case are re-cased; mixed case is how
    /// the release was named (CT.titlecase).
    static func titleCase(_ s: String) -> String {
        if s.range(of: "[a-z]", options: .regularExpression) != nil, s.range(of: "[A-Z]", options: .regularExpression) != nil { return s }
        var out: [String] = []
        for (i, w) in s.split(separator: " ").enumerated() {
            let lw = asciiLower(String(w))
            if i > 0, smallWords.contains(lw) { out.append(lw); continue }
            out.append(lw.prefix(1).uppercased() + lw.dropFirst())
        }
        return out.joined(separator: " ")
    }

    // MARK: - Attributes (CT.chips_for, extended)

    /// What the name says about the release, in display order.
    static func attributes(_ lower: String) -> [Attribute] {
        func has(_ p: String) -> Bool { find(p, lower) != nil }
        var a: [Attribute] = []
        func add(_ k: Kind, _ t: String) { a.append(Attribute(kind: k, text: t)) }

        if has("2160p") || has(#"(?<![a-z0-9])4k(?![a-z0-9])"#) || has(#"(?<![a-z])uhd(?![a-z])"#) { add(.resolution, "4K") }
        else if has("1080[pi]") { add(.resolution, "1080p") }
        else if has("720p") { add(.resolution, "720p") }
        else if has("576p") { add(.resolution, "576p") }
        else if has("480p") { add(.resolution, "480p") }

        if has("remux") { add(.source, "Remux") }
        else if has(#"blu-?ray|(?<![a-z])bd(?:rip)?(?![a-z])|brrip"#) { add(.source, "BluRay") }
        else if has(#"web[\s._-]?dl"#) { add(.source, "WEB-DL") }
        else if has("webrip") { add(.source, "WEBRip") }
        else if has(#"(?<![a-z])web(?![a-z])"#) { add(.source, "WEB") }
        else if has("hdtv") { add(.source, "HDTV") }
        else if has(#"dvd(?:rip)?(?![a-z])"#) { add(.source, "DVD") }

        if has(#"hdr10(?:\+|plus)"#) { add(.hdr, "HDR10+") }
        else if has("hdr10") { add(.hdr, "HDR10") }
        else if has(#"(?<![a-z])hdr(?![a-z])"#) { add(.hdr, "HDR") }
        if has(#"(?<![a-z])dv(?![a-z])|dovi|dolby[\s._-]?vision"#) { add(.dolbyVision, "DV") }

        if has(#"x265|h[\s.]?265|hevc"#) { add(.codec, "HEVC") }
        else if has(#"x264|h[\s.]?264|(?<![a-z])avc(?![a-z])"#) { add(.codec, "AVC") }
        else if has(#"(?<![a-z])av1(?![a-z])"#) { add(.codec, "AV1") }

        var audio: [String] = []
        if has("truehd") { audio.append("TrueHD") }
        if has(#"dts[\s._-]?hd[\s._-]?ma"#) { audio.append("DTS-HD MA") }
        else if has(#"dts[\s._-]?x(?![a-z])"#) { audio.append("DTS:X") }
        else if has(#"(?<![a-z])dts"#) { audio.append("DTS") }
        if has(#"ddp|dd\+|e-?ac-?3"#) { audio.append("DD+") }
        else if has(#"(?<![a-z])(?:dd|ac-?3)(?![a-z+])"#) { audio.append("DD") }
        if has(#"(?<![a-z])aac"#) { audio.append("AAC") }
        if has("flac") { audio.append("FLAC") }
        if has("opus") { audio.append("Opus") }
        if has("atmos") { audio.append("Atmos") }
        if !audio.isEmpty { add(.audio, audio.joined(separator: " ")) }
        if let m = find(#"(?:truehd|ddp?|dd\+|aac|flac|dts(?:-?hd(?:[\s._-]?ma)?)?|opus|atmos|lpcm|pcm)[\s._]?([1-9])[\s._]([0-2])(?![0-9])"#, lower) {
            add(.channels, "\(m.groups[0]).\(m.groups[1])")
        }

        let services = [("nf", "NF"), ("amzn", "AMZN"), ("dsnp", "DSNP"), ("atvp", "ATVP"), ("hmax", "HMAX"), ("max", "MAX"), ("hulu", "HULU"),
                        ("pcok", "PCOK"), ("cr", "CR"), ("hidive", "HIDIVE"), ("pmtp", "PMTP")]
        if let s = services.first(where: { has(#"(?<![a-z0-9])"# + $0.0 + #"(?![a-z0-9])"#) }) { add(.service, s.1) }

        if has(#"dual[\s._-]?audio|(?<![a-z])dual(?![a-z])"#) { add(.language, "Dual Audio") }
        else if has(#"(?<![a-z])multi(?![a-z])"#) { add(.language, "Multi") }
        if has(#"(?<![a-z])repack(?![a-z])"#) { add(.edition, "REPACK") }
        else if has(#"(?<![a-z])proper(?![a-z])"#) { add(.edition, "PROPER") }
        return a
    }

    // MARK: - Telling entries apart

    /// The attributes shown with each entry: resolution, source, HDR and DV
    /// (the script's chips) and the group, then — only for entries that would
    /// still look the same — codec, audio, channels, service, language and
    /// edition, one kind at a time until they differ. Entries identical in
    /// every attribute get the end of their original name.
    static func distinguishing(_ names: [ReleaseName]) -> [[String]] {
        let base: [Kind] = [.resolution, .source, .hdr, .dolbyVision]
        let more: [Kind] = [.codec, .audio, .channels, .service, .language, .edition]
        func shown(_ n: ReleaseName, _ kinds: [Kind], group: Bool) -> [String] {
            n.attributes.filter { kinds.contains($0.kind) }.sorted { $0.kind < $1.kind }.map(\.text) + (group ? n.group.map { [$0] } ?? [] : [])
        }
        var kinds = Array(repeating: base, count: names.count)
        var out = names.indices.map { shown(names[$0], base, group: true) }
        func identity(_ i: Int) -> String { ([names[i].title, names[i].label ?? "", names[i].year ?? "", names[i].episodeTitle ?? ""] + out[i]).joined(separator: "|").lowercased() }
        for k in more {
            let groups = Dictionary(grouping: names.indices, by: identity).values.filter { $0.count > 1 }
            if groups.isEmpty { return out }
            for g in groups { for i in g { kinds[i].append(k); out[i] = shown(names[i], kinds[i], group: true) } }
        }
        for g in Dictionary(grouping: names.indices, by: identity).values where g.count > 1 {
            for i in g { out[i].append(rawTail(names[i].raw)) }
        }
        return out
    }

    /// The last part of a raw name, for two entries alike in everything read.
    private static func rawTail(_ raw: String) -> String {
        let ext = (raw as NSString).pathExtension.lowercased()
        let base = TitleParser.mediaExtensions.contains(ext) ? (raw as NSString).deletingPathExtension : raw
        return base.count > 24 ? "…" + base.suffix(24) : base
    }

    // MARK: - Shared rules

    static let tokens = ["2160p", "1080p", "1080i", "720p", "480p", "4k", "uhd", "bluray", "blu-ray", "bdrip", "brrip",
                         "web-dl", "webdl", "webrip", "hdtv", "dvdrip", "remux", "x264", "x265", "h264", "h265", "hevc",
                         "av1", "hdr", "dovi", "atmos", "dts", "ddp", #"dd\+"#]

    /// Words that end an episode title read from a file name (CT.EP_STOP).
    static let episodeStop: Set<String> = Set("""
        1080p 2160p 720p 480p 1080i 4k uhd web webdl web-dl webrip bluray blu-ray bdrip brrip bd hdtv dvdrip remux
        x264 x265 h264 h265 hevc avc av1 hdr hdr10 dv dovi atmos dts ddp dd aac flac opus multi dual dubbed subbed
        proper repack internal real vostfr nf amzn dsnp atvp hmax max hulu pcok cr crunchyroll hidive ita eng fre ger spa
        jpn kor 10bit 8bit hi10p complete
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    static let groupBlock: Set<String> = ["dl", "hd", "rip", "ma", "hdr", "dv", "webdl", "hevc", "x264", "x265", "h264", "h265", "avc", "aac", "dts", "ac3", "flac"]
    static let smallWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "vs"]

    /// The technical part of a name: from the first word after `from` that
    /// ends an episode title (a resolution, source, codec, service…), so words
    /// of the title ("Mad.Max.Fury.Road.2015…") are never read as attributes.
    /// Empty when there is none.
    static func techTail(_ lower: String, from: Int) -> String {
        let ns = lower as NSString
        var at = from
        while let m = find(#"[a-z0-9+]+"#, lower, from: at) {
            let w = ns.substring(with: NSRange(location: m.start, length: m.end - m.start))
            if episodeStop.contains(w) || find(#"^\d{3,4}[pi]$"#, w) != nil { return ns.substring(from: m.start) }
            at = m.end
        }
        return ""
    }

    /// Where the first technical token starts (after a separator), or nil.
    private static func firstToken(_ lower: String) -> Int? {
        tokens.compactMap { find(#"[._\s\-\[(]"# + $0, lower)?.start }.min()
    }

    /// Dots and underscores to spaces, one space, no dashes or brackets at the ends.
    private static func tidy(_ s: String) -> String {
        var t = replace(#"[._]+"#, in: s, with: " ")
        t = replace(#"\s+"#, in: t, with: " ")
        t = replace(#"^[\s\-]+"#, in: t, with: "")
        return replace(#"[\s\-(\[]+$"#, in: t, with: "")
    }

    /// Characters some upload tools put in place of ones Windows forbids
    /// ("Time?!" saved with U+F025), the double-encoded form of the same, and
    /// U+A789 for ":" (CT.fix_chars).
    static func fixChars(_ s: String) -> String {
        let special: [UInt32: String] = [0xF020: "\"", 0xF021: "*", 0xF022: ":", 0xF023: "<", 0xF024: ">", 0xF025: "?",
                                         0xF026: "\\", 0xF027: "|", 0xF028: " ", 0xF029: "."]
        func mapped(_ cp: UInt32) -> String? {
            if let m = special[cp] { return m }
            if (0xF030...0xF07F).contains(cp), let u = Unicode.Scalar(cp - 0xF000) { return String(Character(u)) }
            return nil
        }
        guard s.unicodeScalars.contains(where: { (0xF020...0xF07F).contains($0.value) || $0.value == 0xA789 || $0.value == 0xEF }) else { return s }
        var out = ""
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if (0xF020...0xF07F).contains(v), let m = mapped(v) { out += m; i += 1; continue }
            // "ï€" + U+00A0…U+00BF: the same character read as Windows-1252 and saved again as UTF-8.
            if v == 0xEF, i + 2 < scalars.count, scalars[i + 1].value == 0x20AC, (0xA0...0xBF).contains(scalars[i + 2].value),
               let m = mapped(0xF000 + scalars[i + 2].value - 0x80) { out += m; i += 3; continue }
            if v == 0xA789 { out += ":"; i += 1; continue }
            out.unicodeScalars.append(scalars[i]); i += 1
        }
        return out
    }

    // MARK: - Pattern helpers (UTF-16 offsets, as NSString / NSRegularExpression use)

    struct Match { let start: Int; let end: Int; let groups: [String] }

    private static let regexLock = NSLock()
    nonisolated(unsafe) private static var regexes: [String: NSRegularExpression] = [:]

    private static func regex(_ p: String) -> NSRegularExpression? {
        regexLock.lock(); defer { regexLock.unlock() }
        if let r = regexes[p] { return r }
        let r = try? NSRegularExpression(pattern: p)
        regexes[p] = r
        return r
    }

    static func find(_ pattern: String, _ s: String, from: Int = 0) -> Match? {
        let ns = s as NSString
        guard from <= ns.length, let re = regex(pattern),
              let m = re.firstMatch(in: s, range: NSRange(location: from, length: ns.length - from)) else { return nil }
        var groups: [String] = []
        if m.numberOfRanges > 1 {
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
        }
        return Match(start: m.range.location, end: m.range.location + m.range.length, groups: groups)
    }

    static func replace(_ pattern: String, in s: String, with t: String) -> String {
        guard let re = regex(pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }

    /// ASCII-only lower case, as Lua's `lower()`: the same length, so
    /// offsets in it are offsets in the original.
    static func asciiLower(_ s: String) -> String {
        String(decoding: s.utf16.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF16.self)
    }

    private static func char(_ s: String, _ at: Int) -> String { substring(s, at, 1) }
    private static func substring(_ s: String, _ from: Int, _ length: Int) -> String {
        let ns = s as NSString
        guard from < ns.length else { return "" }
        return ns.substring(with: NSRange(location: from, length: min(length, ns.length - from)))
    }

    // MARK: - Cache (rows ask on every redraw)

    private struct Key: Hashable { let name: String; let folder: Bool }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: ReleaseName?] = [:]

    private static func cached(_ name: String, folder: Bool, _ make: () -> ReleaseName?) -> ReleaseName? {
        let key = Key(name: name, folder: folder)
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let value = make()
        cacheLock.lock()
        if cache.count > 20000 { cache.removeAll() }
        cache[key] = value
        cacheLock.unlock()
        return value
    }
}
