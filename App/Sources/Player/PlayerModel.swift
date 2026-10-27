import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine
import CoreVideo

struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let type: String          // video | audio | sub
    let title: String?
    let lang: String?
    let codec: String?
    let profile: String?
    let selected: Bool
    let external: Bool
    let isDefault: Bool
    let channels: String?
    let channelCount: Int?
    let dvProfile: Int?
    let width: Int?
    let height: Int?

    var languageName: String? {
        guard let lang, !lang.isEmpty else { return nil }
        return Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()
    }

    /// Menu title, e.g. "English · Dolby TrueHD Atmos 7.1".
    var label: String {
        var parts: [String] = []
        if let languageName { parts.append(languageName) }
        if let title, !title.isEmpty, title.lowercased() != languageName?.lowercased() { parts.append(title) }
        if parts.isEmpty { parts.append("Track \(id)") }
        return parts.joined(separator: " · ")
    }

    var detail: String {
        var parts: [String] = []
        switch type {
        case "audio":
            parts.append(AudioFormat.name(codec: codec, profile: profile))
            if let ch = AudioFormat.channelLayout(channels: channels, count: channelCount) { parts.append(ch) }
        case "video":
            if let dv = dvProfile, dv > 0 { parts.append("Dolby Vision P\(dv)") }
            if let codec { parts.append(codec.uppercased()) }
            if let w = width, let h = height, w > 0 { parts.append("\(w)×\(h)") }
        default:
            if let codec { parts.append(AudioFormat.subtitleName(codec)) }
        }
        if external { parts.append("External") }
        if isDefault { parts.append("Default") }
        return parts.joined(separator: " · ")
    }
}

enum AudioFormat {
    static func name(codec: String?, profile: String?) -> String {
        let c = (codec ?? "").lowercased()
        let p = profile ?? ""
        let atmos = p.localizedCaseInsensitiveContains("atmos")
        switch c {
        case "eac3": return atmos ? "Dolby Digital Plus · Atmos" : "Dolby Digital Plus"
        case "ac3": return "Dolby Digital"
        case "truehd", "mlp": return atmos ? "Dolby TrueHD · Atmos" : "Dolby TrueHD"
        case "dts", "dca":
            if p.contains("DTS:X") { return p.contains("IMAX") ? "DTS:X IMAX" : "DTS:X" }
            if p.contains("MA") { return "DTS-HD MA" }
            if p.contains("HRA") { return "DTS-HD HRA" }
            if p.contains("Express") { return "DTS Express" }
            if p.contains("ES") { return "DTS-ES" }
            return "DTS"
        case "aac": return p.contains("HE") ? "HE-AAC" : "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        case "vorbis": return "Vorbis"
        default:
            if c.hasPrefix("pcm") { return "PCM" }
            return c.isEmpty ? "Audio" : c.uppercased()
        }
    }

    static func channelLayout(channels: String?, count: Int?) -> String? {
        if let n = count, n > 0 {
            switch n {
            case 1: return "Mono"
            case 2: return "Stereo"
            case 6: return "5.1"
            case 8: return "7.1"
            default: return "\(n) ch"
            }
        }
        guard let channels, !channels.isEmpty else { return nil }
        return channels.replacingOccurrences(of: "(side)", with: "")
    }

    static func subtitleName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "ass", "ssa": return "ASS"
        case "subrip", "srt": return "SRT"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvd_subtitle", "dvdsub": return "VobSub"
        case "webvtt": return "WebVTT"
        case "mov_text": return "TX3G"
        default: return codec.uppercased()
        }
    }
}

struct MediaChapter: Identifiable, Hashable {
    let id: Int
    let title: String
    let time: Double
}

/// High-frequency playback state, split out so position ticks only
/// re-render the time labels and seek bar — not the whole player UI.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var cacheAhead: Double = 0
}

@MainActor
final class PlayerModel: ObservableObject {
    // MARK: Published (low-frequency) state
    @Published var paused = false
    @Published var buffering = false
    @Published var speed: Double = 1
    @Published var mediaTitle: String = ""
    @Published var tracks: [MediaTrack] = []
    @Published var chapters: [MediaChapter] = []
    @Published var currentChapter: Int = -1
    @Published var sid = "auto"
    @Published var subDelay: Double = 0
    @Published var audioDelay: Double = 0
    @Published var videoSize: CGSize = .zero
    @Published var hwdecCurrent = ""
    @Published var videoFormat = ""          // "Dolby Vision", "HDR10", "HLG", "SDR"
    @Published var audioOut = ""
    @Published var ended = false
    @Published var errorMessage: String?
    @Published var isPiPActive = false
    @Published var isPiPPossible = false
    @Published var segments: [SkipSegment] = []
    @Published var activeSegment: SkipSegment?
    @Published var toast: String?
    @Published var isLoading = true
    @Published var activeShaders: [String] = MPVFiles.activeShaderNames
    @Published var zoomToFill = false
    @Published var aspectOverride = "no"
    @Published var queueIndex: Int
    @Published var holdSpeedActive = false
    @Published var userMarkers: [UserMarker] = []
    @Published var holdSpeed: Double = UserDefaults.standard.double(forKey: SettingsKey.holdSpeedValue) {
        didSet { UserDefaults.standard.set(holdSpeed, forKey: SettingsKey.holdSpeedValue) }
    }
    @Published var holdEnabled: Bool = UserDefaults.standard.bool(forKey: SettingsKey.holdToSpeed) {
        didSet { UserDefaults.standard.set(holdEnabled, forKey: SettingsKey.holdToSpeed) }
    }

    let clock = PlaybackClock()
    /// Unthrottled position for logic (skip markers, history).
    private(set) var position: Double = 0
    var duration: Double { clock.duration }

    let queue: [MediaItem]
    var item: MediaItem { resolvedItems[queueIndex] ?? queue[queueIndex] }
    /// Play Season: episodes whose stream was found when their turn came.
    private var resolvedItems: [Int: MediaItem] = [:]
    var hasNext: Bool { queueIndex + 1 < queue.count }
    var hasPrevious: Bool { queueIndex > 0 }

    // MARK: Rendering
    enum Renderer { case metal, gl }
    let renderer: Renderer
    let videoView: UIView
    private let metalView: MetalVideoView?
    private let glView: MPVRenderView?
    let pip = PiPManager()
    nonisolated let pipState = PiPStateBox()
    private lazy var sw = MPVSoftwareRenderer(output: pip.makeSink())
    weak var videoContainer: UIView?

    private(set) var client: MPVClient?
    private enum Mode { case main, sw, none }
    private var mode: Mode = .none
    private var vidSaved: String?
    private var videoOffForBackground = false
    /// Left the app while paused: the video track stays on (its buffer with
    /// it); only the Metal view is parked.
    private var parkedPaused = false
    private var pendingMain = false
    private var pipRestoring = false
    private var energyNoteFor: String?
    private var awaitingFirstFrameAfterPiP = false

    private var snapshotTimer: Timer?
    private let snapshotQueue = DispatchQueue(label: "glassplayer.snapshot", qos: .utility)
    private var snapshotPool: CVPixelBufferPool?
    private var snapshotPoolSize = (0, 0)

    private var scopedURL: URL?
    private var lastHistorySave = Date.distantPast
    private var lastPiPSync = Date.distantPast
    private var autoSkipped: Set<String> = []
    private var segmentsRequested = false
    private var fileLoaded = false
    private var observers: [NSObjectProtocol] = []
    private var toastWork: DispatchWorkItem?
    private var speedBeforeHold: Double = 1
    private var started = false
    private var closed = false
    private var loadStarted = Date()
    private var pendingW = 0, pendingH = 0
    var onClose: (() -> Void)?

    private let defaults = UserDefaults.standard

    init?(queue: [MediaItem], startIndex: Int = 0) {
        guard !queue.isEmpty else { return nil }
        self.queue = queue
        self.queueIndex = min(max(0, startIndex), queue.count - 1)
        if UserDefaults.standard.string(forKey: SettingsKey.renderer) == "gl", let gl = MPVRenderView.make() {
            renderer = .gl
            glView = gl
            metalView = nil
            videoView = gl
        } else {
            let mv = MetalVideoView()
            renderer = .metal
            metalView = mv
            glView = nil
            videoView = mv
        }
    }

    // MARK: Lifecycle

    /// Called once the player view is on screen with its final size.
    func start() {
        guard !started else { return }
        started = true
        configureAudioSession()
        dlog("player", "start renderer=\(renderer)")
        if CommandLine.arguments.contains("-labNoEngine") { dlog("lab", "engine not started (lab)"); return }
        guard let c = MPVClient() else {
            dlog("player/error", "mpv_create failed")
            errorMessage = "Could not create the mpv player."
            return
        }
        applyOptions(c)
        do {
            try c.initialize(logLevel: defaults.string(forKey: SettingsKey.logLevel) ?? "info")
        } catch {
            errorMessage = "mpv failed to start: \(error.localizedDescription). Check mpv.conf for invalid options."
            return
        }
        c.delegate = self
        client = c
        observe(c)

        if let glView {
            do { try glView.attach(to: c) } catch {
                errorMessage = "Video output failed: \(error.localizedDescription)"
            }
        }
        metalView?.onResize = { [weak self] in self?.nudgeRedraw() }
        mode = .main

        if defaults.bool(forKey: SettingsKey.pipEnabled), PiPManager.isSupported {
            pip.delegate = self
            pip.onPossibleChanged = { [weak self] in self?.isPiPPossible = $0 }
            pip.setUp(autoStart: defaults.bool(forKey: SettingsKey.pipAuto))
            startPiPFeed()
        }

        registerLifecycle()
        setUpRemoteCommands()
        load(item)
        UIApplication.shared.isIdleTimerDisabled = true
        EnergyMonitor.shared.playing = true
        EnergyMonitor.shared.note = "renderer=\(renderer) picture=\(PictureMode.current.rawValue)"
    }

