import Foundation

/// What a watch history entry is, whichever source played it: an IMDb title
/// ("tt…") and, for an episode, its season and episode ("tt…:1:5"). The
/// shared watch history approved after 1.19.0 links entries by it.
///
/// Worked out without the network and only from what's certain:
/// - an addon's own id ("addon:tt37532356:1:24");
/// - a Real-Debrid or library file whose release has a saved, confident
///   match (ReleaseMatch's rule: an exact name with a year that agrees, or
///   the only title with that name and kind), with the season and episode
///   from the file's name.
/// Anything else has none and keeps working as it does today.
enum TitleIdentity {
    /// "addon:tt37532356:1:24" → "tt37532356:1:24", "addon:tt0816692" →
    /// "tt0816692". Other ids (kitsu:…, mal:…) have no IMDb id: nil.
    static func fromAddonKey(_ key: String) -> String? {
        guard key.hasPrefix("addon:") else { return nil }
        let parts = key.dropFirst("addon:".count).split(separator: ":", omittingEmptySubsequences: false)
        guard let tt = parts.first, isIMDbID(tt) else { return nil }
        switch parts.count {
        case 1: return String(tt)
        case 3:
            guard let s = Int(parts[1]), let e = Int(parts[2]) else { return nil }
            return "\(tt):\(s):\(e)"
        default: return nil
        }
    }

    /// A file by its name and, for a WebDAV file, its folder's name. The
    /// release is the folder when that is a release folder (a season pack),
    /// else the file itself. `match` gives a release's confident IMDb id.
    /// An episode needs an explicit season and episode in the file's name
    /// (an absolute anime number has no season: none); a film needs a
    /// release that is a film.
    static func forFile(name: String, folder: String?, match: (ReleaseName) async -> String?) async -> String? {
        let file = ReleaseName.file(name)
        guard let release = folder.flatMap({ ReleaseName.folder($0) }) ?? file,
              let tt = await match(release), isIMDbID(tt[...]) else { return nil }
        if let label = file?.label {
            // Only an explicit "S01E03" (ReleaseName writes 1x03 that way too).
            guard let se = seasonEpisode(label) else { return nil }
            return "\(tt):\(se.0):\(se.1)"
        }
        return ReleaseMatch.kind(of: release) == .movie ? tt : nil
    }

    /// "S01E03" → (1, 3); "E05", "S02", "S01-S03", "Complete" → nil.
    static func seasonEpisode(_ label: String) -> (Int, Int)? {
        guard label.hasPrefix("S"), let e = label.firstIndex(of: "E"),
              let season = Int(label[label.index(after: label.startIndex)..<e]),
              let episode = Int(label[label.index(after: e)...]) else { return nil }
        return (season, episode)
    }

    private static func isIMDbID(_ s: Substring) -> Bool {
        s.count > 2 && s.hasPrefix("tt") && s.dropFirst(2).allSatisfy(\.isASCII) && s.dropFirst(2).allSatisfy(\.isNumber)
    }
}

/// The history linking check (read only): how many history entries would
/// get an identity, by source, and how many titles were watched from more
/// than one source. It reads history.json into memory and writes nothing,
/// so it's the "test it on a copy of your real data first" step before any
/// migration. Settings → Help & Diagnostics → Diagnostics.
enum HistoryLinkCheck {
    struct Report: Equatable {
        var entries = 0
        var addon = 0, addonLinked = 0
        var webdav = 0, webdavLinked = 0
        var library = 0, libraryLinked = 0
        var other = 0
        /// Identities with entries from more than one source.
        var sharedAcrossSources = 0

        var summary: String {
            "\(entries) entries: addons \(addonLinked) of \(addon) linked, Real-Debrid/WebDAV \(webdavLinked) of \(webdav), "
                + "library files \(libraryLinked) of \(library), other \(other); \(sharedAcrossSources) title(s) watched from more than one source"
        }
    }

    @MainActor
    static func run() async -> Report {
        let entries = HistoryStore.shared.entries      // a copy (value type)
        let r = await check(entries) { release in
            guard let m = await ReleaseMatcher.shared.saved(release), m.confident else { return nil }
            return m.imdbID
        }
        dlog("history", "linking check (nothing changed): " + r.summary)
        return r
    }

    static func check(_ entries: [HistoryEntry], match: (ReleaseName) async -> String?) async -> Report {
        var r = Report()
        var sources: [String: Set<String>] = [:]
        for e in entries {
            r.entries += 1
            var identity: String?
            let kind: String
            switch e.item.source {
            case .addon:
                kind = "addon"; r.addon += 1
                identity = TitleIdentity.fromAddonKey(e.id)
                if identity != nil { r.addonLinked += 1 }
            case .webdav:
                kind = "webdav"; r.webdav += 1
                let u = URL(string: e.item.url)
                let name = u?.lastPathComponent.removingPercentEncoding ?? u?.lastPathComponent ?? ""
                let folder = u?.deletingLastPathComponent().lastPathComponent
                identity = await TitleIdentity.forFile(name: name, folder: folder?.removingPercentEncoding ?? folder, match: match)
                if identity != nil { r.webdavLinked += 1 }
            case .local:
                kind = "library"; r.library += 1
                identity = await TitleIdentity.forFile(name: (e.item.url as NSString).lastPathComponent, folder: nil, match: match)
                if identity != nil { r.libraryLinked += 1 }
            default:
                kind = "other"; r.other += 1
            }
            if let identity { sources[identity, default: []].insert(kind) }
        }
        r.sharedAcrossSources = sources.values.filter { $0.count > 1 }.count
        return r
    }
}
