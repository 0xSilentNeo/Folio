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

    /// The next episode's stream: same binge group (the protocol's marker for "same
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

    /// What the addon has for an episode, compared with the release you picked.
    enum Match {
        /// The same release (ready to play; subtitles are added later).
        case same(MediaItem)
        /// Streams exist, but not of the same release: you pick one.
        case other
        /// Nothing playable (or the addon didn't answer).
        case none
    }

    /// The same release only (1.17.0): the same binge group when the addon sets
    /// one, otherwise the same stream name and resolution. Anything else is
    /// for you to pick — no silent "closest match" any more.
    static func sameRelease(_ streams: [AddonStream], as pick: StreamPick) -> AddonStream? {
        let playable = streams.filter(\.isPlayable)
        if let g = pick.bingeGroup { return playable.first { $0.behaviorHints?.bingeGroup == g } }
        guard let name = pick.streamName else { return nil }
        return playable.first { $0.name == name && resolution(of: $0) == pick.resolution }
    }

    /// The streams each addon last gave for an episode (in-player picker:
    /// shown straight away, and kept when asking again comes back empty).
    @MainActor static var recentStreams: [String: (at: Date, streams: [AddonStream])] = [:]
    static func recentKey(_ addonID: String, _ videoId: String) -> String { addonID + "|" + videoId }

    /// Asks the pick's addon for the episode in `pick.context` and compares.
    @MainActor
    static func screen(_ pick: StreamPick) async -> Match {
        let c = pick.context
        guard let addon = AddonStore.shared.addons.first(where: { $0.id == pick.addonID }),
              let streams = try? await AddonAPI.streams(addon, type: c.type, id: c.videoId) else { return .none }
        recentStreams[recentKey(addon.id, c.videoId)] = (Date(), streams)
        guard streams.contains(where: \.isPlayable) else { return .none }
        if let s = sameRelease(streams, as: pick), let item = makeItem(c, stream: s, addon: addon, extraSubtitles: []) { return .same(item) }
        return .other
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

    /// How long playback waits for subtitle addons.
    static let subtitleWait: UInt64 = 3_000_000_000

    /// Subtitles from subtitle addons, preferred languages first — what
    /// arrived within 3 s. Playback waited for every subtitle addon until
    /// 1.19.0: your 30 Oct log has two stream taps that waited the full 20 s
    /// request timeout for "…/subtitles/series/tt37532356:1:24.json" ("request
    /// sent, no answer"; then "request never sent") before the player opened.
    @MainActor
    static func subtitles(type: String, videoId: String) async -> [ExternalSubtitle] {
        let addons = AddonStore.shared.subtitleAddons(type: type, id: videoId)
        guard !addons.isEmpty else { return [] }
        let prefs = (UserDefaults.standard.string(forKey: SettingsKey.subLangs) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var out: [ExternalSubtitle] = []
        let t0 = Date()
        var answered = 0
        await withTaskGroup(of: [AddonSubtitle]?.self) { tg in
            for a in addons { tg.addTask { (try? await AddonAPI.subtitles(a, type: type, id: videoId)) ?? [] } }
            tg.addTask { try? await Task.sleep(nanoseconds: subtitleWait); return nil }      // the deadline
            for await list in tg {
                guard let list else { tg.cancelAll(); break }
                answered += 1
                out += list.map { ExternalSubtitle(url: $0.url, lang: $0.lang, title: $0.lang) }
                if answered == addons.count { tg.cancelAll(); break }
            }
        }
        dlog("player", "subtitles: \(out.count) from \(answered) of \(addons.count) subtitle addon(s) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms"
             + (answered < addons.count ? "; the rest didn't answer within 3 s, playing without them" : ""))
        if !prefs.isEmpty {
            out.sort { a, b in
                (prefs.firstIndex(of: (a.lang ?? "").lowercased()) ?? 99) < (prefs.firstIndex(of: (b.lang ?? "").lowercased()) ?? 99)
            }
        }
        return out
    }
}

/// Opens a stream link once before it's needed (1.17.0, "Get the next episode
/// ready"): asking for its first byte makes a debrid service prepare the file
/// (the 26 Oct log: 12–13.5 s from loadfile to "file loaded" for the next
/// episode). Returns where the link finally points after its redirects.
enum LinkWarmer {
    static func resolve(_ url: URL, headers: [String: String]) async -> URL? {
        var r = URLRequest(url: url, timeoutInterval: 40)
        r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        r.setValue("libmpv", forHTTPHeaderField: "User-Agent")       // what the player sends
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let t0 = Date()
        let host = url.host ?? "?"
        let others = NetTrace.begin(host)
        defer { NetTrace.end(host) }
        let timer = NetTrace.Timer()
        let c0 = CFAbsoluteTimeGetCurrent()
        let answer: (Data, URLResponse)
        do { answer = try await URLSession.shared.data(for: r, delegate: timer) } catch {
            NetTrace.report("link", url: url, others: others, started: c0, timer: timer, status: nil, bytes: nil, error: error)
            dlog("player", "next episode: link didn't answer")
            return nil
        }
        NetTrace.report("link", url: url, others: others, started: c0, timer: timer, status: (answer.1 as? HTTPURLResponse)?.statusCode, bytes: answer.0.count, error: nil)
        guard let http = answer.1 as? HTTPURLResponse else { return nil }
        dlog("player", String(format: "next episode: link answered HTTP %d in %.1f s%@", http.statusCode, Date().timeIntervalSince(t0),
                              http.url?.host != url.host ? " (redirected to \(http.url?.host ?? "?"))" : ""))
        return (200..<300).contains(http.statusCode) ? http.url : nil
    }
}