    func close() {
        guard !closed else { return }
        closed = true
        screener?.cancel()
        dlog("player", "close at \(Self.format(position))")
        saveHistory(force: true)
        HistoryStore.shared.flush()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        tearDownRemoteCommands()
        stopPiPFeed()
        snapshotQueue.sync {}
        captureThumbnail()
        pip.tearDown()
        if mode == .sw { sw.detach() }
        glView?.detach()
        mode = .none
        let scoped = scopedURL
        scopedURL = nil
        client?.delegate = nil
        if renderer == .metal { detachMetalView() }   // mpv's Metal thread ends during shutdown
        client?.shutdown {
            scoped?.stopAccessingSecurityScopedResource()
        }
        client = nil
        UIApplication.shared.isIdleTimerDisabled = false
        EnergyMonitor.shared.sample(reason: "player closing")
        EnergyMonitor.shared.playing = false
        EnergyMonitor.shared.note = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onClose?()
    }

    private func applyOptions(_ c: MPVClient) {
        switch renderer {
        case .metal:
            c.setOption("wid", int64: metalView!.wid)
            c.setOption("vo", "gpu-next")
            c.setOption("gpu-api", "vulkan")
            c.setOption("gpu-context", "moltenvk")
            let edr = UIScreen.main.potentialEDRHeadroom > 1.0
            if defaults.bool(forKey: SettingsKey.hdrOutput) && edr {
                // HDR / Dolby Vision passthrough to the EDR display.
                c.setOption("target-colorspace-hint", "yes")
            }
        case .gl:
            c.setOption("vo", "libmpv")
            c.setOption("gpu-api", "opengl")
            c.setOption("opengl-es", "yes")
        }
        switch defaults.string(forKey: SettingsKey.hwdec) ?? "auto" {
        case "copy": c.setOption("hwdec", "videotoolbox-copy")
        case "no": c.setOption("hwdec", "no")
        // Copy fallback lets the CPU (PiP) renderer keep hardware decoding.
        default: c.setOption("hwdec", "videotoolbox,videotoolbox-copy")
        }
        c.setOption("config", "yes")
        c.setOption("config-dir", MPVFiles.configDir.path)
        c.setOption("load-scripts", "yes")
        c.setOption("osc", "no")
        c.setOption("load-stats-overlay", "no")   // the app has its own live stats card
        c.setOption("ytdl", "no")
        c.setOption("input-default-bindings", "yes")
        c.setOption("terminal", "no")
        c.setOption("idle", "yes")
        c.setOption("keep-open", "yes")
        c.setOption("log-file", MPVFiles.logFile.path)
        c.setOption("screenshot-directory", MPVFiles.screenshotsDir.path)
        c.setOption("watch-later-dir", MPVFiles.watchLaterDir.path)
        c.setOption("resume-playback", "no")
        c.setOption("save-position-on-quit", "no")
        c.setOption("cache", "yes")
        let cacheMB = max(32, defaults.integer(forKey: SettingsKey.cacheMB))
        c.setOption("demuxer-max-bytes", "\(cacheMB)MiB")
        c.setOption("demuxer-max-back-bytes", "\(max(16, cacheMB / 3))MiB")
        c.setOption("demuxer-readahead-secs", "60")
        c.setOption("network-timeout", "30")
        c.setOption("hr-seek-framedrop", "yes")
        // Audio: multichannel PCM out (AirPlay / HDMI surround, Spatial Audio on AirPods).
        let aoOverride = CommandLine.arguments.first { $0.hasPrefix("-labAO=") }.map { String($0.dropFirst(7)) }.flatMap { $0 == "default" ? nil : $0 }
        // AudioUnit first: measured in the CI A/V lab, the AVFoundation output
        // froze the picture for seconds on a speed change (hold for 2×) or a
        // renderer switch (PiP), and left audio up to 3 s out of sync for ~10 s.
        // AudioUnit stayed within 0.17 s and recovered in about a second.
        c.setOption("ao", aoOverride ?? "audiounit,avfoundation")
        c.setOption("audio-channels", defaults.bool(forKey: SettingsKey.surroundAudio) ? "auto" : "stereo")
        c.setOption("sub-auto", "fuzzy")
        if defaults.string(forKey: SettingsKey.subtitlesDefault) == "off" { c.setOption("sid", "no") }
        c.setOption("audio-normalize-downmix", defaults.bool(forKey: SettingsKey.downmixNormalize) ? "yes" : "no")
        if defaults.bool(forKey: SettingsKey.lfeInDownmix) { c.setOption("audio-swresample-o", "lfe_mix_level=1") }
        c.setOption("embeddedfonts", "yes")
        c.setOption("sub-fonts-dir", MPVFiles.fontsDir.path)
        if let s = defaults.string(forKey: SettingsKey.subLangs), !s.isEmpty { c.setOption("slang", s) }
        if let s = defaults.string(forKey: SettingsKey.audioLangs), !s.isEmpty { c.setOption("alang", s) }
        c.setOption("sub-scale", String(defaults.double(forKey: SettingsKey.subScale)))
        c.setOption("sub-bold", defaults.bool(forKey: SettingsKey.subBold) ? "yes" : "no")
        if defaults.bool(forKey: SettingsKey.subBox) {
            c.setOption("sub-border-style", "background-box")
            c.setOption("sub-back-color", "0.0/0.0/0.0/0.6")
        }
        c.setOption("sub-pos", String(defaults.integer(forKey: SettingsKey.subPos)))
        c.setOption("speed", String(defaults.double(forKey: SettingsKey.defaultSpeed)))
        let shaders = Anime4K.currentShaderList()
        if !shaders.isEmpty { c.setOption("glsl-shaders", shaders) }
        for (k, v) in PictureMode.current.options { c.setOption(k, v) }
        c.setOption("volume-max", "200")
        let boost = defaults.integer(forKey: SettingsKey.audioBoost)
        if boost > 0 { c.setOption("volume", String(100 + boost)) }
        dlog("player", "mpv options applied renderer=\(renderer) hwdec=\(defaults.string(forKey: SettingsKey.hwdec) ?? "auto") anime4k=\(Anime4K.mode.rawValue)/\(Anime4K.quality.rawValue) picture=\(PictureMode.current.rawValue)")
    }

    // MARK: Quality toggles (live)

    @Published var pictureMode: PictureMode = PictureMode.current {
        didSet {
            PictureMode.current = pictureMode
            for (k, v) in pictureMode.options { client?.set(k, v) }
            dlog("player", "picture mode \(pictureMode.rawValue)")
        }
    }
    @Published var anime4kMode: Anime4KMode = Anime4K.mode {
        didSet { Anime4K.mode = anime4kMode; applyShaderList() }
    }
    @Published var anime4kQuality: Anime4KQuality = Anime4K.quality {
        didSet { Anime4K.quality = anime4kQuality; applyShaderList() }
    }
    @Published var audioBoost: Int = UserDefaults.standard.integer(forKey: SettingsKey.audioBoost) {
        didSet {
            UserDefaults.standard.set(audioBoost, forKey: SettingsKey.audioBoost)
            client?.set("volume", Double(100 + audioBoost))
        }
    }
    @Published var playbackMode: String = UserDefaults.standard.string(forKey: SettingsKey.playbackMode) ?? "playlist" {
        didSet {
            UserDefaults.standard.set(playbackMode, forKey: SettingsKey.playbackMode)
            client?.set("loop-file", playbackMode == "loop" ? "inf" : "no")
        }
    }

