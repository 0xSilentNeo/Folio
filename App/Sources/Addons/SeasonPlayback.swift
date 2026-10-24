import Foundation

/// What's needed to turn an addon stream into a playable item, kept with the
/// queue so later episodes can be resolved when their turn comes.
struct PlayContext: Codable, Hashable {
    var name: String
    var poster: String?
    var type: String
    var metaId: String
    var isAnime: Bool
    var videoId: String
    var videoLabel: String?
    var episode: Int?
}

/// "Play Season": the stream you picked for the first episode, remembered so
/// the next episodes can pick the matching stream from the same addon.
struct StreamPick: Codable, Hashable {
    var addonID: String
    var bingeGroup: String?
    var streamName: String?
    var resolution: String?
    var context: PlayContext
}

enum AddonPlayback {
    /// A playable item from a picked stream.
    @MainActor
    static func makeItem(_ c: PlayContext, stream s: AddonStream, addon: InstalledAddon, extraSubtitles: [ExternalSubtitle]) -> MediaItem? {
        guard let url = s.url else { return nil }
        var item = MediaItem(url: url, title: c.name, subtitle: c.videoLabel, source: .addon(name: addon.manifest.name))
        item.artwork = c.poster
        item.historyKey = "addon:\(c.videoId)"
        item.addonRef = "\(c.type)|\(c.metaId)|\(c.videoId)"
        item.headers = s.behaviorHints?.proxyHeaders?.request ?? [:]
        let subs = (s.subtitles ?? []).map { ExternalSubtitle(url: $0.url, lang: $0.lang, title: $0.lang) } + extraSubtitles
        item.subtitles = Array(subs.prefix(40))
        // Remembered with the history entry, so Continue Watching can queue the
        // rest of the season from the same addon and release (the URL is set,
        // so the player plays it directly; the pick is only for what follows).
        item.streamPick = pick(from: s, addon: addon, context: c)
        if c.isAnime {
            var hint = AnimeHint(title: c.name, episode: c.episode)
            let parts = c.videoId.split(separator: ":")
            if parts.first == "kitsu", parts.count >= 2 {
                hint.kitsuId = Int(parts[1])
                if parts.count >= 3 { hint.episode = Int(parts[2]) ?? hint.episode }
            } else if parts.first == "mal", parts.count >= 2 {
                hint.malId = Int(parts[1])
                if parts.count >= 3 { hint.episode = Int(parts[2]) ?? hint.episode }
            }
            if hint.episode == nil, c.type == "movie" { hint.episode = 1 }
            item.anime = hint
        }
        return item
    }

    /// Queue entry for an episode whose stream is found just before it plays
    /// (debrid links expire, and asking every addon for a whole season up
    /// front would take long).
    static func placeholder(_ c: PlayContext, pick: StreamPick) -> MediaItem {
        var item = MediaItem(url: "", title: c.name, subtitle: c.videoLabel, source: .url)
        item.artwork = c.poster
        item.historyKey = "addon:\(c.videoId)"
        item.addonRef = "\(c.type)|\(c.metaId)|\(c.videoId)"
        var p = pick
        p.context = c
        item.streamPick = p
        return item
    }

    static func pick(from s: AddonStream, addon: InstalledAddon, context: PlayContext) -> StreamPick {
        StreamPick(addonID: addon.id, bingeGroup: s.behaviorHints?.bingeGroup, streamName: s.name,
                   resolution: resolution(of: s), context: context)
    }

    static func resolution(of s: AddonStream) -> String? {
        let text = [s.name, s.title, s.description, s.behaviorHints?.filename].compactMap { $0 }.joined(separator: " ").lowercased()
        for r in ["2160p", "4k", "1440p", "1080p", "720p", "576p", "480p"] where text.contains(r) { return r == "4k" ? "2160p" : r }
        return nil
    }

    /// The next episode's stream: same binge group (Stremio's marker for "same
    /// release across episodes") if the addon sets one, else the same stream
    /// name and resolution, else the first playable stream.
    static func choose(_ streams: [AddonStream], like pick: StreamPick) -> AddonStream? {
        let playable = streams.filter(\.isPlayable)
        if let g = pick.bingeGroup, let s = playable.first(where: { $0.behaviorHints?.bingeGroup == g }) { return s }
        func score(_ s: AddonStream) -> Int {
            var n = 0
            if let r = pick.resolution, resolution(of: s) == r { n += 2 }
            if let name = pick.streamName, s.name == name { n += 1 }
            return n
        }
        return playable.max { score($0) < score($1) } ?? playable.first
    }

    /// Resolves a placeholder; nil when the addon has nothing playable.
    @MainActor
    static func resolve(_ pick: StreamPick) async -> MediaItem? {
        let c = pick.context
        guard let addon = AddonStore.shared.addons.first(where: { $0.id == pick.addonID }) else { return nil }
        guard let streams = try? await AddonAPI.streams(addon, type: c.type, id: c.videoId),
              let s = choose(streams, like: pick) else { return nil }
        dlog("player", "season: \(c.videoLabel ?? c.videoId) → \(s.displayName) (\(resolution(of: s) ?? "?"))\(s.behaviorHints?.bingeGroup != nil && s.behaviorHints?.bingeGroup == pick.bingeGroup ? " same release" : "")")
        let subs = await subtitles(type: c.type, videoId: c.videoId)
        return makeItem(c, stream: s, addon: addon, extraSubtitles: subs)
    }

    /// Subtitles from subtitle addons, preferred languages first.
    @MainActor
    static func subtitles(type: String, videoId: String) async -> [ExternalSubtitle] {
        let addons = AddonStore.shared.subtitleAddons(type: type, id: videoId)
        guard !addons.isEmpty else { return [] }
        let prefs = (UserDefaults.standard.string(forKey: SettingsKey.subLangs) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var out: [ExternalSubtitle] = []
        await withTaskGroup(of: [AddonSubtitle].self) { tg in
            for a in addons { tg.addTask { (try? await AddonAPI.subtitles(a, type: type, id: videoId)) ?? [] } }
            for await list in tg { out += list.map { ExternalSubtitle(url: $0.url, lang: $0.lang, title: $0.lang) } }
        }
        if !prefs.isEmpty {
            out.sort { a, b in
                (prefs.firstIndex(of: (a.lang ?? "").lowercased()) ?? 99) < (prefs.firstIndex(of: (b.lang ?? "").lowercased()) ?? 99)
            }
        }
        return out
    }
}
