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
    /// The addon's manifest id (1.23.0), so a pick still finds its addon
    /// after it's added again with a new key or options (a new address).
    var manifestID: String? = nil
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
                   resolution: resolution(of: s), context: context, manifestID: addon.manifest.id)
    }

    /// The addon a saved pick came from: by its address, else the same
    /// addon on the same server added again with a new key or options,
    /// which until 1.23.0 marked every next episode "unavailable" (review, 5 Nov).
    @MainActor
    static func addon(for pick: StreamPick) -> InstalledAddon? {
        // Only addons switched on (1.27.0).
        let addons = AddonStore.shared.active
        if let a = addons.first(where: { $0.id == pick.addonID }) { return a }
        let host = URL(string: pick.addonID)?.host
        let sameHost = addons.filter { URL(string: $0.transportURL)?.host == host }
        if let m = pick.manifestID { return sameHost.first { $0.manifest.id == m } }
        return sameHost.count == 1 ? sameHost[0] : nil
    }

    static func resolution(of s: AddonStream) -> String? {
        let text = [s.name, s.title, s.description, s.behaviorHints?.filename].compactMap { $0 }.joined(separator: " ").lowercased()
        for r in ["2160p", "4k", "1440p", "1080p", "720p", "576p", "480p"] where text.contains(r) { return r == "4k" ? "2160p" : r }
        return nil
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
    @MainActor static var recentStreams: [String: (at: Date, streams: [AddonStream])] = [:] {
        // The newest 200 (1.30.2): it grew with every episode checked.
        didSet {
            let extra = recentStreams.count - 200
            guard extra > 0 else { return }
            for old in recentStreams.sorted(by: { $0.value.at < $1.value.at }).prefix(extra) {
                recentStreams[old.key] = nil
            }
        }
    }
    static func recentKey(_ addonID: String, _ videoId: String) -> String { addonID + "|" + videoId }

    /// Asks the pick's addon for the episode in `pick.context` and compares.
    @MainActor
    static func screen(_ pick: StreamPick) async -> Match {
        let c = pick.context
        guard let addon = addon(for: pick) else { return .other }       // gone: let you pick
        guard let streams = try? await AddonAPI.streams(addon, type: c.type, id: c.videoId) else { return .none }
        recentStreams[recentKey(addon.id, c.videoId)] = (Date(), streams)
        guard streams.contains(where: \.isPlayable) else { return .none }
        if let s = sameRelease(streams, as: pick), let item = makeItem(c, stream: s, addon: addon, extraSubtitles: []) { return .same(item) }
        return .other
    }

    /// Resolves a placeholder; nil when the addon has nothing playable.
    @MainActor

    /// How long a stream start waits for subtitle addons (1.20.0). Until
    /// then playback waited for every one: 20.3 s twice in the 30 Oct log
    /// (an addon's subtitles request timing out, then "play requested").
    /// Subtitles that come later are added to the playing file.
    static let subtitleWait: Duration = .seconds(3)

    /// Posted (main thread) when subtitle addons answer after
    /// `subtitleWait`: userInfo "videoId" (String), "subtitles" ([ExternalSubtitle]).
    static let lateSubtitlesArrived = Notification.Name("AddonPlayback.lateSubtitlesArrived")

    /// Late answers, kept for 10 minutes by video id, for a player that
    /// isn't there yet when they come, or an episode that plays later
    /// (PlayerModel.onFileLoaded adds them).
    @MainActor private static var late: [String: (at: Date, subtitles: [ExternalSubtitle])] = [:]

    @MainActor static func lateSubtitles(for videoId: String) -> [ExternalSubtitle] {
        guard let l = late[videoId], Date().timeIntervalSince(l.at) < 600 else { return [] }
        return l.subtitles
    }

    /// Subtitles from subtitle addons, preferred languages first: what has
    /// come within `subtitleWait`; the rest goes to the player as it comes
    /// (`lateSubtitlesArrived`).
    @MainActor
    static func subtitles(type: String, videoId: String) async -> [ExternalSubtitle] {
        let sources = AddonStore.shared.subtitleAddons(type: type, id: videoId).map { a in
            SubtitleSource(name: a.manifest.name) { try await AddonAPI.subtitles(a, type: type, id: videoId) }
        }
        return await subtitles(videoId: videoId, from: sources)
    }

    /// A subtitle addon: its name (for the log, never its address: it holds
    /// your key) and its request.
    struct SubtitleSource {
        let name: String
        let fetch: () async throws -> [AddonSubtitle]
    }

    @MainActor
    static func subtitles(videoId: String, from sources: [SubtitleSource], waitingAtMost limit: Duration = subtitleWait) async -> [ExternalSubtitle] {
        guard !sources.isEmpty else { return [] }
        let wait = SubtitleWait(left: sources.count)
        let t0 = Date()
        for a in sources {
            Task { @MainActor in
                let list = ((try? await a.fetch()) ?? [])
                    .map { ExternalSubtitle(url: $0.url, lang: $0.lang, title: $0.lang) }
                wait.left -= 1
                if wait.open {
                    wait.arrived += list
                    if wait.left == 0 { wait.finish() }
                    return
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                dlog("player", "subtitle addon \(a.name) answered after \(ms) ms with \(list.count) subtitle(s)")
                guard !list.isEmpty else { return }
                let sorted = preferredFirst(list)
                let had = lateSubtitles(for: videoId)
                late = late.filter { Date().timeIntervalSince($0.value.at) < 600 }
                late[videoId] = (Date(), had + sorted)
                NotificationCenter.default.post(name: lateSubtitlesArrived, object: nil, userInfo: ["videoId": videoId, "subtitles": sorted])
            }
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: limit)
            guard wait.open else { return }
            dlog("player", "subtitle addons: \(wait.left) of \(sources.count) still out after \(Int(Date().timeIntervalSince(t0) * 1000)) ms; starting without them")
            wait.finish()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if wait.open { wait.continuation = c } else { c.resume() }
        }
        timer.cancel()
        if wait.left == 0 { dlog("player", "subtitle addons: all \(sources.count) answered in \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        return preferredFirst(wait.arrived)
    }

    @MainActor
    private static func preferredFirst(_ list: [ExternalSubtitle]) -> [ExternalSubtitle] {
        let prefs = (UserDefaults.standard.string(forKey: SettingsKey.subLangs) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !prefs.isEmpty else { return list }
        return list.sorted { a, b in
            (prefs.firstIndex(of: (a.lang ?? "").lowercased()) ?? 99) < (prefs.firstIndex(of: (b.lang ?? "").lowercased()) ?? 99)
        }
    }

    /// One wait for subtitle addons (main actor only).
    @MainActor
    private final class SubtitleWait {
        var arrived: [ExternalSubtitle] = []
        var left: Int
        var open = true
        var continuation: CheckedContinuation<Void, Never>?
        init(left: Int) { self.left = left }
        func finish() {
            open = false
            continuation?.resume()
            continuation = nil
        }
    }
}

/// Opens a stream link once before it's needed (1.17.0, "Get the next episode
/// ready"): asking for its first byte makes a debrid service prepare the file
/// (the 26 Oct log: 12–13.5 s from loadfile to "file loaded" for the next
/// episode). Returns where the link finally points after its redirects.
///
/// Only the answer's headers are read, then the request is cancelled. Until
/// 1.20.2 the whole answer was read into memory, and Real-Debrid sends the
/// whole file whatever the Range asks for: the 1 Nov log has "HTTP 206,
/// 885 MB in 17216 ms", then 891, 977 and 926 MB, for every next episode —
/// a second download of each file, held in RAM (the memory warnings and the
/// app ended while the next episode loaded, 27 Oct).
enum LinkWarmer {
    /// Hosts that answered without a redirect this launch (a NAS, most
    /// WebDAV servers): their files aren't asked twice before mpv opens them.
    @MainActor static var direct: Set<String> = []

    /// As `resolve`, but for a link followed before (1.28.9) its saved
    /// download address is asked at the same time, and whichever answers
    /// first plays. An addon's playback link goes through the addon's own
    /// server on the way to the debrid service: the 11 Nov log has
    /// "link answered HTTP 206 in 34.2 s" for a Continue Watching card,
    /// with the player showing nothing meanwhile. The address it led to
    /// answers in under a second for as long as the debrid service keeps it.
    /// Returns where the link led, and whether that came from the saved
    /// address. Nothing is saved here (1.28.10): 1.28.9 saved whatever a
    /// link led to, and a debrid addon answers a link whose file isn't
    /// ready with a short "downloading" clip, which would then have won
    /// every race for half a day. The player saves an address once the
    /// file it led to has really loaded (PlayerModel.rememberAddress).
    static func resolveFast(_ url: URL, headers: [String: String], purpose: String) async -> (address: URL?, fromSaved: Bool) {
        guard let saved = await ResolvedLinks.shared.address(for: url) else {
            return (await resolve(url, headers: headers, purpose: purpose), false)
        }
        let t0 = Date()
        return await withTaskGroup(of: (url: URL?, saved: Bool).self) { group in
            // The saved address must answer as a file does: part of it (206), not a page.
            group.addTask { (await resolve(saved, headers: [:], purpose: purpose + " (its saved address)", timeout: 8, asFile: true), true) }
            group.addTask { (await resolve(url, headers: headers, purpose: purpose), false) }
            var winner: (address: URL?, fromSaved: Bool) = (nil, false)
            for await answer in group {
                if let u = answer.url {
                    winner = (u, answer.saved)
                    if answer.saved {
                        dlog("player", String(format: "%@: played from its saved download address after %.1f s, without waiting for the link", purpose, Date().timeIntervalSince(t0)))
                    }
                    group.cancelAll()           // the other request ends at once
                    break
                } else if answer.saved {
                    await ResolvedLinks.shared.forget(url)      // no longer kept there: the link decides
                }
            }
            return winner
        }
    }

    /// `asFile`: only an answer a file gives counts (206 to the byte range,
    /// and not a web page): for a saved address, which an expired one may
    /// answer with its error page.
    static func resolve(_ url: URL, headers: [String: String], purpose: String = "next episode", timeout: TimeInterval = 40, asFile: Bool = false) async -> URL? {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        r.setValue("libmpv", forHTTPHeaderField: "User-Agent")       // what the player sends
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let t0 = Date()
        let host = url.host ?? "?"
        let others = NetTrace.begin(host)
        defer { NetTrace.end(host) }
        let timer = NetTrace.Timer()
        let c0 = CFAbsoluteTimeGetCurrent()
        let response: URLResponse
        do {
            let (body, r) = try await URLSession.shared.bytes(for: r, delegate: timer)
            body.task.cancel()                      // the headers are all it needs
            response = r
        } catch {
            // The race's other request, ended on purpose (1.28.10): not "didn't answer".
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return nil }
            NetTrace.report("link", url: url, others: others, started: c0, timer: timer, status: nil, bytes: nil, error: error)
            dlog("player", "\(purpose): link didn't answer")
            return nil
        }
        NetTrace.report("link", url: url, others: others, started: c0, timer: timer, status: (response as? HTTPURLResponse)?.statusCode, bytes: 0, error: nil)
        guard let http = response as? HTTPURLResponse else { return nil }
        dlog("player", String(format: "%@: link answered HTTP %d in %.1f s%@", purpose, http.statusCode, Date().timeIntervalSince(t0),
                              http.url?.host != url.host ? " (redirected to \(http.url?.host ?? "?"))" : ""))
        if asFile {
            let page = ChunkPlan.isPage(contentType: http.value(forHTTPHeaderField: "Content-Type"), fileName: url.lastPathComponent)
            guard http.statusCode == 206, !page else { return nil }
        }
        return (200..<300).contains(http.statusCode) ? http.url : nil
    }
}

/// Where a stream link led the last time it was followed (1.28.9), kept for
/// half a day: LinkWarmer.resolveFast asks it alongside the link. In
/// Application Support, like the history that holds the links themselves.
actor ResolvedLinks {
    static let shared = ResolvedLinks()
    static let life: TimeInterval = 12 * 3600
    static let limit = 60

    private struct Entry: Codable { var address: URL; var at: Date }
    private var entries: [String: Entry]?
    private let file: URL

    init(file: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.file = file ?? dir.appendingPathComponent("resolved-links.json")
    }

    private func loaded() -> [String: Entry] {
        if let entries { return entries }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = read
        return read
    }

    func address(for link: URL, now: Date = Date()) -> URL? {
        guard let e = loaded()[link.absoluteString], now.timeIntervalSince(e.at) < Self.life, e.address != link else { return nil }
        return e.address
    }

    func keep(_ address: URL, for link: URL, now: Date = Date()) {
        var all = loaded().filter { now.timeIntervalSince($0.value.at) < Self.life }
        all[link.absoluteString] = Entry(address: address, at: now)
        if all.count > Self.limit {
            for k in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - Self.limit).map(\.key) { all[k] = nil }
        }
        entries = all
        save()
    }

    func forget(_ link: URL) {
        var all = loaded()
        guard all.removeValue(forKey: link.absoluteString) != nil else { return }
        entries = all
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries ?? [:]) { try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
}