    /// Forces the VO to re-render at the new drawable size even while paused
    /// (otherwise the old frame stays stretched until the next decoded frame).
    private var nudgeWork: DispatchWorkItem?
    func nudgeRedraw() {
        guard mode == .main, renderer == .metal, let c = client else { return }
        nudgeWork?.cancel()
        let w = DispatchWorkItem { [weak c] in
            guard let c, !c.isShutDown else { return }
            c.command(["set", "video-zoom", "0.0001"])
            c.command(["set", "video-zoom", "0"])
        }
        nudgeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    private func applyShaderList() {
        client?.set("glsl-shaders", Anime4K.currentShaderList())
    }

    private func observe(_ c: MPVClient) {
        c.observe("time-pos", .double)
        c.observe("duration", .double)
        c.observe("pause", .flag)
        c.observe("paused-for-cache", .flag)
        c.observe("seeking", .flag)
        c.observe("eof-reached", .flag)
        c.observe("speed", .double)
        c.observe("media-title", .string)
        c.observe("track-list/count", .int)
        c.observe("chapter-list/count", .int)
        c.observe("chapter", .int)
        c.observe("aid", .string)
        c.observe("vid", .string)
        c.observe("sid", .string)
        c.observe("sub-delay", .double)
        c.observe("audio-delay", .double)
        c.observe("dwidth", .int)
        c.observe("dheight", .int)
        c.observe("hwdec-current", .string)
        c.observe("video-params/gamma", .string)
        c.observe("audio-out-params/channels", .string)
        c.observe("demuxer-cache-duration", .double)
        c.observe("panscan", .double)
    }

    // MARK: Loading

    func load(_ item: MediaItem) {
        guard let c = client else { return }
        if item.url.isEmpty, let pick = item.streamPick {
            resolveAndLoad(pick, index: queueIndex)
            return
        }
        // An episode found by the season check: its subtitles come now.
        if queue.indices.contains(queueIndex), queue[queueIndex].url.isEmpty, !subsFetched.contains(queueIndex),
           let ctx = item.streamPick?.context {
            subsFetched.insert(queueIndex)
            let index = queueIndex
            isLoading = true
            Task { [weak self] in
                guard let self else { return }
                var it = item
                it.subtitles += await AddonPlayback.subtitles(type: ctx.type, videoId: ctx.videoId)
                self.resolvedItems[index] = it
                guard self.queueIndex == index else { return }
                self.load(it)
            }
            return
        }
        saveHistory(force: true)
        ended = false
        errorMessage = nil
        segments = []
        activeSegment = nil
        autoSkipped = []
        upNext = nil
        upNextDismissed = false
        postCredits = false
        segmentsRequested = false
        fileLoaded = false
        isLoading = true
        position = 0
        clock.position = 0
        clock.duration = item.durationHint ?? 0
        tracks = []
        chapters = []
        loadStarted = Date()
        userMarkers = MarkerStore.shared.markers(for: item.id)
        mediaTitle = item.displayTitle

        if let old = scopedURL { old.stopAccessingSecurityScopedResource(); scopedURL = nil }
        if let u = item.resolvedURL, u.isFileURL, !u.path.hasPrefix(MPVFiles.documents.path) {
            if u.startAccessingSecurityScopedResource() { scopedURL = u }
        }

        c.command(["change-list", "http-header-fields", "clr", ""])
        c.set("user-agent", "libmpv")
        c.set("referrer", "")
        for (k, v) in item.headers {
            switch k.lowercased() {
            case "user-agent": c.set("user-agent", v)
            case "referer", "referrer": c.set("referrer", v)
            default: c.command(["change-list", "http-header-fields", "append", "\(k): \(v)"])
            }
        }

        let opts = startOptions(for: item, toast: true)
        c.set("demuxer-readahead-secs", "60")
        if let a = appended, a.index == queueIndex, a.path == item.mpvPath {
            // Prepared near the end of the last episode: next in mpv's playlist,
            // opened (and buffered, once the last file was fully read) already.
            appended = nil
            c.set("pause", false)
            let r = c.command(["playlist-next"])
            dlog("player", "playlist-next → the prepared episode \(item.displayTitle) -> \(r)")
        } else {
            appended = nil
            let r = c.command(["loadfile", item.mpvPath, "replace", "-1", opts.joined(separator: ",")])
            dlog("player", "loadfile \(item.mpvPath) source=\(item.source) opts=\(opts) -> \(r)")
        }
        updateNowPlaying()
    }

    private func startOptions(for item: MediaItem, toast: Bool) -> [String] {
        guard defaults.bool(forKey: SettingsKey.resumePlayback),
              let entry = HistoryStore.shared.entry(for: item.id), entry.canResume else { return [] }
        if toast { showToast("Resuming from \(Self.format(entry.position))") }
        return ["start=\(Int(entry.position))"]
    }

    /// Finds the next episode's stream (same addon, matching release), then plays it.
    private func resolveAndLoad(_ pick: StreamPick, index: Int) {
        if let done = resolvedItems[index] { load(done); return }
        saveHistory(force: true)
        isLoading = true
        ended = false
        errorMessage = nil
        mediaTitle = [pick.context.name, pick.context.videoLabel].compactMap { $0 }.joined(separator: " · ")
        showToast("Finding \(pick.context.videoLabel ?? "next episode")…")
        Task { [weak self] in
            guard let self else { return }
            let p = self.pick(for: index) ?? pick
            let match = await AddonPlayback.screen(p)
            guard self.queueIndex == index else { return }
            switch match {
            case .same(var found):
                self.episodeStates[index] = .ready
                found.subtitles += await AddonPlayback.subtitles(type: p.context.type, videoId: p.context.videoId)
                self.subsFetched.insert(index)
                guard self.queueIndex == index else { return }
                self.resolvedItems[index] = found
                self.load(found)
            case .other:
                self.episodeStates[index] = .pick
                self.isLoading = false
                self.askToPick(index)
            case .none:
                self.episodeStates[index] = .unavailable
                self.isLoading = false
                self.errorMessage = "No stream found for \(pick.context.videoLabel ?? "this episode") from the same addon. Pick one from the title page."
            }
        }
    }

    // MARK: Next episode (1.17.0)

    /// What the season check found for each later episode of an addon season.
    enum EpisodeState: Equatable { case checking, ready, pick, unavailable }
    @Published var episodeStates: [Int: EpisodeState] = [:]
    /// An episode with no stream of the release being watched: the picker.
    struct PickRequest: Identifiable, Equatable { let id: Int; let context: PlayContext }
    @Published var pickRequest: PickRequest?

    private var screener: Task<Void, Never>?
    private var preparing: Int?
    /// The next item, appended to mpv's playlist behind the current file.
    private var appended: (index: Int, path: String)?
    private var subsFetched: Set<Int> = []
    /// A stream picked by hand: later episodes follow that release.
    private var pickOverride: StreamPick?

    private func pick(for index: Int) -> StreamPick? {
        guard index < queue.count, var p = queue[index].streamPick else { return nil }
        if let o = pickOverride {
            let ctx = p.context
            p = o
            p.context = ctx
        }
        return p
    }

    /// Season check: asks the addon for each later episode, one at a time,
    /// whether it has the same release, so the playlist knows what's ready
    /// and what needs a pick. Starts a few seconds into playback.
    private func startScreener() {
        guard screener == nil, defaults.bool(forKey: SettingsKey.prepareNext),
              queue.indices.contains(where: { $0 > queueIndex && queue[$0].url.isEmpty && queue[$0].streamPick != nil }) else { return }
        screener = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            var ready = 0, picks = 0, missing = 0
            var i = (self?.queueIndex ?? 0) + 1
            while let self, !self.closed, i < self.queue.count, !Task.isCancelled {
                defer { i += 1 }
                guard self.queue[i].url.isEmpty, self.resolvedItems[i] == nil, self.episodeStates[i] == nil, let p = self.pick(for: i) else { continue }
                self.episodeStates[i] = .checking
                switch await AddonPlayback.screen(p) {
                case .same(let item): self.resolvedItems[i] = item; self.episodeStates[i] = .ready; ready += 1
                case .other: self.episodeStates[i] = .pick; picks += 1
                case .none: self.episodeStates[i] = .unavailable; missing += 1
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // one request at a time, gently
            }
            dlog("player", "season check: \(ready) ready, \(picks) need a pick, \(missing) unavailable")
            self?.screener = nil
        }
    }

    /// Near the end of an episode: get the next one ready (Settings →
    /// Playback → Get the next episode ready). Network items only; library
    /// files open at once anyway.
    private func maybePrepareNext() {
        guard defaults.bool(forKey: SettingsKey.prepareNext), hasNext, playbackMode == "playlist", preparing == nil, fileLoaded,
              duration > 120, duration - position < 180 else { return }
        let i = queueIndex + 1
        guard appended?.index != i, episodeStates[i] != .pick, episodeStates[i] != .unavailable else { return }
        let next = resolvedItems[i] ?? queue[i]
        guard next.url.isEmpty || next.resolvedURL?.isFileURL == false else { return }
        preparing = i
        Task { [weak self] in
            await self?.prepare(i)
            self?.preparing = nil
        }
    }

    private func prepare(_ i: Int) async {
        var item: MediaItem
        if let r = resolvedItems[i] {
            item = r
        } else if queue[i].url.isEmpty, let p = pick(for: i) {
            episodeStates[i] = .checking
            switch await AddonPlayback.screen(p) {
            case .same(let it): item = it; resolvedItems[i] = it; episodeStates[i] = .ready
            case .other: episodeStates[i] = .pick; return
            case .none: episodeStates[i] = .unavailable; return
            }
        } else {
            item = queue[i]
        }
        guard queueIndex + 1 == i, !closed else { return }
        if let ctx = item.streamPick?.context, !subsFetched.contains(i) {
            item.subtitles += await AddonPlayback.subtitles(type: ctx.type, videoId: ctx.videoId)
            subsFetched.insert(i)
            resolvedItems[i] = item
        }
        if let u = item.resolvedURL, !u.isFileURL, let final = await LinkWarmer.resolve(u, headers: item.headers), final != u {
            item.url = final.absoluteString
            resolvedItems[i] = item
        }
        guard queueIndex + 1 == i, !closed, fileLoaded, let c = client else { return }
        // Next in mpv's playlist: mpv opens it and starts filling its buffer as
        // soon as this file has been read to the end (prefetch-playlist; mpv
        // 0.41 loadfile.c, prefetch_next → demux_start_prefetch). Reading ahead
        // to the end of this file is allowed now so that happens early.
        c.set("keep-open", "always")                 // never move on by itself: Up Next / autoplay decide
        c.set("prefetch-playlist", "yes")
        c.set("demuxer-readahead-secs", String(Int(max(60, duration - position + 30))))
        c.command(["playlist-clear"])
        let opts = startOptions(for: item, toast: false)
        c.command(["loadfile", item.mpvPath, "append", "-1", opts.joined(separator: ",")])
        appended = (i, item.mpvPath)
        dlog("player", "next episode ready: \(item.displayTitle) — buffers once this file is read to the end")
    }

    /// Picker for an episode without the same release. What's playing carries
    /// on until a stream is picked (1.17.0 paused it, and the picker could not
    /// open over the Now Playing menu — 27 Oct report).
    private func askToPick(_ index: Int) {
        guard let ctx = queue[index].streamPick?.context else { return }
        pickRequest = PickRequest(id: index, context: ctx)
        dlog("player", "episode \(ctx.videoLabel ?? ctx.videoId): no stream of the same release; asking")
    }

    /// Lab (`-pickLab`): the picker for a made-up episode, over whatever is open.
    func labShowPicker() {
        pickRequest = PickRequest(id: max(0, queueIndex), context: PlayContext(name: "Lab Show", poster: nil, type: "series", metaId: "tt0000000",
                                                                             isAnime: false, videoId: "tt0000000:1:7", videoLabel: "S1 · E7", episode: 7))
        dlog("lab", "picker asked for (lab)")
    }

    func cancelPick() {
        if let r = pickRequest { dlog("player", "pick for episode \(r.id + 1) cancelled") }
        pickRequest = nil
    }

    /// A tap on a playlist row. The episode playing now keeps playing until the
    /// chosen one is ready to load: an addon episode is looked up first, and
    /// one without the same release opens the picker instead (1.17.0 stopped
    /// the current episode and then waited on a picker that never showed).
    /// The row of the episode playing now does nothing.
    func playFromPlaylist(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        guard i != queueIndex else {
            dlog("player", "playlist: the episode playing now — nothing to do")
            if paused { setPaused(false) }
            return
        }
        if let done = resolvedItems[i] { queueIndex = i; load(done); return }
        guard queue[i].url.isEmpty, let p = pick(for: i) else { queueIndex = i; load(queue[i]); return }
        switch episodeStates[i] {
        case .pick?, .unavailable?:
            askToPick(i)
        default:
            let label = p.context.videoLabel ?? "episode \(i + 1)"
            showToast("Finding \(label)…")
            episodeStates[i] = .checking
            Task { [weak self] in
                guard let self else { return }
                switch await AddonPlayback.screen(p) {
                case .same(var found):
                    self.episodeStates[i] = .ready
                    found.subtitles += await AddonPlayback.subtitles(type: p.context.type, videoId: p.context.videoId)
                    self.subsFetched.insert(i)
                    self.resolvedItems[i] = found
                    guard !self.closed else { return }
                    self.queueIndex = i
                    self.load(found)
                case .other:
                    self.episodeStates[i] = .pick
                    self.askToPick(i)
                case .none:
                    self.episodeStates[i] = .unavailable
                    self.askToPick(i)
                }
            }
        }
    }

    /// The stream you picked for an episode; the episodes after it follow that release.
    func playPicked(_ s: AddonStream, from addon: InstalledAddon, for request: PickRequest) {
        pickRequest = nil
        Task { [weak self] in
            guard let self else { return }
            let ctx = request.context
            let subs = await AddonPlayback.subtitles(type: ctx.type, videoId: ctx.videoId)
            guard let item = AddonPlayback.makeItem(ctx, stream: s, addon: addon, extraSubtitles: subs) else { return }
            self.pickOverride = AddonPlayback.pick(from: s, addon: addon, context: ctx)
            // Later episodes are checked again against the new release.
            for j in self.queue.indices where j > request.id && self.queue[j].url.isEmpty { self.episodeStates[j] = nil; self.resolvedItems[j] = nil }
            self.resolvedItems[request.id] = item
            self.subsFetched.insert(request.id)
            self.episodeStates[request.id] = .ready
            self.queueIndex = request.id
            self.load(item)
            self.screener?.cancel(); self.screener = nil
        }
    }

    func playNext() {
        guard hasNext else { return }
        let i = queueIndex + 1
        if episodeStates[i] == .pick {
            askToPick(i)
            return
        }
        queueIndex = i
        load(item)
    }

    func playPrevious() {
        if position > 10 || !hasPrevious { seek(to: 0); return }
        queueIndex -= 1
        load(item)
    }

    private func onFileLoaded() {
        guard let c = client else { return }
        dlog("player", "file loaded in \(String(format: "%.0f", Date().timeIntervalSince(loadStarted) * 1000)) ms")
        fileLoaded = true
        isLoading = false
        refreshTracks()
        refreshChapters()
        for sub in item.subtitles {
            c.commandAsync(["sub-add", sub.url, "auto", sub.title ?? sub.lang ?? "Addon", sub.lang ?? ""])
        }
        maybeRequestSegments()
        updateNowPlaying()
        startScreener()
    }

    // MARK: Tracks / chapters

    private var tracksRefreshPending = false

    func refreshTracks() {
        guard let c = client, !tracksRefreshPending else { return }
        tracksRefreshPending = true
        c.query({ c -> ([MediaTrack], String) in
            var list: [MediaTrack] = []
            let n = c.int("track-list/count") ?? 0
            for i in 0..<Int(n) {
                let p = "track-list/\(i)/"
                guard let id = c.int(p + "id"), let type = c.string(p + "type") else { continue }
                list.append(MediaTrack(
                    id: Int(id), type: type, title: c.string(p + "title"), lang: c.string(p + "lang"),
                    codec: c.string(p + "codec"), profile: c.string(p + "codec-profile"),
                    selected: c.flag(p + "selected") ?? false,
                    external: c.flag(p + "external") ?? false, isDefault: c.flag(p + "default") ?? false,
                    channels: type == "audio" ? c.string(p + "demux-channels") : nil,
                    channelCount: type == "audio" ? c.int(p + "demux-channel-count").map(Int.init) : nil,
                    dvProfile: type == "video" ? c.int(p + "dolby-vision-profile").map(Int.init) : nil,
                    width: type == "video" ? c.int(p + "demux-w").map(Int.init) : nil,
                    height: type == "video" ? c.int(p + "demux-h").map(Int.init) : nil
                ))
            }
            return (list, c.string("video-params/gamma") ?? "")
        }) { [weak self] result in
            guard let self else { return }
            self.tracksRefreshPending = false
            if result.0 != self.tracks { self.tracks = result.0 }
            self.updateVideoFormat(gamma: result.1)
        }
    }

    func refreshChapters() {
        guard let c = client else { chapters = []; return }
        c.query({ c -> [MediaChapter] in
            let n = c.int("chapter-list/count") ?? 0
            var list: [MediaChapter] = []
            for i in 0..<Int(n) {
                let t = c.double("chapter-list/\(i)/time") ?? 0
                let title = c.string("chapter-list/\(i)/title") ?? "Chapter \(i + 1)"
                list.append(MediaChapter(id: i, title: title, time: t))
            }
            return list
        }) { [weak self] list in
            guard let self else { return }
            if list != self.chapters { self.chapters = list }
        }
    }

    func tracks(_ type: String) -> [MediaTrack] { tracks.filter { $0.type == type } }

    func selectTrack(_ type: String, id: Int?) {
        let prop = type == "audio" ? "aid" : type == "sub" ? "sid" : "vid"
        client?.set(prop, id.map(String.init) ?? "no")
    }

    func addSubtitle(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        if scoped { url.stopAccessingSecurityScopedResource() }
        client?.command(["sub-add", dest.path, "select"])
    }

    private var lastGamma = ""
    private func updateVideoFormat(gamma: String? = nil) {
        if let gamma { lastGamma = gamma }
        let gamma = lastGamma
        let dv = tracks.first { $0.type == "video" && $0.selected }?.dvProfile ?? 0
        if dv > 0 { videoFormat = "Dolby Vision" }
        else if gamma == "pq" { videoFormat = "HDR10" }
        else if gamma == "hlg" { videoFormat = "HLG" }
        else { videoFormat = gamma.isEmpty ? "" : "SDR" }
    }

    // MARK: Transport

    func togglePause() {
        if ended { seek(to: 0); client?.set("pause", false); ended = false; return }
        client?.set("pause", !paused)
    }
    func setPaused(_ p: Bool) { client?.set("pause", p) }

    // Seeks are queued asynchronously: a synchronous mpv_command waits for
    // the core, which on a network file can take long enough to freeze the
    // button that was tapped.
    func seek(by seconds: Double) {
        _ = client?.commandAsync(["seek", String(seconds), "relative+exact"])
    }

    func seek(to seconds: Double, exact: Bool = true) {
        _ = client?.commandAsync(["seek", String(max(0, seconds)), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    /// Live preview while scrubbing: the video jumps to the nearest keyframe
    /// as the finger moves (throttled), so the main screen shows where you are.
    private var lastScrubSeek = Date.distantPast
    func scrub(to seconds: Double) {
        clock.position = seconds
        guard Date().timeIntervalSince(lastScrubSeek) > 0.1 else { return }
        lastScrubSeek = Date()
        _ = client?.commandAsync(["seek", String(max(0, seconds)), "absolute+keyframes"])
    }

    func setSpeed(_ s: Double) { client?.set("speed", s) }

    func beginHoldSpeed() {
        guard holdEnabled, !paused, !holdSpeedActive else { return }
        speedBeforeHold = speed
        holdSpeedActive = true
        setSpeed(holdSpeed)
        traceAV("hold \(holdSpeed)x")
    }

    func endHoldSpeed() {
        guard holdSpeedActive else { return }
        holdSpeedActive = false
        setSpeed(speedBeforeHold)
        traceAV("release")
    }

    /// For 3 s after a speed or renderer change, samples A/V offset and
    /// whether the picture advances; logs one summary line (for the log you send).
    func traceAV(_ label: String) {
        guard let c = client else { return }
        var samples: [(t: Double, a: Double, sync: Double)] = []
        let start = Date()
        func sample() {
            c.query({ c in (c.double("time-pos") ?? -1, c.double("audio-pts") ?? -1, c.double("avsync") ?? 0) }) { [weak self] r in
                samples.append((r.0, r.1, r.2))
                if Date().timeIntervalSince(start) < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { sample() }
                } else {
                    var stalled = 0.0
                    for i in 1..<max(1, samples.count) where abs(samples[i].t - samples[i - 1].t) < 0.01 { stalled += 0.2 }
                    let worst = samples.map { abs($0.sync) }.max() ?? 0
                    let ao = self.map { _ in c.string("current-ao") ?? "?" } ?? "?"
                    dlog("av", String(format: "%@: worst A/V offset %.0f ms, picture still for %.1f s of 3 (ao %@)", label, worst * 1000, stalled, ao))
                }
            }
        }
        sample()
    }

    func setVolume(_ v: Double) { client?.set("volume", min(150, max(0, v))) }
    var volume: Double { client?.double("volume") ?? 100 }
    func setSubDelay(_ v: Double) { client?.set("sub-delay", v) }
    func setAudioDelay(_ v: Double) { client?.set("audio-delay", v) }
    func setSubScale(_ v: Double) { client?.set("sub-scale", v) }

    func toggleZoom() {
        client?.set("panscan", zoomToFill ? 0.0 : 1.0)
        showToast(zoomToFill ? "Fit" : "Fill")
    }

    func setAspect(_ value: String) {
        aspectOverride = value
        client?.set("video-aspect-override", value)
    }

    func screenshot() {
        client?.command(["screenshot", "subtitles"])
        showToast("Screenshot saved")
    }

    func skip(_ segment: SkipSegment) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showToast("Skipped \(segment.kind.chapterTitle.lowercased())")
        seek(to: segment.end)
        autoSkipped.insert(segment.id)
        skipSuppressedUntil = Date().addingTimeInterval(3)   // position still reads "inside" until the seek lands
        activeSegment = nil
    }
    private var skipSuppressedUntil = Date.distantPast

    func jump(to chapter: MediaChapter) { seek(to: chapter.time) }

    func addMarker() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let t = position
        var list = userMarkers
        list.append(UserMarker(time: t, title: "Marker \(list.count + 1) · \(Self.format(t))"))
        list.sort { $0.time < $1.time }
        userMarkers = list
        MarkerStore.shared.set(list, for: item.id)
        showToast("Marker added at \(Self.format(t))")
    }

    func removeMarker(_ m: UserMarker) {
        userMarkers.removeAll { $0.id == m.id }
        MarkerStore.shared.set(userMarkers, for: item.id)
    }

    @discardableResult
    func run(command: String) -> Bool {
        guard let c = client else { return false }
        let r = c.commandString(command)
        if r < 0 { showToast("Command failed: \(String(cString: mpv_error_string(r)))") }
        return r >= 0
    }

    func keyDown(_ key: String) { client?.command(["keydown", key]) }
    func keyUp(_ key: String) { client?.command(["keyup", key]) }

    func setShaders(_ names: [String]) {
        MPVFiles.activeShaderNames = names
        activeShaders = names
        applyShaderList()
        showToast(names.isEmpty ? "Shaders off" : "\(names.count) shader\(names.count == 1 ? "" : "s") on")
    }

    func startPiP() { pip.start() }
    func stopPiP() { pip.stop() }

    // MARK: Toast

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }

