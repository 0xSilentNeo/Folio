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
    var item: MediaItem { queue[queueIndex] }
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
    private var pendingMain = false
    private var pipRestoring = false
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
        guard let c = MPVClient() else {
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
    }

    func close() {
        guard !closed else { return }
        closed = true
        saveHistory(force: true)
        HistoryStore.shared.flush()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        tearDownRemoteCommands()
        stopPiPFeed()
        snapshotQueue.sync {}
        pip.tearDown()
        if mode == .sw { sw.detach() }
        glView?.detach()
        mode = .none
        let scoped = scopedURL
        scopedURL = nil
        client?.delegate = nil
        client?.shutdown {
            scoped?.stopAccessingSecurityScopedResource()
        }
        client = nil
        UIApplication.shared.isIdleTimerDisabled = false
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
        c.setOption("ao", "avfoundation,audiounit")
        c.setOption("audio-channels", defaults.bool(forKey: SettingsKey.surroundAudio) ? "auto" : "stereo")
        c.setOption("sub-auto", "fuzzy")
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
        let shaders = MPVFiles.activeShaderPaths
        if !shaders.isEmpty { c.setOption("glsl-shaders", shaders.joined(separator: ":")) }
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
        saveHistory(force: true)
        ended = false
        errorMessage = nil
        segments = []
        activeSegment = nil
        autoSkipped = []
        segmentsRequested = false
        fileLoaded = false
        isLoading = true
        position = 0
        clock.position = 0
        clock.duration = item.durationHint ?? 0
        tracks = []
        chapters = []
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

        var opts: [String] = []
        if defaults.bool(forKey: SettingsKey.resumePlayback),
           let entry = HistoryStore.shared.entry(for: item.id), entry.canResume {
            opts.append("start=\(Int(entry.position))")
            showToast("Resuming from \(Self.format(entry.position))")
        }
        c.command(["loadfile", item.mpvPath, "replace", "-1", opts.joined(separator: ",")])
        updateNowPlaying()
    }

    func playNext() {
        guard hasNext else { return }
        queueIndex += 1
        load(item)
    }

    func playPrevious() {
        if position > 10 || !hasPrevious { seek(to: 0); return }
        queueIndex -= 1
        load(item)
    }

    private func onFileLoaded() {
        guard let c = client else { return }
        fileLoaded = true
        isLoading = false
        refreshTracks()
        refreshChapters()
        for sub in item.subtitles {
            c.commandAsync(["sub-add", sub.url, "auto", sub.title ?? sub.lang ?? "Addon", sub.lang ?? ""])
        }
        maybeRequestSegments()
        updateNowPlaying()
    }

    // MARK: Tracks / chapters

    func refreshTracks() {
        guard let c = client, let n = c.int("track-list/count") else { return }
        var list: [MediaTrack] = []
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
        tracks = list
        updateVideoFormat()
    }

    func refreshChapters() {
        guard let c = client, let n = c.int("chapter-list/count") else { chapters = []; return }
        var list: [MediaChapter] = []
        for i in 0..<Int(n) {
            let t = c.double("chapter-list/\(i)/time") ?? 0
            let title = c.string("chapter-list/\(i)/title") ?? "Chapter \(i + 1)"
            list.append(MediaChapter(id: i, title: title, time: t))
        }
        chapters = list
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

    private func updateVideoFormat() {
        let gamma = client?.string("video-params/gamma") ?? ""
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

    func seek(by seconds: Double) {
        client?.command(["seek", String(seconds), "relative+exact"])
    }

    func seek(to seconds: Double, exact: Bool = true) {
        client?.command(["seek", String(max(0, seconds)), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    /// Live preview while scrubbing: fast keyframe seeks, throttled.
    private var lastScrubSeek = Date.distantPast
    func scrub(to seconds: Double) {
        clock.position = seconds
        guard Date().timeIntervalSince(lastScrubSeek) > 0.12 else { return }
        lastScrubSeek = Date()
        client?.command(["seek", String(max(0, seconds)), "absolute+keyframes"])
    }

    func setSpeed(_ s: Double) { client?.set("speed", s) }

    func beginHoldSpeed() {
        guard holdEnabled, !paused, !holdSpeedActive else { return }
        speedBeforeHold = speed
        holdSpeedActive = true
        setSpeed(holdSpeed)
    }

    func endHoldSpeed() {
        guard holdSpeedActive else { return }
        holdSpeedActive = false
        setSpeed(speedBeforeHold)
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
        seek(to: segment.end)
        autoSkipped.insert(segment.id)
        activeSegment = nil
    }

    func jump(to chapter: MediaChapter) { seek(to: chapter.time) }

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
        client?.set("glsl-shaders", MPVFiles.activeShaderPaths.joined(separator: ":"))
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
        guard defaults.bool(forKey: SettingsKey.skipEnabled) else { return }

        if defaults.bool(forKey: SettingsKey.skipUseChapters) {
            let s = SkipService.segments(fromChapters: chapters.map { ($0.title, $0.time) }, duration: duration)
            if !s.isEmpty { segments = s; return }
        }

        var hint = item.anime ?? AnimeHint()
        if hint.title == nil || hint.episode == nil {
            let name = item.resolvedURL?.lastPathComponent ?? item.title
            let parsed = TitleParser.parse(TitleParser.isMedia(name) ? name : item.title)
            if hint.title == nil { hint.title = parsed.title }
            if hint.episode == nil { hint.episode = parsed.episode }
        }
        guard hint.episode != nil else { return }
        let key = item.id
        let dur = duration
        let len = defaults.double(forKey: SettingsKey.skipOATLength)
        Task { [weak self] in
            let found = await SkipService.shared.lookup(hint: hint, duration: dur, oatLength: len > 0 ? len : 90)
            await MainActor.run {
                guard let self, self.item.id == key, !found.isEmpty else { return }
                self.segments = found
                if self.defaults.bool(forKey: SettingsKey.skipInjectChapters), self.chapters.isEmpty {
                    self.injectChapters(found)
                }
            }
        }
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
            snapshotTimer?.invalidate()
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.takeSnapshot() }
            }
            RunLoop.main.add(t, forMode: .common)
            snapshotTimer = t
        }
    }

    private func stopPiPFeed() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        glView?.setPiPFeed(nil)
    }

    private func takeSnapshot() {
        guard renderer == .metal, mode == .main, fileLoaded, !isPiPActive,
              UIApplication.shared.applicationState == .active, let c = client else { return }
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

    private func switchToSoftware() {
        guard mode == .main, let c = client else { return }
        if let vid = c.string("vid"), vid != "no" { vidSaved = vid }
        stopPiPFeed()
        snapshotQueue.sync {}
        switch renderer {
        case .gl:
            glView?.detach()
        case .metal:
            c.set("vid", "no")          // tear down the Metal VO first
        }
        do {
            sw.setVideoSize(width: Int(videoSize.width), height: Int(videoSize.height))
            try sw.attach(to: c)
            mode = .sw
        } catch {
            mode = .none
            showToast("PiP renderer failed")
        }
        if renderer == .metal { c.set("vo", "libmpv") }
        c.set("vid", "no")
        c.set("vid", vidSaved ?? "auto")
    }

    private func switchToMain() {
        guard let c = client else { return }
        c.set("vid", "no")
        if mode == .sw { sw.detach() }
        switch renderer {
        case .metal:
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

    private func didEnterBackground() {
        saveHistory(force: true)
        guard mode == .main, !isPiPActive, let c = client else { return }
        if renderer == .gl { glView?.setRenderingAllowed(false) }
        if defaults.bool(forKey: SettingsKey.backgroundAudio) {
            if let vid = c.string("vid"), vid != "no" {
                vidSaved = vid
                videoOffForBackground = true
                c.set("vid", "no")
            }
        } else {
            setPaused(true)
        }
    }

    private func didBecomeActive() {
        if pendingMain { switchToMain(); return }
        guard mode == .main else { return }
        if renderer == .gl { glView?.setRenderingAllowed(true) }
        if videoOffForBackground, let c = client {
            videoOffForBackground = false
            c.set("vid", vidSaved ?? "auto")
        }
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
                errorMessage = "Playback failed: \(String(cString: mpv_error_string(error)))"
            }
        case .playbackRestart:
            buffering = false
            if awaitingFirstFrameAfterPiP {
                awaitingFirstFrameAfterPiP = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.setPiPLayerOnTop(false) }
            }
            if renderer == .metal { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.takeSnapshot() } }
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
            if paused { saveHistory(force: true); takeSnapshot() }
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
        case "dwidth", "dheight":
            let w = client?.int("dwidth") ?? 0, h = client?.int("dheight") ?? 0
            let size = CGSize(width: Int(w), height: Int(h))
            if size != videoSize { videoSize = size }
            if w > 0, h > 0 {
                glView?.setVideoAspect(Double(w) / Double(h))
                sw.setVideoSize(width: Int(w), height: Int(h))
            }
        case "hwdec-current":
            hwdecCurrent = value.string ?? ""
        case "video-params/gamma":
            updateVideoFormat()
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

    private func handleEOF() {
        saveHistory(force: true)
        if defaults.bool(forKey: SettingsKey.autoplayNext), hasNext {
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
            if UIApplication.shared.applicationState == .background {
                if self.mode == .sw { self.sw.detach() }
                self.mode = .none
                self.pendingMain = true
                self.client?.set("vid", "no")
                if !self.pipRestoring { self.setPaused(true) }
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