    // MARK: History

    func saveHistory(force: Bool = false) {
        guard fileLoaded, duration > 0 || position > 0 else { return }
        if !force && Date().timeIntervalSince(lastHistorySave) < 5 { return }
        lastHistorySave = Date()
        var stored = item
        if stored.title.isEmpty { stored.title = mediaTitle }
        HistoryStore.shared.record(stored, position: position, duration: duration)
    }

    // MARK: Skip segments

    private func maybeRequestSegments() {
        guard fileLoaded, !segmentsRequested, duration > 0 else { return }
        segmentsRequested = true
        // Looked up even with the Skip button off: Up Next uses the credits time.
        if defaults.bool(forKey: SettingsKey.skipUseChapters) {
            let chs = chapters.map { ($0.title, $0.time) }
            let s = SkipService.tidy(SkipService.segments(fromChapters: chs, duration: duration), duration: duration, chapters: chs, anime: item.anime != nil)
            if !s.isEmpty { segments = s; dlog("skip", "from chapters: \(s.map { "\($0.label) \(Int($0.start))-\(Int($0.end))" })"); return }
        }

        let name = item.resolvedURL?.lastPathComponent ?? item.title
        let fileName = TitleParser.isMedia(name) ? name : item.title
        let parsed = TitleParser.parse(fileName)
        var hint = item.anime ?? AnimeHint()
        if hint.title == nil { hint.title = parsed.title }
        if hint.episode == nil { hint.episode = parsed.episode }
        let explicitAnime = item.anime != nil
        // Fansub naming ("[Group] Title - 05") is a strong anime signal.
        let fansubName = fileName.hasPrefix("[") || fileName.range(of: #" - \d{1,4}\b"#, options: .regularExpression) != nil
        let key = item.id
        let dur = duration
        let len = defaults.double(forKey: SettingsKey.skipOATLength)
        Task { [weak self] in
            var found = SkipLookup()
            let meta = await MetadataService.shared.lookup(filename: fileName)
            if let meta, meta.id.hasPrefix("tt") {
                found = await SkipService.shared.lookupTV(imdbId: meta.id, season: parsed.episode != nil ? (parsed.season ?? 1) : nil,
                                                          episode: parsed.episode, duration: dur)
            }
            // Anime databases only for anime: an explicit hint, animation per
            // IMDb, or an unknown title with fansub-style naming. Never a
            // fuzzy anime search for a live-action show.
            let animation = meta?.genres?.contains { $0.localizedCaseInsensitiveContains("anim") } ?? false
            if found.segments.isEmpty, hint.episode != nil, explicitAnime || animation || (meta == nil && fansubName) {
                found.segments = await SkipService.shared.lookup(hint: hint, season: parsed.season, duration: dur, oatLength: len > 0 ? len : 90)
                dlog("skip", "anime lookup \(hint.title ?? "?") s\(parsed.season ?? 1)e\(hint.episode ?? 0): \(found.segments.count) segment(s)")
            }
            await MainActor.run {
                guard let self, self.item.id == key else { return }
                self.postCredits = found.postCredits
                guard !found.segments.isEmpty else { return }
                let anime = explicitAnime || animation || found.segments.contains { $0.source == "AniSkip" || $0.source == "OAT" }
                self.segments = SkipService.tidy(found.segments, duration: dur, chapters: self.chapters.map { ($0.title, $0.time) }, anime: anime)
                dlog("skip", "segments: \(self.segments.map { "\($0.label) \(Int($0.start))-\(Int($0.end))" })")
                if self.defaults.bool(forKey: SettingsKey.skipInjectChapters), self.chapters.isEmpty {
                    self.injectChapters(found.segments)
                }
            }
        }
    }

    // MARK: Up Next

    struct UpNext: Equatable {
        let start: Double          // playback time the card appeared at
        let autoplay: Bool         // counts down and plays the next file
        let next: MediaItem
    }
    @Published var upNext: UpNext?
    private var upNextDismissed = false
    private var postCredits = false
    static let upNextCountdown = 10.0

    /// When the card appears: the start of the credits (file chapters,
    /// IntroDB / TheIntroDB, AniSkip ending) if known, else 30 s before the end.
    private var upNextTrigger: (time: Double, autoplay: Bool)? {
        guard hasNext, playbackMode == "playlist", defaults.bool(forKey: SettingsKey.upNextEnabled), duration > 120 else { return nil }
        let autoplayOn = defaults.bool(forKey: SettingsKey.autoplayNext)
        if let outro = segments.filter({ $0.kind == .outro && $0.start > duration * 0.5 }).first {
            // Story content after the credits (and not a "next episode" preview)
            // means a post-credits scene: show the card, but don't jump away.
            let after = duration - outro.end
            let previewFollows = segments.contains { $0.kind == .preview && $0.start >= outro.end - 2 }
            let sceneAfter = postCredits || (after > 30 && !previewFollows)
            return (outro.start, autoplayOn && !sceneAfter)
        }
        // No credits known but a skippable preview closes the episode: the card
        // takes over there instead of a "Skip Preview" pill.
        if let preview = segments.filter({ $0.kind == .preview && $0.start > duration * 0.6 }).first {
            return (preview.start, autoplayOn && !postCredits)
        }
        return (max(duration * 0.9, duration - 30), autoplayOn && !postCredits)
    }

    private func updateUpNext() {
        guard !upNextDismissed, let trigger = upNextTrigger else {
            if upNext != nil { upNext = nil }
            return
        }
        if position >= trigger.time && position < duration - 0.3 {
            if upNext == nil { upNext = UpNext(start: trigger.time, autoplay: trigger.autoplay, next: queue[queueIndex + 1]) }
            if trigger.autoplay, !paused, position >= trigger.time + Self.upNextCountdown {
                upNext = nil
                dlog("player", "up next: countdown finished")
                playNext()
            }
        } else if upNext != nil {
            upNext = nil      // seeked back before the credits
        }
    }

    func dismissUpNext() {
        upNextDismissed = true
        upNext = nil
    }

    private func injectChapters(_ segs: [SkipSegment]) {
        var marks: [(title: String, time: Double)] = []
        let sorted = segs.sorted { $0.start < $1.start }
        if let first = sorted.first, first.start > 1 { marks.append(("Episode", 0)) }
        for (i, s) in sorted.enumerated() {
            marks.append((s.kind.chapterTitle, s.start))
            let nextStart = i + 1 < sorted.count ? sorted[i + 1].start : duration
            if s.end < nextStart - 1, s.end < duration - 1 { marks.append(("Episode", s.end)) }
        }
        client?.setChapters(marks)
    }

    private func updateActiveSegment() {
        guard Date() >= skipSuppressedUntil, defaults.bool(forKey: SettingsKey.skipEnabled) else { return }
        let seg = segments.first { position >= $0.start && position < $0.end - 0.5 }
        if seg != activeSegment { activeSegment = seg }
        guard let seg, !autoSkipped.contains(seg.id) else { return }
        let key: String
        switch seg.kind {
        case .intro: key = SettingsKey.skipAutoIntro
        case .outro: key = SettingsKey.skipAutoOutro
        case .recap: key = SettingsKey.skipAutoRecap
        case .preview: key = SettingsKey.skipAutoPreview
        }
        if defaults.bool(forKey: key) {
            autoSkipped.insert(seg.id)
            seek(to: seg.end)
            showToast("Skipped \(seg.kind.chapterTitle.lowercased())")
        }
    }

    // MARK: PiP frame feed (keeps the PiP layer showing the current picture)

    private func startPiPFeed() {
        guard defaults.bool(forKey: SettingsKey.pipEnabled), PiPManager.isSupported else { return }
        switch renderer {
        case .gl:
            glView?.setPiPFeed(pip.makeSink())
        case .metal:
            // A readback of the full frame is not free; refresh the PiP
            // layer rarely (it only needs *some* current-ish picture to be
            // allowed to start) and whenever playback settles.
            snapshotTimer?.invalidate()
            let t = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.takeSnapshot() }
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            snapshotTimer = t
        }
    }

    private func stopPiPFeed() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        glView?.setPiPFeed(nil)
    }

    /// Saves the current frame as the Continue Watching thumbnail.
    private func captureThumbnail() {
        #if targetEnvironment(simulator)
        return                        // the simulator's Metal driver aborts on readback
        #endif
        guard fileLoaded, mode == .main, let c = client, !c.isShutDown else { return }
        var w: Int32 = 0, h: Int32 = 0
        guard let bytes = gp_screenshot_bgra(c.handle, 640, &w, &h) else { return }
        defer { free(bytes) }
        ThumbnailStore.save(bgra: bytes, width: Int(w), height: Int(h), key: item.id)
    }

    private var snapshotWork: DispatchWorkItem?
    private func scheduleSnapshot(after delay: Double) {
        snapshotWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.takeSnapshot() }
        snapshotWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private var lastSnapshot = Date.distantPast
    private func takeSnapshot() {
        #if targetEnvironment(simulator)
        return                        // the simulator's Metal driver aborts on readback
        #endif
        guard renderer == .metal, mode == .main, fileLoaded, !isPiPActive,
              UIApplication.shared.applicationState == .active, let c = client else { return }
        guard Date().timeIntervalSince(lastSnapshot) > 2 else { return }
        lastSnapshot = Date()
        let sink = pip.makeSink()
        snapshotQueue.async { [weak self] in
            guard !c.isShutDown else { return }
            var w: Int32 = 0, h: Int32 = 0
            guard let bytes = gp_screenshot_bgra(c.handle, 640, &w, &h) else { return }
            defer { free(bytes) }
            guard let pb = self?.makePixelBuffer(bytes, Int(w), Int(h)) else { return }
            sink(pb)
        }
    }

    nonisolated private func makePixelBuffer(_ bytes: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pbOut: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOut)
        guard let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h {
            memcpy(dst + y * dstStride, bytes + y * w * 4, w * 4)
        }
        return pb
    }

    // MARK: Renderer switching (PiP)

    /// A/V lab: the same renderer switch PiP does, without PiP.
    func labSwitchRenderer(software: Bool) { software ? switchToSoftware() : switchToMain() }

    /// A/V lab: the "closed PiP from the background, then came back" path,
    /// without PiP or a real background transition.
    func labParkThenReturn() {
        if mode == .sw { sw.detach() }
        mode = .none
        pendingMain = true
        client?.set("vid", "no")
        setPaused(true)
        setPiPLayerOnTop(true)
        scheduleParkedCheck()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.setPaused(false) }
    }

    /// PiP starts: mpv draws on the CPU (vo=libmpv, software render API).
    ///
    /// Metal (1.17.0): only the video output is swapped. mpv then rebuilds the
    /// video chain on the new output and seeks in place (command.c: a `vo`
    /// change → uninit_video_out, reinit_video_chain, queue_seek(relative 0,
    /// exact)); the track stays selected, so the seek is served from the
    /// demuxer cache. Until 1.16.1 the video track was also switched off and
    /// on, and a re-selected track makes the demuxer drop its buffer and read
    /// it again (demux.c, initiate_refresh_seek) — the buffer lost on entering
    /// and leaving PiP (26 Oct report).
    /// OpenGL: freeing the GL render context takes the track down anyway
    /// (vo_libmpv.c: mpv_render_context_free → kill_video_async), and only one
    /// render context can exist, so that path still re-selects the track.
    private func switchToSoftware() {
        guard mode == .main, let c = client else { return }
        defer { traceAV("renderer → PiP") }
        if let vid = c.string("vid"), vid != "no" { vidSaved = vid }
        stopPiPFeed()
        snapshotQueue.sync {}
        switch renderer {
        case .gl:
            glView?.detach()
        case .metal:
            detachMetalView()           // before mpv's Metal thread ends (see detachMetalView)
        }
        do {
            sw.setVideoSize(width: Int(videoSize.width), height: Int(videoSize.height))
            try sw.attach(to: c)
            mode = .sw
        } catch {
            mode = .none
            showToast("PiP renderer failed")
        }
        if renderer == .metal {
            c.set("vo", "libmpv")
            if c.string("vid") == "no" { c.set("vid", vidSaved ?? "auto") }
            dlog("player", "PiP: video output → CPU (track and buffer kept)")
        } else {
            c.set("vid", "no")
            c.set("vid", vidSaved ?? "auto")
        }
    }

    /// PiP ended: back to the main renderer. Metal: the same output swap the
    /// other way (see switchToSoftware); the CPU renderer is freed once mpv
    /// has let go of it — freeing it while its output is still up makes mpv
    /// take the video track down (vo_libmpv.c: kill_video_async → error_on_track).
    private func switchToMain() {
        guard let c = client else { return }
        defer { traceAV("renderer → main (PiP ended)") }
        if renderer == .metal, mode == .sw, sw.isAttached, let vid = c.string("vid"), vid != "no" {
            reattachMetalView()
            videoContainer?.layoutIfNeeded(); metalView?.layoutIfNeeded()
            c.set("vo", "gpu-next")
            mode = .main
            pendingMain = false
            videoOffForBackground = false
            dlog("player", "PiP ended: video output → Metal (track and buffer kept)")
            releaseSoftwareRenderer()
            startPiPFeed()
            return
        }
        c.set("vid", "no")
        if mode == .sw { sw.detach() }
        switch renderer {
        case .metal:
            reattachMetalView()
            c.set("vo", "gpu-next")
        case .gl:
            do { try glView?.attach(to: c) } catch {
                mode = .none
                errorMessage = "Video output failed: \(error.localizedDescription)"
                return
            }
            glView?.setRenderingAllowed(true)
        }
        mode = .main
        pendingMain = false
        videoOffForBackground = false
        c.set("vid", vidSaved ?? "auto")
        startPiPFeed()
    }

    /// Frees the CPU renderer once mpv's output is no longer the libmpv one
    /// (checked every 50 ms, for up to 3 s).
    private func releaseSoftwareRenderer(attempt: Int = 0) {
        let vo = client?.string("current-vo")
        if vo == "libmpv", attempt < 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.releaseSoftwareRenderer(attempt: attempt + 1) }
            return
        }
        guard mode != .sw else { return }       // PiP started again meanwhile: keep it
        if vo == "libmpv" { dlog("player/error", "CPU renderer still in use after 3 s; freeing it anyway") }
        sw.detach()
        dlog("player", "CPU renderer freed (\(attempt * 50) ms after the switch, output \(vo ?? "none"))")
    }

    /// mpv's Metal video thread changes the layer's properties (MoltenVK); Core
    /// Animation commits those changes on that thread when it ends. If the
    /// window has a layout pending at that moment — iOS snapshotting the app
    /// as you swipe home — UIKit runs Auto Layout off the main thread and the
    /// app is killed (SIGTRAP, 24 Oct 20:23:40, PiP starting). So the Metal
    /// view leaves the window before that thread ends, and comes back before
    /// a new one starts; a commit then only reaches this detached view.
    private func detachMetalView() {
        guard let mv = metalView, mv.superview != nil else { return }
        mv.removeFromSuperview()
        dlog("player", "metal view detached")
    }

    private func reattachMetalView() {
        guard let mv = metalView, mv.superview == nil, let container = videoContainer else { return }
        mv.frame = container.bounds
        mv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(mv)
        container.sendSubviewToBack(pip.view)
        mv.setNeedsLayout()
        dlog("player", "metal view attached")
    }

    /// While PiP hands back to the main renderer, keep the (correctly
    /// sized) PiP layer on top so the restore animation never shows a
    /// stretched or black frame.
    private func setPiPLayerOnTop(_ onTop: Bool) {
        guard let container = videoContainer else { return }
        if onTop { container.bringSubviewToFront(pip.view) } else { container.sendSubviewToBack(pip.view) }
    }

    // MARK: App lifecycle

    private func registerLifecycle() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBecomeActive() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.setPaused(true) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.setPaused(true) }
                if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable { self?.updateOutputChannels() }
            }
        })
    }

    /// Leaving the app.
    ///
    /// 1.16.1: when paused, the video track is no longer switched off. mpv
    /// drops the packets of a switched-off track, and switching it back on
    /// discards the whole buffer and reads it again from the network
    /// (demux.c, initiate_refresh_seek: "We need to re-read all packets
    /// anyway, so discard the buffered data") — the lost buffer in the
    /// 26 Oct report, and the picture rebuilt at the old size on return.
    /// Only while audio actually plays on in the background is video off
    /// (iOS doesn't run GPU work for a background app).
    private func didEnterBackground() {
        saveHistory(force: true)
        wentToBackground = true
        guard mode == .main, !isPiPActive, let c = client else { return }
        if renderer == .gl { glView?.setRenderingAllowed(false) }
        if defaults.bool(forKey: SettingsKey.backgroundAudio) {
            if paused {
                parkedPaused = true
                if renderer == .metal { detachMetalView() }
                dlog("player", "background while paused: video and buffer kept")
            } else {
                videoOffForPlayback(c)
            }
        } else {
            setPaused(true)
        }
    }

    private func videoOffForPlayback(_ c: MPVClient) {
        guard let vid = c.string("vid"), vid != "no" else { return }
        vidSaved = vid
        videoOffForBackground = true
        if renderer == .metal { detachMetalView() }
        c.set("vid", "no")
        dlog("player", "background playback: video off")
    }

    /// Playback resumed while the app is in the background (Lock Screen,
    /// headphones) after it was left paused: video off now, as if it had
    /// been playing when the app was left.
    private func resumedInBackground() {
        guard parkedPaused, UIApplication.shared.applicationState == .background, mode == .main, let c = client else { return }
        parkedPaused = false
        videoOffForPlayback(c)
    }

    /// Safety net for the parked state: if the app is on screen with the video
    /// still parked (the active event raced the PiP stop), restore it.
    private func scheduleParkedCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.pendingMain, UIApplication.shared.applicationState != .background else {
                if self?.pendingMain == true { self?.scheduleParkedCheck() }
                return
            }
            dlog("player", "video was parked while on screen; restoring")
            self.switchToMain()
            self.setPiPLayerOnTop(false)
        }
    }

    /// Coming back to the app (from the background, not Control Centre) while
    /// PiP plays: end PiP and carry on in the player. The PiP window animates
    /// back into the player and the picture stays up until the player's own
    /// first frame is drawn, so there is no black flash or jump.
    private func willEnterForeground() {
        guard isPiPActive, defaults.bool(forKey: SettingsKey.pipReturnOnOpen) else { return }
        dlog("player", "app opened while in PiP: back to the player")
        pipRestoring = true
        returnFromPiP = true
        stopPiP()
    }

    /// "Back to the player when you open the app": the stop asked for as the
    /// app comes forward did not always take (1.14.1 log: PiP stopped 9 s
    /// later, by hand). Once the app is active, ask again if PiP is still up,
    /// and once more half a second later; each step goes in the log.
    private var returnFromPiP = false
    private var wentToBackground = false
    private func finishReturnFromPiP(attempt: Int = 1) {
        guard returnFromPiP else { return }
        guard pip.isActive else { returnFromPiP = false; return }
        guard attempt <= 3 else {
            dlog("player/error", "PiP still up after \(attempt - 1) stop requests")
            returnFromPiP = false
            return
        }
        dlog("player", "app active, PiP still up: stop request \(attempt + 1)")
        pipRestoring = true
        stopPiP()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finishReturnFromPiP(attempt: attempt + 1) }
    }

    private func didBecomeActive() {
        let fromBackground = wentToBackground
        wentToBackground = false
        if !returnFromPiP, fromBackground, isPiPActive, defaults.bool(forKey: SettingsKey.pipReturnOnOpen) {
            // The "will enter foreground" event didn't get here first.
            dlog("player", "app active again with PiP up: back to the player")
            returnFromPiP = true
            finishReturnFromPiP(attempt: 0)
        } else if returnFromPiP {
            finishReturnFromPiP()
        }
        if pendingMain { switchToMain(); setPiPLayerOnTop(false); return }
        guard mode == .main else { return }
        if renderer == .gl { glView?.setRenderingAllowed(true) }
        if videoOffForBackground, let c = client {
            videoOffForBackground = false
            parkedPaused = false
            if renderer == .metal {
                reattachMetalView()
                // The drawable must have the screen's current size before mpv
                // builds its video output (26 Oct mpv log: built at the old
                // landscape size 2868×1320 on a portrait screen).
                videoContainer?.layoutIfNeeded(); metalView?.layoutIfNeeded()
            }
            c.set("vid", vidSaved ?? "auto")
        } else if parkedPaused {
            parkedPaused = false
            if renderer == .metal { reattachMetalView(); videoContainer?.layoutIfNeeded(); metalView?.layoutIfNeeded() }
            dlog("player", "back while paused: video view back, \(metalView.map { "\(Int($0.bounds.width))×\(Int($0.bounds.height))" } ?? "-")")
        }
        videoView.setNeedsLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.nudgeRedraw() }
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        if defaults.bool(forKey: SettingsKey.surroundAudio) {
            // Lets iOS spatialise 5.1/7.1 output (AirPods) and pass it to
            // multichannel routes (AirPlay receivers, HDMI).
            try? s.setSupportsMultichannelContent(true)
        }
        try? s.setActive(true)
        updateOutputChannels()
    }

    private func updateOutputChannels() {
        guard defaults.bool(forKey: SettingsKey.surroundAudio) else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setPreferredOutputNumberOfChannels(s.maximumOutputNumberOfChannels)
    }

    // MARK: Now Playing / remote commands

    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    private func setUpRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            cmd.isEnabled = true
            remoteTargets.append((cmd, cmd.addTarget(handler: handler)))
        }
        add(cc.playCommand) { [weak self] _ in self?.setPaused(false); return .success }
        add(cc.pauseCommand) { [weak self] _ in self?.setPaused(true); return .success }
        add(cc.togglePlayPauseCommand) { [weak self] _ in self?.togglePause(); return .success }
        let step = NSNumber(value: defaults.integer(forKey: SettingsKey.seekStep))
        cc.skipForwardCommand.preferredIntervals = [step]
        cc.skipBackwardCommand.preferredIntervals = [step]
        add(cc.skipForwardCommand) { [weak self] e in
            self?.seek(by: (e as? MPSkipIntervalCommandEvent)?.interval ?? 10); return .success
        }
        add(cc.skipBackwardCommand) { [weak self] e in
            self?.seek(by: -((e as? MPSkipIntervalCommandEvent)?.interval ?? 10)); return .success
        }
        add(cc.changePlaybackPositionCommand) { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
        add(cc.nextTrackCommand) { [weak self] _ in self?.playNext(); return .success }
        add(cc.previousTrackCommand) { [weak self] _ in self?.playPrevious(); return .success }
    }

    private func tearDownRemoteCommands() {
        for (cmd, target) in remoteTargets { cmd.removeTarget(target) }
        remoteTargets = []
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : speed,
        ]
        if let sub = item.subtitle { info[MPMediaItemPropertyArtist] = sub }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Helpers

    static func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - mpv events

extension PlayerModel: MPVClientDelegate {
    nonisolated func mpvClient(_ client: MPVClient, didReceive event: MPVEvent) {
        MainActor.assumeIsolated { self.handle(event) }
    }

    private func handle(_ event: MPVEvent) {
        switch event {
        case .property(let name, let value):
            handleProperty(name, value)
        case .fileLoaded:
            onFileLoaded()
        case .endFile(let reason, let error):
            if reason == MPVEndReason.error {
                isLoading = false
                var msg = "Playback failed: \(String(cString: mpv_error_string(error)))"
                if let u = item.resolvedURL, u.isFileURL {
                    let fm = FileManager.default
                    let exists = fm.fileExists(atPath: u.path)
                    let attrs = (try? fm.attributesOfItem(atPath: u.path)) ?? [:]
                    let mediaCount = (try? fm.contentsOfDirectory(atPath: MPVFiles.mediaDir.path))?.count ?? -1
                    dlog("player/error", "local file exists=\(exists) readable=\(fm.isReadableFile(atPath: u.path)) size=\(attrs[.size] ?? 0) protection=\((attrs[.protectionKey] as? FileProtectionType)?.rawValue ?? "?") mediaDirFiles=\(mediaCount) path=\(u.path)")
                    if !exists {
                        msg += "\n\nThis file is no longer in the library (\(u.lastPathComponent)). Add it again from Files."
                    } else if !fm.isReadableFile(atPath: u.path) {
                        msg += "\n\niOS didn't grant access to this file (\(u.lastPathComponent)). Open it again from Files, or copy it into Folio → Media."
                    }
                }
                dlog("player/error", msg)
                errorMessage = msg
            }
        case .playbackRestart:
            buffering = false
            if awaitingFirstFrameAfterPiP {
                awaitingFirstFrameAfterPiP = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.setPiPLayerOnTop(false) }
            }
            if renderer == .metal { scheduleSnapshot(after: 0.8) }
        case .videoReconfig:
            break
        case .clientMessage(let args):
            if args.first == "glassplayer-toast", args.count > 1 { showToast(args[1]) }
        case .log, .seek, .shutdown:
            break
        }
    }

    private func handleProperty(_ name: String, _ value: MPVValue) {
        switch name {
        case "time-pos":
            let p = value.double ?? 0
            position = p
            // Publish at most ~4x per second (skips SwiftUI work per frame).
            if abs(p - clock.position) >= 0.25 || p < clock.position { clock.position = p }
            updateActiveSegment()
            updateUpNext()
            maybePrepareNext()
            if Date().timeIntervalSince(lastPiPSync) > 1 {
                lastPiPSync = Date()
                pip.updatePlayback(position: p, rate: paused ? 0 : speed)
            }
            saveHistory()
        case "duration":
            clock.duration = value.double ?? 0
            pipState.duration = clock.duration
            pip.invalidate()
            maybeRequestSegments()
            updateNowPlaying()
        case "pause":
            paused = value.bool ?? false
            pipState.paused = paused
            pip.updatePlayback(position: position, rate: paused ? 0 : speed)
            pip.invalidate()
            updateNowPlaying()
            UIApplication.shared.isIdleTimerDisabled = !paused
            if paused { saveHistory(force: true); scheduleSnapshot(after: 0.3) } else { resumedInBackground() }
        case "paused-for-cache":
            buffering = value.bool ?? false
        case "seeking":
            if value.bool == true { buffering = true }
        case "eof-reached":
            if value.bool == true { handleEOF() }
        case "speed":
            speed = value.double ?? 1
            updateNowPlaying()
        case "media-title":
            if let t = value.string, !t.isEmpty, item.title.isEmpty { mediaTitle = t }
        case "track-list/count", "aid", "vid":
            refreshTracks()
        case "chapter-list/count":
            refreshChapters()
        case "chapter":
            currentChapter = Int(value.int ?? -1)
        case "sid":
            sid = value.string ?? "no"
            refreshTracks()
        case "sub-delay":
            subDelay = value.double ?? 0
        case "audio-delay":
            audioDelay = value.double ?? 0
        case "dwidth":
            pendingW = Int(value.int ?? 0); applyVideoSize()
        case "dheight":
            pendingH = Int(value.int ?? 0); applyVideoSize()
        case "hwdec-current":
            hwdecCurrent = value.string ?? ""
            dlog("player", "decoder: \(hwdecCurrent.isEmpty || hwdecCurrent == "no" ? "software" : hwdecCurrent)")
            EnergyMonitor.shared.note = "renderer=\(renderer) picture=\(PictureMode.current.rawValue) decoder=\(hwdecCurrent.isEmpty ? "sw" : hwdecCurrent)"
            // A minute into playback: one line that says what this file costs
            // (once per file, not once per decoder change).
            if energyNoteFor != item.id {
                energyNoteFor = item.id
                let id = item.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    if let self, !self.closed, self.item.id == id { EnergyMonitor.shared.sample(reason: "1 min into playback\(self.isPiPActive ? " (PiP)" : "")") }
                }
            }
        case "video-params/gamma":
            updateVideoFormat(gamma: value.string ?? "")
        case "audio-out-params/channels":
            audioOut = value.string ?? ""
        case "demuxer-cache-duration":
            let v = value.double ?? 0
            if abs(v - clock.cacheAhead) > 1 { clock.cacheAhead = v }
        case "panscan":
            zoomToFill = (value.double ?? 0) > 0.5
        default:
            break
        }
    }

    private func applyVideoSize() {
        let size = CGSize(width: pendingW, height: pendingH)
        if size != videoSize { videoSize = size }
        if pendingW > 0, pendingH > 0 {
            glView?.setVideoAspect(Double(pendingW) / Double(pendingH))
            sw.setVideoSize(width: pendingW, height: pendingH)
        }
    }

    private func handleEOF() {
        saveHistory(force: true)
        if playbackMode == "playlist", defaults.bool(forKey: SettingsKey.autoplayNext), hasNext {
            playNext()
        } else {
            ended = true
        }
    }
}

// MARK: - PiP

/// Runs `body` synchronously when already on the main thread (needed for
/// renderer switching during the PiP transition), otherwise hops to main.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.async { body() }
    }
}

extension PlayerModel: PiPManagerDelegate {
    nonisolated func pipWillStart() {
        onMain { [weak self] in
            guard let self else { return }
            self.isPiPActive = true
            self.pipRestoring = false
            self.switchToSoftware()
        }
    }

    nonisolated func pipDidStart() {}

    nonisolated func pipWillStop() {
        onMain { [weak self] in self?.setPiPLayerOnTop(true) }
    }

    nonisolated func pipDidStop() {
        onMain { [weak self] in
            guard let self else { return }
            self.isPiPActive = false
            self.returnFromPiP = false
            let state = UIApplication.shared.applicationState
            dlog("player", "pip stopped (app \(state == .active ? "active" : state == .inactive ? "inactive" : "background"), restoring=\(self.pipRestoring))")
            // Only a truly backgrounded app parks the video. `.inactive` is the
            // moment the user is already coming back (switcher, PiP's ✕ while
            // returning): parking there left the picture off with audio on,
            // because the "became active" event that un-parks had already fired.
            if state == .background && !self.pipRestoring {
                if self.mode == .sw { self.sw.detach() }
                self.mode = .none
                self.pendingMain = true
                self.client?.set("vid", "no")
                self.setPaused(true)
                self.scheduleParkedCheck()
            } else {
                self.awaitingFirstFrameAfterPiP = true
                self.switchToMain()
                // Fallback in case no playback-restart arrives (paused video).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.awaitingFirstFrameAfterPiP = false
                    self?.setPiPLayerOnTop(false)
                }
            }
            self.pipRestoring = false
        }
    }

    nonisolated func pipFailed(_ error: Error) {
        let message = error.localizedDescription
        onMain { [weak self] in
            guard let self else { return }
            self.isPiPActive = false
            self.showToast("PiP failed: \(message)")
            self.setPiPLayerOnTop(false)
            if self.mode == .sw { self.switchToMain() }
        }
    }

    nonisolated func pipRestoreUI(_ completion: @escaping (Bool) -> Void) {
        onMain { [weak self] in self?.pipRestoring = true }
        completion(true)
    }

    nonisolated func pipSetPlaying(_ playing: Bool) {
        onMain { [weak self] in self?.setPaused(!playing) }
    }

    nonisolated func pipSkip(by seconds: Double) {
        onMain { [weak self] in self?.seek(by: seconds) }
    }

    nonisolated var pipIsPaused: Bool { pipState.paused }
    nonisolated var pipDuration: Double { pipState.duration }
}

/// Thread-safe snapshot read by AVKit's playback delegate callbacks.
final class PiPStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _duration: Double = 0
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }
    var duration: Double {
        get { lock.lock(); defer { lock.unlock() }; return _duration }
        set { lock.lock(); _duration = newValue; lock.unlock() }
    }
}
