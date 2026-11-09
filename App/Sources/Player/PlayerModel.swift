import Foundation
import TipKit
import UIKit
import AVFoundation
import MediaPlayer
import Combine
import CoreVideo
import os

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
    /// mpv's track flags (subtitles): forced lines only; for the hearing impaired.
    var forced = false
    var hearingImpaired = false

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
            if forced { parts.append("Forced") }
            if hearingImpaired { parts.append("SDH") }
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
    /// Where a scrub on the bar or the video is (1.24.1; on PlayerUIState
    /// until then): set on every touch move, so it lives with what only the
    /// time bar watches, not with the whole player's chrome.
    @Published var scrubTime: Double?
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
    /// Where the sound goes (Media info's Output, 1.27.0).
    @Published var audioRoute: AudioRoute?
    @Published var ended = false
    @Published var errorMessage: String?
    /// Why a file on a server didn't play, from the server's own answer
    /// (1.23.0): a file Real-Debrid removed, a refused login, a server down.
    @Published var problem: ServerProblem?
    /// The server is being asked why (the card says so meanwhile).
    @Published var checkingProblem = false
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

    /// Grows only at its end: the show's later episodes from other folders
    /// on the same server (findMoreEpisodes).
    @Published private(set) var queue: [MediaItem]
    var item: MediaItem { resolvedItems[queueIndex] ?? queue[queueIndex] }
    /// Play Season: episodes whose stream was found when their turn came.
    private var resolvedItems: [Int: MediaItem] = [:]
    var hasNext: Bool { queueIndex + 1 < queue.count }
    var hasPrevious: Bool { queueIndex > 0 }

    // MARK: Rendering
    /// `.metal`: mpv's gpu-next on a Metal layer; PiP swaps mpv's video
    /// output to a CPU renderer and back. `.gl`: mpv's OpenGL renderer
    /// draws every frame into PiP's own sample-buffer layer,
    /// which is also the picture in the player (SampleBufferRenderer); PiP
    /// changes nothing but the size frames are drawn at.
    enum Renderer { case metal, gl }
    let renderer: Renderer
    let videoView: UIView
    /// Metal on its own CAMetalLayer (engines before 3): PiP swaps mpv's
    /// output, the background takes it down.
    private let metalView: MetalVideoView?
    private let glRenderer: SampleBufferRenderer?
    /// Metal drawing into the video layer (1.28.0, engine 3).
    private let metalFrames: MetalFrameRenderer?
    /// The renderer whose frames go into the video layer PiP uses: OpenGL,
    /// or Metal on engine 3. Nil only for Metal on its own layer.
    private var frames: FrameRenderer? { glRenderer ?? metalFrames }
    /// Frames go into the video layer (OpenGL, or Metal on engine 3): PiP,
    /// the background, Fill and subtitles work the same for both.
    var onLayer: Bool { frames != nil }
    /// Metal on its own layer (classic).
    private var ownLayerMetal: Bool { renderer == .metal && metalFrames == nil }
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
    /// PiP trace (PiPTrace, off unless switched on in Diagnostics).
    private var traceSampler: PiPTrace.Sampler?
    private let traceHitches = PiPTrace.HitchWatch()
    private func traceTransition(_ what: String, seconds: Double = 4) {
        guard PiPTrace.on else { return }
        PiPTrace.mark(what)
        if let c = client {
            let base = CACurrentMediaTime()
            let s = PiPTrace.Sampler(client: c, label: what, base: base)
            traceSampler = s
            s.start(seconds: seconds) { [weak self] text in
                // With the OpenGL renderer the layer is the picture: its frames too.
                PiPTrace.event(text + (self?.onLayer == true ? self?.pip.frameGaps(since: base) ?? "" : ""))
                if self?.traceSampler === s { self?.traceSampler = nil }
            }
        }
        traceHitches.start(seconds: seconds)
    }

    private var snapshotTimer: Timer?
    private let snapshotQueue = DispatchQueue(label: "folio.snapshot", qos: .utility)
    private var snapshotPool: CVPixelBufferPool?
    private var snapshotPoolSize = (0, 0)

    private var scopedURL: URL?
    private var lastHistorySave = Date.distantPast
    private var lastPiPSync = Date.distantPast
    private var autoSkipped: Set<String> = []
    private var segmentsRequested = false
    /// The loaded file's chapter list has been read (refreshChapters). Skip
    /// segments wait for it as well as for the length: until 1.20.3 they were
    /// decided as soon as the length was known, often before the chapters
    /// came, and never again, so a file's own chapters lost to the online
    /// lookup (review, 2 Nov).
    private var chaptersRead = false
    private var fileLoaded = false
    private var observers: [NSObjectProtocol] = []
    private var toastWork: DispatchWorkItem?
    private var speedBeforeHold: Double = 1
    private var started = false
    private var closed = false
    private var loadStarted = Date()
    private var pendingW = 0, pendingH = 0
    /// Closes the player's screen (PlayerViewController.closePlayer, which
    /// calls close()): for a close the screen didn't ask for, such as mpv
    /// quitting on its own. Not called from close() itself: that made every
    /// close run twice (review of the 1.20.2 change, 2 Nov).
    var closeScreen: (() -> Void)?

    private let defaults = UserDefaults.standard

    init?(queue: [MediaItem], startIndex: Int = 0, fromStart: Bool = false) {
        guard !queue.isEmpty else { return nil }
        startFirstAtZero = fromStart
        self.queue = queue
        self.queueIndex = min(max(0, startIndex), queue.count - 1)
        if UserDefaults.standard.string(forKey: SettingsKey.renderer) == "gl", let gl = SampleBufferRenderer.make(output: pip.makeSink()) {
            renderer = .gl
            glRenderer = gl
            metalFrames = nil
            metalView = nil
            videoView = pip.view
        } else if !CommandLine.arguments.contains("-metalOwnLayer"), let mf = MetalFrameRenderer(output: pip.makeSink()) {
            // 1.28.0: Metal into the video layer, as OpenGL (engine 3).
            renderer = .metal
            metalFrames = mf
            glRenderer = nil
            metalView = nil
            videoView = pip.view
        } else {
            let mv = MetalVideoView()
            renderer = .metal
            metalView = mv
            glRenderer = nil
            metalFrames = nil
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
            try c.initialize()
        } catch {
            errorMessage = "mpv failed to start: \(error.localizedDescription). Check mpv.conf for invalid options."
            // Freed now: its core and thread were left running until the app quit.
            c.shutdown()
            return
        }
        c.delegate = self
        client = c
        observe(c)
        probeAudioFilters(c)

        if let glRenderer {
            do { try glRenderer.attach(to: c) } catch {
                errorMessage = "Video output failed: \(error.localizedDescription)"
            }
        }
        if let frames {
            pip.view.onLayout = { [weak frames, weak self] pixels in frames?.setViewSize(pixels); self?.refitAnime4K(); self?.applySubtitleFraming() }
            metalFrames?.onResize = { [weak self] in self?.nudgeRedraw() }
            let b = pip.view.bounds.size, n = pip.view.layouts, name = renderer == .gl ? "OpenGL" : "Metal (video layer)"
            Task { @MainActor in PiPTrace.event("\(name) renderer listening for the view's size: \(Int(b.width))×\(Int(b.height)) pt after \(n) layout(s)") }
            // start() runs in viewDidAppear, after the view's layout: its size
            // now, not at the next layout (which may not come until the phone
            // turns).
            pip.view.reportSize()
        }
        metalView?.onResize = { [weak self] in self?.nudgeRedraw(); self?.refitAnime4K() }
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refitAnime4K(); self?.applyHDRDecode() }
        })
        mode = .main

        if defaults.bool(forKey: SettingsKey.pipEnabled), PiPManager.isSupported {
            pip.delegate = self
            pip.onPossibleChanged = { [weak self] in self?.isPiPPossible = $0 }
            pip.onRenderSize = { [weak self] size in DispatchQueue.main.async { self?.pipWindowSized(size) } }
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

    /// One line per player session: a session that closes without it is
    /// still held somewhere (with its video layers and PiP layer).
    deinit { dlog("player", "player model freed") }

    /// The screen's brightness before a swipe in the player changed it: put
    /// back when the player closes. It stayed at the player's level all
    /// over the app (review, 2 Nov).
    var brightnessBefore: CGFloat?

    /// Retry reloads the file in the running mpv; with none, it can't.
    var canRetry: Bool { client.map { !$0.isShutDown } ?? false }

    func close() {
        guard !closed else { return }
        closed = true
        if let b = brightnessBefore {
            (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen ?? UIScreen.main).brightness = b
            brightnessBefore = nil
        }
        screener?.cancel()
        problemCheck?.cancel(); problemCheck = nil
        nowPlayingArtTask?.cancel(); nowPlayingArtTask = nil
        dlog("player", "close at \(Self.format(position))")
        saveHistory(force: true)
        HistoryStore.shared.flush()
        WatchLog.shared.flush()
        ShowMemoryStore.shared.flush()
        HandoffActivity.stopPlaying()
        closeSubtitleSearch()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        tearDownRemoteCommands()
        stopPiPFeed()
        snapshotQueue.sync {}
        captureThumbnail()
        // The OpenGL renderer first: it enqueues into PiP's layer from its own
        // queue, and the layer is flushed below (independent review, 1.20.0).
        frames?.detach()
        pip.tearDown()
        if mode == .sw { sw.detach() }
        mode = .none
        let scoped = scopedURL
        scopedURL = nil
        client?.delegate = nil
        if ownLayerMetal, let c = client {
            // mpv's Metal thread would end during the quit below, on mpv's own
            // time, while the player closes here; end it now, with the main
            // thread waiting (no video track and no forced window: mpv closes
            // its video output — player/loadfile.c, handle_force_window).
            settleBeforeMetalThreadEnds()
            c.set("vid", "no")
        }
        // The Metal frames' hook stays until mpv is gone: its video output
        // thread may still call it while it quits.
        let metalFrames = self.metalFrames
        if client == nil { metalFrames?.engineDone() }
        client?.shutdown {
            scoped?.stopAccessingSecurityScopedResource()
            metalFrames?.engineDone()
        }
        client = nil
        UIApplication.shared.isIdleTimerDisabled = false
        EnergyMonitor.shared.sample(reason: "player closing")
        EnergyMonitor.shared.playing = false
        EnergyMonitor.shared.note = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func applyOptions(_ c: MPVClient) {
        switch renderer {
        case .metal:
            c.setOption("vo", "gpu-next")
            c.setOption("gpu-api", "vulkan")
            c.setOption("gpu-context", "moltenvk")
            if let mf = metalFrames {
                // 1.28.0: frames into Folio's buffers (the video layer); the
                // layer given as the window is never shown. HDR is chosen per
                // file (updateLayerHDR), not hinted to a swapchain.
                c.setOption("wid", int64: mf.wid)
                c.setOption("folio-target", mf.targetAddress)
            } else {
                c.setOption("wid", int64: metalView!.wid)
                let edr = UIScreen.main.potentialEDRHeadroom > 1.0
                if defaults.bool(forKey: SettingsKey.hdrOutput) && edr {
                    // HDR / Dolby Vision passthrough to the EDR display.
                    c.setOption("target-colorspace-hint", "yes")
                }
            }
        case .gl:
            c.setOption("vo", "libmpv")
            c.setOption("gpu-api", "opengl")
            c.setOption("opengl-es", "yes")
            // The hardware decoder hands OpenGL 8-bit frames: OpenGL ES on iOS
            // can't sample its 10-bit ones (mpv's iOS interop answers "Format
            // unsupported" and draws nothing), so 10-bit files, most anime
            // releases, played black (4 Nov report). HDR files switch to
            // 10-bit copy decoding instead (updateGLHDR).
            c.setOption("hwdec-image-format", "nv12")
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
        // A saved Loop mode: until 1.20.3 it was set only when changed, so a
        // new session ignored it (review, 2 Nov).
        c.setOption("loop-file", playbackMode == "loop" ? "inf" : "no")
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
        // Folio's sound doesn't mix with other apps' (1.22.7). mpv's AudioUnit
        // output sets the audio session again when it starts, and without
        // this asks it to mix with others (ao_audiounit.m: no
        // AO_INIT_EXCLUSIVE → AVAudioSessionCategoryOptionMixWithOthers).
        // iOS never makes an app that mixes the Now Playing app, so Control
        // Center and the Lock Screen said "Not Playing" (4 Nov report): the
        // session read "options 1" once a file with sound played, in the
        // simulator, whatever Folio had set before. Music and TV don't mix
        // either: another app's sound pauses when a video starts.
        c.setOption("audio-exclusive", "yes")
        c.setOption("audio-channels", defaults.bool(forKey: SettingsKey.surroundAudio) ? "auto" : "stereo")
        c.setOption("sub-auto", "fuzzy")
        if defaults.string(forKey: SettingsKey.subtitlesDefault) == "off" { c.setOption("sid", "no") }
        c.setOption("audio-normalize-downmix", defaults.bool(forKey: SettingsKey.downmixNormalize) ? "yes" : "no")
        if defaults.bool(forKey: SettingsKey.lfeInDownmix) { c.setOption("audio-swresample-o", "lfe_mix_level=1") }
        c.setOption("embeddedfonts", "yes")
        c.setOption("sub-fonts-dir", MPVFiles.fontsDir.path)
        if let s = defaults.string(forKey: SettingsKey.subLangs), !s.isEmpty { c.setOption("slang", s) }
        if let s = defaults.string(forKey: SettingsKey.audioLangs), !s.isEmpty { c.setOption("alang", s) }
        // The subtitle style preset over your size, position, bold and box
        // (1.20.3, 2 Nov). Set before mpv reads mpv.conf, which still wins.
        for (k, v) in subtitleOptions() { c.setOption(k, v) }
        // Night mode's Dolby range compression (AudioFilters).
        if nightMode { c.setOption("ad-lavc-ac3drc", AudioFilters.ac3drc(night: true)) }
        c.setOption("speed", String(defaults.double(forKey: SettingsKey.defaultSpeed)))
        // One by one: as a ":"-separated list, a shader whose name has a
        // ":" in it broke the whole list (review, 2 Nov).
        for path in Anime4K.currentShaders() { c.setOption("glsl-shaders-append", path) }
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
            applyHDRDecode()
        }
    }
    /// Chosen here, it's also the mode for titles with none remembered (as
    /// before 1.20.3); applied from a show's memory, it's that show's only.
    @Published var anime4kMode: Anime4KMode = Anime4K.mode {
        didSet {
            if !applyingMemory {
                Anime4K.mode = anime4kMode
                remember { $0.anime4k = self.anime4kMode.rawValue }
            }
            applyShaderList()
        }
    }
    /// Night mode and dialogue boost (AudioFilters): Settings → Audio &
    /// Subtitles gives what a player starts with; the player's menu changes
    /// them for this player session.
    @Published var nightMode: Bool = UserDefaults.standard.bool(forKey: SettingsKey.nightMode) {
        didSet {
            guard nightMode != oldValue else { return }
            client?.set("ad-lavc-ac3drc", AudioFilters.ac3drc(night: nightMode))
            updateAudioFilters(because: nightMode ? "night mode on" : "night mode off")
        }
    }
    @Published var dialogueBoost: Bool = UserDefaults.standard.bool(forKey: SettingsKey.dialogueBoost) {
        didSet {
            guard dialogueBoost != oldValue else { return }
            updateAudioFilters(because: dialogueBoost ? "dialogue boost on" : "dialogue boost off")
        }
    }
    /// What the audio filters do now, for the menu ("Compressor", "Centre channel louder").
    @Published private(set) var audioFilterPlan: AudioFilters.Plan?
    @Published var subtitleStyle: SubtitleStyle = SubtitleStyle.current {
        didSet {
            SubtitleStyle.current = subtitleStyle
            applySubtitleStyle()
        }
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

    /// The player's own Anime4K mode (a show's remembered one may differ
    /// from the saved default), then your shaders.
    private func applyShaderList(force: Bool = true) {
        guard let c = client else { return }
        let restoreOnly = anime4kRestoreOnly
        let list = Anime4K.paths(mode: anime4kMode, quality: anime4kQuality, restoreOnly: restoreOnly) + MPVFiles.activeShaderPaths
        // A change of size or heat that changes nothing: no reload.
        guard force || list != appliedShaders else { return }
        if anime4kMode != .off, appliedShaders != list {
            dlog("player", "Anime4K \(anime4kMode.rawValue)/\(anime4kQuality.rawValue): \(restoreOnly ? "restore stages only" : "full chain")"
                 + " (on screen at \(anime4kScale.map { String(format: "%.2f×", $0) } ?? "?"), thermal \(ProcessInfo.processInfo.thermalState.rawValue))")
        }
        appliedShaders = list
        if !list.contains(where: { $0.contains(":") }) {
            c.set("glsl-shaders", list.joined(separator: ":"))      // one change, one shader reload
        } else {
            c.command(["change-list", "glsl-shaders", "clr", ""])
            for p in list { c.command(["change-list", "glsl-shaders", "append", p]) }
        }
    }

    // MARK: Anime4K fitted to the screen (1.23.1)

    private var appliedShaders: [String] = []

    /// How much bigger than its own size the video is shown, fitted in the
    /// player view; nil until both are known.
    private var anime4kScale: CGFloat? {
        let v = videoSize
        let px = videoView.bounds.size
        let scale = videoView.window?.screen.scale ?? UIScreen.main.scale
        guard v.width > 0, v.height > 0, px.width > 0, px.height > 0 else { return nil }
        return min(px.width * scale / v.width, px.height * scale / v.height)
    }

    /// The restore stages only: the video shown at under 1.5× (Anime4K.fullChainScale),
    /// or the phone hot (Apple: at "serious", "reduce GPU usage").
    private var anime4kRestoreOnly: Bool {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return true }
        guard let s = anime4kScale else { return false }
        return s < Anime4K.fullChainScale
    }

    /// The video's size, the view's size or the heat changed: the chain again
    /// if it's now a different one.
    private func refitAnime4K() {
        guard anime4kMode != .off else { return }
        applyShaderList(force: false)
    }

    private func observe(_ c: MPVClient) {
        c.observe("time-pos", .double)
        c.observe("duration", .double)
        c.observe("pause", .flag)
        c.observe("mute", .flag)
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
        c.observe("audio-params/channels", .string)        // the track's own channels (AudioFilters)
        c.observe("demuxer-cache-duration", .double)
        c.observe("panscan", .double)
        c.observe("secondary-sid", .string)
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
        saveHistory(force: true)            // the file that was playing, under its own entry
        leftFinished = false
        playingItem = item
        ended = false
        errorMessage = nil
        problem = nil
        checkingProblem = false
        problemCheck?.cancel(); problemCheck = nil
        segments = []
        activeSegment = nil
        autoSkipped = []
        introsShown = []
        openTimelineLogged = false
        seekStarted = nil
        waitStarted = nil
        upNext = nil
        upNextDismissed = false
        postCredits = false
        segmentsRequested = false
        chaptersRead = false
        fileLoaded = false
        memoryApplied = false
        pendingSubtitle = nil
        resolveShowKey(for: item)
        dropLayoutFilter(c)
        subtitleSearch?.cancel(); subtitleSearch = nil
        isLoading = true
        position = 0
        clock.position = 0
        clock.duration = item.durationHint ?? 0
        tracks = []
        chapters = []
        loadStarted = Date()
        userMarkers = MarkerStore.shared.markers(for: item.id)
        mediaTitle = item.displayTitle
        lastGamma = ""
        glHDRFailedForFile = false
        hardwareSeenForFile = false
        copyTooSlowForFile = false
        copyWatch?.cancel(); copyWatch = nil

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
        if raisedBuffer, !bufferTrimmed {
            raisedBuffer = false
            c.set("demuxer-max-bytes", "\(max(32, defaults.integer(forKey: SettingsKey.cacheMB)))MiB")
        }
        readToEndCheck?.invalidate(); readToEndCheck = nil
        if let a = appended, a.index == queueIndex, a.path == mpvPath(item) {
            // Prepared near the end of the last episode: next in mpv's playlist,
            // opened (and buffered, once the last file was fully read) already.
            appended = nil
            c.set("pause", false)
            let r = c.command(["playlist-next"])
            dlog("player", "playlist-next → the prepared episode \(item.displayTitle) -> \(r)")
        } else {
            appended = nil
            if resolvesFirst(item), let u = item.resolvedURL {
                // Its download address first: mpv goes back to the address it
                // was given on every reconnect and is redirected again. The
                // last file pauses meanwhile (Next without a prepared episode);
                // the play state is put back once the new file is asked for.
                let wasPaused = paused
                if !wasPaused { c.set("pause", true) }
                let id = item.id
                Task { [weak self] in
                    let final = await LinkWarmer.resolve(u, headers: item.headers, purpose: "this file")
                    guard let self, !self.closed, self.playingItem?.id == id, self.appended == nil else { return }
                    if let final, final != u { self.playLinks[id] = final } else if final == u { LinkWarmer.direct.insert(u.host ?? "") }
                    self.loadFile(item, opts, c)
                    if !wasPaused { c.set("pause", false) }
                }
            } else {
                loadFile(item, opts, c)
            }
        }
        watchLoading(item)
        updateNowPlaying()
    }

    private func loadFile(_ item: MediaItem, _ opts: [String], _ c: MPVClient) {
        let r = c.command(["loadfile", mpvPath(item), "replace", "-1", opts.joined(separator: ",")])
        dlog("player", "loadfile \(mpvPath(item)) source=\(item.source) opts=\(opts) -> \(r)")
    }

    // MARK: Links (1.23.2)

    /// The address mpv opens for an item when it isn't the item's own: a
    /// WebDAV or addon link already followed to the file's download address.
    /// Kept apart from the item, so history, Continue Watching and the queue
    /// keep the item's own address: 1.23.1 wrote a prepared next episode's
    /// download address into the episode, and Real-Debrid episodes were saved
    /// under it (5 Nov log, 18:05: a Continue Watching card played
    /// "syd3-4.download.real-debrid.com/d/…" as a queue of one).
    private var playLinks: [String: URL] = [:]
    private func mpvPath(_ it: MediaItem) -> String { playLinks[it.id]?.absoluteString ?? it.mpvPath }

    /// Worth following to its download address before mpv opens it: mpv
    /// goes back to the address it was given on every reconnect (a resume
    /// position, the index at the end of a file, each seek past its buffer)
    /// and is redirected again each time — 1.9–2.3 s for Real-Debrid's
    /// WebDAV from your phone ("link answered HTTP 206 in 2.2 s (redirected
    /// to syd3-4.download.real-debrid.com)", 4–5 Nov logs). Measured in the
    /// simulator against a lab server that redirects: a resume made three
    /// trips through the redirecting host before the first picture.
    private func resolvesFirst(_ it: MediaItem) -> Bool {
        guard playLinks[it.id] == nil, !CommandLine.arguments.contains("-labNoResolve"),
              let u = it.resolvedURL, ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              !LinkWarmer.direct.contains(u.host ?? "") else { return false }
        switch it.source {
        case .webdav, .addon: return true
        case .url: return it.streamPick != nil
        case .local: return false
        }
    }

    /// Continue Watching's queue, built after the player opened (a WebDAV
    /// folder's listing, 1.2 s on Real-Debrid, held the player back: "built
    /// in 1212 ms", 5 Nov log). Taken while nothing else has been queued
    /// after the file but the show's episodes from other folders.
    func adoptQueue(_ built: [MediaItem], index: Int) {
        let items = built.map { $0.preparedForPlayback() }
        guard items.indices.contains(index), items.count > 1, items[index].id == queue[queueIndex].id,
              queue.count - addedFromElsewhere == 1, appended == nil, preparing == nil, !closed else {
            dlog("player", "continue: folder queue not taken (\(built.count) item(s); the player has \(queue.count), prepared \(appended != nil || preparing != nil))")
            return
        }
        queue = items
        queueIndex = index
        resolvedItems = [:]
        episodeStates = [:]
        subsFetched = []
        lookedForMore = false
        addedFromElsewhere = 0
    }

    // MARK: Why a file didn't play (1.23.0)

    private var problemCheck: Task<Void, Never>?

    /// The server the item is on, by name, and whether it's Real-Debrid.
    private func serverName(of it: MediaItem) -> (name: String, realDebrid: Bool) {
        if case .webdav(let id) = it.source, let s = ServerStore.shared.server(id: id) {
            return (s.name, RealDebrid.isRealDebrid(s))
        }
        let host = it.resolvedURL?.host?.lowercased() ?? ""
        if host.hasSuffix("real-debrid.com") { return ("Real-Debrid", true) }
        return (host.isEmpty ? "The server" : host, false)
    }

    /// An HTTP file still opening after 12 s: the server is asked whether
    /// it's there. A removed file or a refused login ends the wait with the
    /// card (mpv can wait on a server a long time); anything else is only
    /// logged and the player keeps waiting.
    private func watchLoading(_ it: MediaItem) {
        guard let url = it.resolvedURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let id = it.id
        problemCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled, self.isLoading, !self.fileLoaded, self.playingItem?.id == id else { return }
            let answer = await ServerProblem.probe(url, headers: it.headers)
            guard !Task.isCancelled, self.isLoading, !self.fileLoaded, self.playingItem?.id == id, self.errorMessage == nil else { return }
            let where_ = self.serverName(of: it)
            let p = ServerProblem.classify(status: answer.status, error: answer.error, server: where_.name, realDebrid: where_.realDebrid)
            dlog("player", "still opening after 12 s: the server answers \(answer.status.map(String.init) ?? "nothing") (\(p.kind))")
            guard p.kind == .gone || p.kind == .refused else { return }
            self.client?.command(["stop"])
            self.show(p, for: it)
        }
    }

    /// mpv couldn't open the file: for a file on a server, the server is
    /// asked why, and the card says it.
    private func diagnose(_ it: MediaItem, reason: String) {
        guard let url = it.resolvedURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        problemCheck?.cancel()
        checkingProblem = true
        let id = it.id
        problemCheck = Task { [weak self] in
            let answer = await ServerProblem.probe(url, headers: it.headers)
            guard let self, !Task.isCancelled, self.playingItem?.id == id, self.errorMessage != nil else { return }
            let where_ = self.serverName(of: it)
            let p = ServerProblem.classify(status: answer.status, error: answer.error, server: where_.name,
                                           realDebrid: where_.realDebrid, reason: reason)
            dlog("player/error", "the server answers \(answer.status.map(String.init) ?? (answer.error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "nothing"): \(p.title)")
            self.show(p, for: it)
        }
    }

    private func show(_ p: ServerProblem, for it: MediaItem) {
        isLoading = false
        checkingProblem = false
        problem = p
        if errorMessage == nil { errorMessage = p.title }
        // A file Real-Debrid (or another server) no longer has leaves the
        // search and Home's row at the next look (the index is read again).
        if p.kind == .gone, case .webdav(let sid) = it.source, let s = ServerStore.shared.server(id: sid) {
            LibraryIndexStore.shared.refreshNow(s)
        }
    }

    /// The history entry of the file that didn't play, for "Remove from
    /// Continue Watching".
    var problemHistoryEntry: HistoryEntry? {
        guard let it = playingItem else { return nil }
        return HistoryStore.shared.entry(for: it.id)
    }

    /// Start over (TitleHeroView): the first file opens at 0. Until 1.20.3 its
    /// history was deleted before the player opened, so a file that failed to
    /// open, or a quick close, lost its resume point and watched mark.
    private var startFirstAtZero = false

    private func startOptions(for item: MediaItem, toast: Bool) -> [String] {
        if startFirstAtZero { startFirstAtZero = false; return ["start=0"] }
        // Lab: a resume position for the first file (loading measurements).
        if item.id == queue.first?.id, let s = CommandLine.arguments.first(where: { $0.hasPrefix("-labStart=") }) { return ["start=" + s.dropFirst("-labStart=".count)] }
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
        problem = nil
        checkingProblem = false
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
        // Four minutes before the Up Next card (credits start when known), or
        // five before the end, so the next episode is open before the card
        // shows (with 15 s to spare): finding its stream and opening its link
        // took 24–37 s in the 28–29 Oct logs, and mpv only opens it once this
        // file has been read to the end (readToEnd). 1.17.x started two
        // minutes before the card, and Play Next on the card still had to
        // load the episode (29 Oct log: 3.3 and 5.8 s). 1.17.0 waited for the
        // end only, and with long credits the countdown finished before
        // anything was ready (27 Oct log: credits 3506–3750, card at 3506).
        let cardAt = upNextTrigger?.time ?? duration
        guard defaults.bool(forKey: SettingsKey.prepareNext), hasNext, playbackMode == "playlist", preparing == nil, fileLoaded,
              duration > 120, position >= cardAt - Self.prepareLead || duration - position < Self.prepareLead + 60 else { return }
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

    static let prepareLead: Double = 240

    /// mpv opens the next playlist entry only once this file has been read to
    /// its end (mpv manual, --prefetch-playlist: "opens the URL of the next
    /// playlist entry as soon as the current URL is fully read"), and it
    /// reads ahead no more than the buffer limit (demuxer-max-bytes, Settings
    /// → Playback → buffer). With more of the file left than that, the next
    /// episode wasn't opened before Play Next. The limit is raised to what's
    /// left of the file, up to a quarter of the memory iOS still gives the app
    /// and 768 MB, until the next file starts (not after a memory warning).
    private var raisedBuffer = false
    private var readToEndCheck: Timer?
    private func readToEnd() {
        guard let c = client, duration > 0 else { return }
        let mb = 1_048_576.0
        let size = Double(c.int("file-size") ?? 0)
        let limit = Double(max(32, defaults.integer(forKey: SettingsKey.cacheMB))) * mb
        let left = size > 0 ? size * max(0, duration - position) / duration * 1.15 + 16 * mb : 0
        if left > limit, !bufferTrimmed {
            let cap = min(768 * mb, Double(os_proc_available_memory()) / 4)
            let target = max(limit, min(left, cap))
            c.set("demuxer-max-bytes", "\(Int(target / mb))MiB")
            raisedBuffer = true
            dlog("player", "next episode: \(Int(left / mb)) MB of this file left; buffer limit \(Int(limit / mb)) → \(Int(target / mb)) MB so it's read to the end and mpv opens the next one\(target < left ? " (capped: less memory to spare)" : "")")
        } else {
            dlog("player", "next episode: \(Int(left / mb)) MB of this file left, within the \(Int(limit / mb)) MB buffer")
        }
        // Report when the file has been read to its end (mpv then opens the next).
        let cardAt = upNextTrigger?.time ?? duration
        readToEndCheck?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let c = self.client, !self.closed, self.appended != nil else { timer.invalidate(); return }
                // Asked off the main thread (1.25.0): a property read waits for
                // mpv's core, and this ran every 2 s for minutes on slow streams.
                c.query({ Self.fileReadToEnd($0) }) { [weak self] done in
                    guard done, let self, timer.isValid else { return }
                    timer.invalidate()
                    dlog("player", String(format: "next episode: this file read to the end at %.0f s, %.0f s before the Up Next card; mpv opens the next file now", self.position, cardAt - self.position))
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        readToEndCheck = t
    }

    /// mpv's reader has hit the end of this file (demuxer-cache-state "eof").
    nonisolated private static func fileReadToEnd(_ c: MPVClient) -> Bool {
        (c.string("demuxer-cache-state") ?? "").range(of: #""eof"\s*:\s*true"#, options: .regularExpression) != nil
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
        if let u = item.resolvedURL, !u.isFileURL, playLinks[item.id] == nil, let final = await LinkWarmer.resolve(u, headers: item.headers), final != u {
            playLinks[item.id] = final
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
        c.command(["loadfile", mpvPath(item), "append", "-1", opts.joined(separator: ",")])
        appended = (i, mpvPath(item))
        readToEnd()
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

    /// A tap on a playlist row. The row of the episode playing now does nothing.
    func playFromPlaylist(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        guard i != queueIndex else {
            dlog("player", "playlist: the episode playing now — nothing to do")
            if paused { setPaused(false) }
            return
        }
        goTo(i)
    }

    /// The latest "go to episode" request; a lookup that finishes after a newer
    /// request (another tap, a pick) does nothing.
    private var lookupToken = 0

    /// Moves to episode `i`. The episode playing now keeps playing, and
    /// `queueIndex` stays on it, until `i` is ready to load: an addon episode
    /// is looked up first, and one without the same release opens the picker
    /// instead. (1.17.0 moved `queueIndex` first and stopped the episode
    /// playing; with the picker up, history then went under the wrong episode
    /// and the end of the file skipped on.)
    private func goTo(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        lookupToken += 1
        if let done = resolvedItems[i] { queueIndex = i; load(done); return }
        guard queue[i].url.isEmpty, let p = pick(for: i) else { queueIndex = i; load(queue[i]); return }
        switch episodeStates[i] {
        case .pick?, .unavailable?:
            askToPick(i)
        default:
            let token = lookupToken
            let label = p.context.videoLabel ?? "episode \(i + 1)"
            showToast("Finding \(label)…")
            episodeStates[i] = .checking
            Task { [weak self] in
                guard let self else { return }
                let match = await AddonPlayback.screen(p)
                switch match {
                case .same: self.episodeStates[i] = .ready
                case .other: self.episodeStates[i] = .pick
                case .none: self.episodeStates[i] = .unavailable
                }
                guard self.lookupToken == token, !self.closed else {
                    dlog("player", "lookup for \(label) finished after a newer choice; ignored")
                    return
                }
                switch match {
                case .same(var found):
                    found.subtitles += await AddonPlayback.subtitles(type: p.context.type, videoId: p.context.videoId)
                    self.subsFetched.insert(i)
                    self.resolvedItems[i] = found
                    guard self.lookupToken == token, !self.closed else { return }
                    self.queueIndex = i
                    self.load(found)
                case .other, .none:
                    self.askToPick(i)
                }
            }
        }
    }

    /// The stream you picked for an episode; the episodes after it follow that release.
    func playPicked(_ s: AddonStream, from addon: InstalledAddon, for request: PickRequest) {
        pickRequest = nil
        lookupToken += 1
        let token = lookupToken
        episodeStates[request.id] = .checking
        Task { [weak self] in
            guard let self else { return }
            let ctx = request.context
            let subs = await AddonPlayback.subtitles(type: ctx.type, videoId: ctx.videoId)
            // A later choice (another pick, another episode) wins (review, 5 Nov).
            guard self.lookupToken == token, !self.closed else { return }
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
        goTo(queueIndex + 1)
    }

    func playPrevious() {
        if position > 10 || !hasPrevious { seek(to: 0); return }
        goTo(queueIndex - 1)
    }

    private func onFileLoaded() {
        guard let c = client else { return }
        dlog("player", "file loaded in \(String(format: "%.0f", Date().timeIntervalSince(loadStarted) * 1000)) ms")
        fileLoaded = true
        // The gestures tip comes up in the first plays after installing (1.27.0).
        FolioTips.note(PlayerGesturesTip.played)
        isLoading = false
        refreshTracks()
        refreshChapters()
        readDuration()
        addedSubtitles = []
        addSubtitles(item.subtitles)
        // Subtitle addons that answered after the stream started (AddonPlayback.subtitleWait).
        if let id = addonVideoID {
            let late = AddonPlayback.lateSubtitles(for: id)
            if addSubtitles(late) > 0 { dlog("player", "subtitles that came after the start added: \(late.count)") }
        }
        maybeRequestSegments()
        updateNowPlaying()
        startScreener()
        applyMemoryIfReady()
        readAudioLayoutLater()
        findMoreEpisodes()
        startPassLog()
        // Each new file: automatic PiP armed again from its state (1.26.0).
        if !isPiPActive { pip.rearmAutoStart(defaults.bool(forKey: SettingsKey.pipAuto)) }
    }

    /// The last episode in the queue, on a WebDAV server: the show's later
    /// episodes are looked for in the server's library, in other folders too,
    /// and added to the queue, so Up Next, getting the next one ready and
    /// autoplay go on to them. A debrid service keeps each torrent in its own
    /// folder, and a show added episode by episode had a queue of one (5 Nov
    /// report: The Gentlemen on Real-Debrid). Once per player.
    private var lookedForMore = false
    /// How many of the queue's items findMoreEpisodes added.
    private var addedFromElsewhere = 0
    private func findMoreEpisodes() {
        guard !lookedForMore, !hasNext, playbackMode == "playlist" else { return }
        let it = queue[queueIndex]
        guard case .webdav(let serverID) = it.source, let url = URL(string: it.url), url.scheme?.hasPrefix("http") == true,
              TitleParser.parse(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent).episode != nil,
              let server = ServerStore.shared.servers.first(where: { $0.id == serverID }) else { return }
        lookedForMore = true
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        Task { [weak self] in
            let store = LibraryIndexStore.shared
            await store.load(server)
            var files = store.state(serverID).index?.allFiles ?? []
            var found = await Task.detached(priority: .utility) { NextEpisodes.after(name, url: url, in: files) }.value
            // Nothing in a library listed more than 10 minutes ago: list it
            // again (what changed only) and look once more.
            if found.isEmpty, (store.state(serverID).index?.refreshed).map({ Date().timeIntervalSince($0) > LibraryIndexStore.freshFor }) ?? true {
                await store.refresh(server, full: false)
                files = store.state(serverID).index?.allFiles ?? []
                found = await Task.detached(priority: .utility) { NextEpisodes.after(name, url: url, in: files) }.value
            }
            guard let self, !self.closed else { return }
            guard !found.isEmpty else {
                dlog("player", "next episodes: none on \(server.name) after this one (\(files.count) files in its library)")
                return
            }
            let client = WebDAVClient(server: server)
            let clean = self.defaults.bool(forKey: SettingsKey.cleanTitles)
            let known = Set(self.queue.map(\.url))
            let more = found.map { f in
                client.mediaItem(for: DAVItem(url: f.url, name: f.name, isDirectory: false, size: f.size, modified: f.added, contentType: nil), cleanTitles: clean)
            }.filter { !known.contains($0.url) }
            guard !more.isEmpty else { return }
            self.queue += more
            self.addedFromElsewhere += more.count
            let folders = Set(found.map { $0.url.deletingLastPathComponent() }).count
            dlog("player", "next episodes: \(more.count) from \(folders) folder(s) on \(server.name) added after this one, first \(found[0].name)")
        }
    }

    /// The file's length: the time bar, skip segments (looked up only once
    /// it's known), history, Now Playing, PiP.
    private func applyDuration(_ d: Double) {
        clock.duration = d
        pipState.duration = d
        pip.invalidate()
        maybeRequestSegments()
        updateNowPlaying()
    }

    /// Reads the length once the file is loaded, besides observing it.
    ///
    /// mpv sends an observed property only when its value changes ("no
    /// change => no event", player/client.c). Up Next's playlist-next to the
    /// prepared episode keeps the same mpv state, and load() set the length
    /// back to 0 for the new file: when the next episode is exactly as long
    /// as the last, no new length ever arrives. 28 Oct recording: S01E15
    /// after S01E14 (both 23:25) showed 0:00 left with the knob at the end,
    /// got no Skip Intro/Ending, and its history had no length.
    private func readDuration() {
        guard let c = client, !CommandLine.arguments.contains("-noDurationRead") else { return }
        let id = item.id
        c.query({ $0.double("duration") }) { [weak self] d in
            guard let self, self.item.id == id, let d, d > 0, abs(self.clock.duration - d) > 0.001 else { return }
            dlog("player", "length read when the file loaded: \(Self.format(d)) (mpv sent none: the same as the last file's)")
            self.applyDuration(d)
        }
    }

    /// Lab (`-upNextLab`): Up Next's way to the next episode with two local
    /// files of the same length (the lab clip twice) — next in mpv's playlist
    /// as prepare(_:) does for a stream, then playlist-next.
    func labUpNext() {
        guard let c = client, hasNext, fileLoaded else { dlog("lab", "up next lab: not ready"); return }
        let i = queueIndex + 1
        let next = queue[i]
        c.set("keep-open", "always")
        c.set("prefetch-playlist", "yes")
        c.command(["playlist-clear"])
        c.command(["loadfile", next.mpvPath, "append", "-1"])
        appended = (i, next.mpvPath)
        dlog("lab", "up next lab: \(next.displayTitle) next in mpv's playlist; this file is \(Self.format(duration)) long")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            dlog("lab", "up next lab: on to the next episode")
            self.playNext()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let c = self.client else { return }
                c.query({ $0.double("duration") }) { d in
                    dlog("lab", "up next lab: now \(self.mediaTitle): the time bar's length \(Self.format(self.duration)), mpv's \(d.map { Self.format($0) } ?? "none") → \(self.duration > 0 && abs(self.duration - (d ?? 0)) < 0.01 ? "OK" : "WRONG")")
                }
            }
        }
    }

    // MARK: Tracks / chapters

    private var tracksRefreshPending = false
    /// Asked for while one was running: run once more after it, so the list
    /// read is never one from before the change (the file loading, a
    /// subtitle added), which show memory reads the tracks from.
    private var tracksRefreshAgain = false

    func refreshTracks() {
        guard let c = client else { return }
        guard !tracksRefreshPending else { tracksRefreshAgain = true; return }
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
                    height: type == "video" ? c.int(p + "demux-h").map(Int.init) : nil,
                    forced: type == "sub" ? c.flag(p + "forced") ?? false : false,
                    hearingImpaired: type == "sub" ? c.flag(p + "hearing-impaired") ?? false : false
                ))
            }
            return (list, c.string("video-params/gamma") ?? "")
        }) { [weak self] result in
            guard let self else { return }
            self.tracksRefreshPending = false
            if result.0 != self.tracks { self.tracks = result.0 }
            self.updateVideoFormat(gamma: result.1)
            if self.tracksRefreshAgain {
                self.tracksRefreshAgain = false
                self.refreshTracks()
                return
            }
            self.applyMemoryIfReady()
            self.retryPendingSubtitle()
            self.updateAudioFilters(because: "tracks read")
        }
    }

    func refreshChapters() {
        guard let c = client else { chapters = []; return }
        let started = loadStarted, afterLoad = fileLoaded
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
            guard let self, started == self.loadStarted else { return }
            if list != self.chapters { self.chapters = list }
            if afterLoad, !self.chaptersRead {
                self.chaptersRead = true
                self.maybeRequestSegments()
            }
        }
    }

    func tracks(_ type: String) -> [MediaTrack] { tracks.filter { $0.type == type } }

    /// A track picked in the Tracks menu: remembered for the show.
    func selectTrack(_ type: String, id: Int?) {
        let prop = type == "audio" ? "aid" : type == "sub" ? "sid" : "vid"
        client?.set(prop, id.map(String.init) ?? "no")
        switch type {
        case "audio":
            guard let t = tracks.first(where: { $0.type == "audio" && $0.id == id }) else { return }
            remember { $0.audio = AudioChoice(t) }
        case "sub":
            pendingSubtitle = nil
            if let id, let t = tracks.first(where: { $0.type == "sub" && $0.id == id }) {
                remember { $0.subtitle = SubtitleChoice(t) }
            } else if id == nil {
                remember { $0.subtitle = .turnedOff }
            }
        default: break
        }
    }

    func addSubtitle(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            // It used to be added anyway, and mpv quietly found nothing.
            dlog("subs/error", "couldn't copy the subtitle file: \(error.localizedDescription)")
            showToast("Couldn't open that subtitle file")
            return
        }
        client?.command(["sub-add", dest.path, "select"])
    }

    // MARK: Subtitle search (SubtitleSearch)

    /// "Search subtitles…" in the Tracks menu: the card over the player.
    @Published var subtitleSearch: SubtitleSearch?

    func searchSubtitles() {
        subtitleSearch?.cancel()
        let s = SubtitleSearch(item: playingItem ?? item)
        subtitleSearch = s
        s.start()
    }

    func closeSubtitleSearch() {
        subtitleSearch?.cancel()
        subtitleSearch = nil
    }

    /// A search result tapped: added to the file and shown ("cached": one
    /// added before, by the addon at the start or an earlier tap, is
    /// selected instead of loaded twice), and remembered for the show.
    func addSearchedSubtitle(_ r: SubtitleSearch.Result) {
        guard let c = client else { return }
        let lang = r.lang ?? ""
        let title = "\(SubtitleSearch.languageName(TrackMatch.language(r.lang) ?? "")) · \(r.label)"
        addedSubtitles.insert(r.url)
        pendingSubtitle = nil
        c.commandAsync(["sub-add", r.url, "cached", title, lang])
        dlog("subs", "search: added \(r.label) (\(lang.isEmpty ? "no language" : lang))")
        remember { $0.subtitle = SubtitleChoice(lang: r.lang, title: title, external: true) }
        closeSubtitleSearch()
        showToast("Subtitle added")
    }

    private var lastGamma = ""
    private func updateVideoFormat(gamma: String? = nil) {
        // While the decoder restarts, mpv has no video params for a moment
        // and reports no gamma: that isn't an SDR video. Read as one, the
        // OpenGL renderer switched HDR off, which changed the decoding and
        // restarted the decoder, which reported no gamma again, round and
        // round: a 4K Dolby Vision file never got going (5 Nov report: the
        // decoder flipped between VideoToolbox and software many times a
        // second). The last gamma is forgotten when a new file loads.
        if let gamma, !gamma.isEmpty { lastGamma = gamma }
        let gamma = lastGamma
        let dv = tracks.first { $0.type == "video" && $0.selected }?.dvProfile ?? 0
        if dv > 0 { videoFormat = "Dolby Vision" }
        else if gamma == "pq" { videoFormat = "HDR10" }
        else if gamma == "hlg" { videoFormat = "HLG" }
        else { videoFormat = gamma.isEmpty ? "" : "SDR" }
        updateGLHDR(gamma: gamma)
        updateMetalFramesHDR(gamma: gamma)
    }

    /// HDR on Metal in the video layer (1.28.0): libplacebo draws BT.2020 PQ
    /// (or HLG) into half-float frames, tagged with the video's light levels,
    /// as OpenGL's HDR frames are, but from the hardware decoder's own 10-bit
    /// frames, with Dolby Vision applied: no copy decoding, no stripping.
    private func updateMetalFramesHDR(gamma: String) {
        guard let mf = metalFrames, let c = client else { return }
        let hdrVideo = gamma == "pq" || gamma == "hlg"
        let edr = UIScreen.main.potentialEDRHeadroom > 1 || CommandLine.arguments.contains("-labEDR")
        let want = hdrVideo && defaults.bool(forKey: SettingsKey.hdrOutput) && edr && !glHDRFailedForFile
        guard want != glHDROn else { return }
        glHDROn = want
        if want {
            let hlg = gamma == "hlg"
            let info = SampleBufferRenderer.HDROutput(hlg: hlg, maxCLL: c.int("video-params/max-cll").map(Int.init), maxFALL: c.int("video-params/max-fall").map(Int.init),
                                                       maxLuma: c.double("video-params/max-luma"), minLuma: c.double("video-params/min-luma"))
            mf.onHDRFailed = { [weak self] in self?.glHDRFailed() }
            mf.setHDR(info)
            pip.setHDR(true)
            dlog("player", "Metal (video layer): HDR output \(hlg ? "HLG" : "PQ") BT.2020 from the hardware's 10-bit frames, MaxCLL \(info.maxCLL.map(String.init) ?? "?"), mastering \(info.maxLuma.map { "\(Int($0))" } ?? "?") nits")
        } else {
            mf.setHDR(nil)
            pip.setHDR(false)
            dlog("player", "Metal (video layer): SDR output\(hdrVideo ? " (HDR video tone-mapped: HDR output off or no HDR screen)" : "")")
        }
    }

    // MARK: HDR on the sample-buffer (OpenGL) renderer, 1.22.1

    /// The reference design: mpv draws an HDR video in its own colour space
    /// (BT.2020, PQ or HLG) into half-float frames tagged as HDR, which the
    /// layer shows with HDR brightness, in the app and in PiP alike. Needs
    /// "HDR output" on and a screen with HDR headroom; otherwise mpv tone-maps
    /// to SDR as before.
    private var glHDROn = false
    /// Half-float frames failed for this file: not tried again until the
    /// next one (the simulator, which can't make them, tried after every
    /// decoder restart, round and round).
    private var glHDRFailedForFile = false

    private func updateGLHDR(gamma: String) {
        guard renderer == .gl, let c = client, let gl = glRenderer else { return }
        let hdrVideo = gamma == "pq" || gamma == "hlg"
        // -labEDR: as on an HDR screen (the simulator has none), to test this path.
        let edr = UIScreen.main.potentialEDRHeadroom > 1 || CommandLine.arguments.contains("-labEDR")
        let want = hdrVideo && defaults.bool(forKey: SettingsKey.hdrOutput) && edr && !glHDRFailedForFile
        guard want != glHDROn else { return }
        glHDROn = want
        let autoDecode = (defaults.string(forKey: SettingsKey.hwdec) ?? "auto") == "auto"
        if want {
            let hlg = gamma == "hlg"
            c.set("target-prim", "bt.2020")
            c.set("target-trc", hlg ? "hlg" : "pq")
            // All 10 bits need copy decoding (OpenGL ES can't draw the
            // hardware decoder's 10-bit frames, see applyOptions); whether it's
            // worth its cost is decided by applyHDRDecode (1.26.1).
            hdrCopyActive = false
            if autoDecode { applyHDRDecode() }
            let info = SampleBufferRenderer.HDROutput(hlg: hlg, maxCLL: c.int("video-params/max-cll").map(Int.init), maxFALL: c.int("video-params/max-fall").map(Int.init),
                                                       maxLuma: c.double("video-params/max-luma"), minLuma: c.double("video-params/min-luma"))
            gl.onHDRFailed = { [weak self] in self?.glHDRFailed() }
            gl.setHDR(info)
            pip.setHDR(true)
            dlog("player", "OpenGL: HDR output \(hlg ? "HLG" : "PQ") BT.2020, \(hdrCopyActive ? "10-bit copy decoding" : "hardware frames")\(autoDecode ? "" : " (your decoding setting kept)"), MaxCLL \(info.maxCLL.map(String.init) ?? "?"), mastering \(info.maxLuma.map { "\(Int($0))" } ?? "?") nits")
        } else {
            c.set("target-prim", "auto")
            c.set("target-trc", "auto")
            if autoDecode && hdrCopyActive { c.set("hwdec", "videotoolbox,videotoolbox-copy"); c.set("hwdec-image-format", "nv12") }
            hdrCopyActive = false
            setDolbyVisionStripped(false)
            watchCopy(false)
            gl.setHDR(nil)
            pip.setHDR(false)
            dlog("player", "OpenGL: SDR output\(hdrVideo ? " (HDR video tone-mapped: HDR output off or no HDR screen)" : "")")
        }
    }

    /// The device couldn't make half-float frames: SDR output again.
    private func glHDRFailed() {
        guard glHDROn, let c = client else { return }
        glHDROn = false
        glHDRFailedForFile = true
        c.set("target-prim", "auto")
        c.set("target-trc", "auto")
        pip.setHDR(false)
        dlog("player/error", "OpenGL: HDR frames not possible here; tone-mapped to SDR")
    }

    // MARK: HDR decoding on the OpenGL renderer, 1.26.1

    /// HDR is decoded by copying each frame out of the hardware decoder (all
    /// 10 bits), or drawn from the hardware's own frames (8 bits, no copy).
    /// The copy is a 4K frame through memory 24–60 times a second: on your
    /// 7–8 Nov logs a 4K HDR film ran at ~50% CPU against ~6% for a 1080p
    /// one without it, and the switch to it mid-file sent an AV1 HDR video
    /// to software decoding for good (dav1d at ~190% CPU). So for long
    /// watching:
    /// - Picture → Efficient ("Coolest, longest battery") never copies: HDR
    ///   brightness stays, with 8-bit steps in gradients.
    /// - Balanced and Enhanced copy, unless the phone is hot (serious or
    ///   critical), or copying failed for this codec in this player.
    /// - Your own decoding choice in Settings is never changed.
    private var hdrCopyActive = false
    /// Codecs whose copy decoding fell back to software in this player.
    private var copyFailedCodecs: Set<String> = []
    /// The hardware decoder has decoded this file (a software decoder after
    /// that is a fallback, not the start).
    private var hardwareSeenForFile = false

    private var hdrWantsCopy: Bool {
        guard (defaults.string(forKey: SettingsKey.hwdec) ?? "auto") == "auto", PictureMode.current != .efficient else { return false }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return false }
        if copyTooSlowForFile { return false }
        if let codec = client?.string("video-format"), copyFailedCodecs.contains(codec) { return false }
        return true
    }

    /// Copy decoding on or off for the HDR file playing, as hdrWantsCopy says now.
    private func applyHDRDecode() {
        guard renderer == .gl, glHDROn, let c = client,
              (defaults.string(forKey: SettingsKey.hwdec) ?? "auto") == "auto" else { return }
        let copy = hdrWantsCopy
        guard copy != hdrCopyActive else { return }
        hdrCopyActive = copy
        if copy {
            c.set("hwdec-image-format", "no")
            c.set("hwdec", "videotoolbox-copy")
        } else {
            c.set("hwdec", "videotoolbox,videotoolbox-copy")
            c.set("hwdec-image-format", "nv12")
        }
        setDolbyVisionStripped(copy)
        watchCopy(copy)
        dlog("player", "OpenGL HDR: \(copy ? "10-bit copy decoding" : "hardware frames, no copy") (picture \(PictureMode.current.rawValue), thermal \(ProcessInfo.processInfo.thermalState.rawValue))")
    }

    // MARK: Copy decoding's limits (1.27.1)

    /// Copied frames carry the file's Dolby Vision metadata, which the
    /// OpenGL renderer can't apply: it took the picture for Dolby Vision's
    /// own colours and showed it green (Dune, a DV profile 7 remux, in
    /// Balanced and Enhanced, 9 Nov recording). Without it the film is its
    /// HDR10 base layer, as the hardware's own frames already showed it.
    /// The Metal renderer applies Dolby Vision and keeps it.
    private var dolbyVisionStripped = false

    private func setDolbyVisionStripped(_ on: Bool) {
        guard on != dolbyVisionStripped, let c = client else { return }
        dolbyVisionStripped = on
        _ = c.command(on ? ["vf", "add", "@foliodv:format=dolbyvision=no"] : ["vf", "remove", "@foliodv"])
        if on { dlog("player", "OpenGL HDR: Dolby Vision metadata left out while copying (the base layer's HDR10 is shown)") }
    }

    /// Copying didn't keep up with this file: hardware frames for the rest
    /// of it.
    private var copyTooSlowForFile = false
    private var copyWatch: Task<Void, Never>?

    /// While copying, the decoder's dropped frames are counted every 5 s;
    /// two windows in a row with more than one a second (after a few seconds
    /// to settle) and the copy stops. Dune, 4K at 60 Mb/s: 85 dropped in
    /// 20 s at 40–52% CPU and over 1 GB of memory, and it stuttered.
    private func watchCopy(_ on: Bool) {
        copyWatch?.cancel(); copyWatch = nil
        guard on else { return }
        let id = (playingItem ?? item).id
        copyWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            var last: Int64?
            var bad = 0
            while !Task.isCancelled {
                guard let self, !self.closed, self.hdrCopyActive, (self.playingItem ?? self.item).id == id, let c = self.client else { return }
                let drops = await withCheckedContinuation { (k: CheckedContinuation<Int64, Never>) in
                    c.query({ $0.int("frame-drop-count") ?? 0 }) { k.resume(returning: $0) }
                }
                if let last, !self.paused {
                    bad = drops - last > 5 ? bad + 1 : 0
                    if bad >= 2 {
                        self.copyTooSlowForFile = true
                        dlog("player/error", "OpenGL HDR: copy decoding dropped \(drops - last) frames in 5 s; hardware frames for the rest of this file")
                        self.showToast("10-bit HDR couldn't keep up here: smoother 8-bit HDR")
                        self.applyHDRDecode()
                        return
                    }
                }
                last = drops
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// The decoder went to software after the switch to copy decoding (AV1:
    /// the hardware decoder restarted mid-stream and gave up). Still so a
    /// second later: back to the hardware's own frames, and this codec
    /// isn't copied again in this player.
    private func checkCopyFallback() {
        guard hdrCopyActive, hardwareSeenForFile else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.hdrCopyActive, self.hwdecCurrent.isEmpty || self.hwdecCurrent == "no" else { return }
            let codec = self.client?.string("video-format") ?? "?"
            self.copyFailedCodecs.insert(codec)
            dlog("player/error", "OpenGL HDR: copy decoding fell back to software for \(codec); hardware frames instead")
            self.applyHDRDecode()
        }
    }

    // MARK: Transport

    // Asynchronous (1.24.1): mpv's reply isn't needed, the button follows
    // the "pause" property's event.
    func togglePause() {
        if ended { seek(to: 0); client?.setAsync("pause", false); ended = false; return }
        client?.setAsync("pause", !paused)
    }
    func setPaused(_ p: Bool) { client?.setAsync("pause", p) }

    /// mpv's own "mute", as its event last said (1.24.1): read here instead of
    /// asking mpv on the main thread before a skip.
    private var mpvMuted = false

    // Seeks are queued asynchronously: a synchronous mpv_command waits for
    // the core, which on a network file can take long enough to freeze the
    // button that was tapped.
    func seek(by seconds: Double) {
        guard let c = client else { return }
        // The sound is off until the picture lands, so quick skips don't
        // play a few milliseconds from each place on the way (4 Nov
        // recording: seven +10 s taps in 2 s, the sound cutting in and out).
        if !mutedForSkip, !paused, !mpvMuted {
            _ = c.setAsync("mute", true)
            mutedForSkip = true
        }
        // A skip while one is still landing is added to the next one: one
        // seek for a run of taps instead of one each.
        if skipRunning {
            skipPending += seconds
            skipsGathered += 1
            return
        }
        skipRunning = true
        sendSkip(seconds, c)
    }

    // MARK: Quick skips (1.22.2)

    /// A skip has been sent and its picture isn't up yet (playback restart).
    private var skipRunning = false
    private var skipStarted: CFTimeInterval = 0
    /// Seconds of skips pressed meanwhile, sent as one when it lands.
    private var skipPending: Double = 0
    /// mpv's sound was turned off for a skip (only when it wasn't muted already).
    private var mutedForSkip = false
    private var skipsGathered = 0

    private func sendSkip(_ seconds: Double, _ c: MPVClient) {
        let started = CACurrentMediaTime()
        skipStarted = started
        _ = c.commandAsync(["seek", String(seconds), "relative+exact"])
        // A seek that never shows a picture (an error, the end of the file)
        // mustn't leave the sound off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.skipRunning, self.skipStarted == started else { return }
            dlog("player", "skip: no picture 2 s after it; sound back")
            self.skipPending = 0
            self.skipLanded()
        }
    }

    /// The picture of a skip is up: the gathered skips go as one seek, or,
    /// with none, the sound comes back.
    private func skipLanded() {
        guard skipRunning || mutedForSkip else { return }
        if skipRunning, skipPending != 0, let c = client {
            let s = skipPending
            skipPending = 0
            sendSkip(s, c)
            return
        }
        skipRunning = false
        skipPending = 0
        if skipsGathered > 0 {
            dlog("player", "skips: \(skipsGathered + 1) taps went as fewer seeks, the sound off until the picture landed")
            skipsGathered = 0
        }
        if mutedForSkip {
            mutedForSkip = false
            _ = client?.setAsync("mute", false)
        }
    }

    func seek(to seconds: Double, exact: Bool = true) {
        if ended, duration > 0, seconds < duration - 0.5 { ended = false }
        // A place chosen outright: skips still waiting would move it on.
        skipPending = 0
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

    /// A speed picked in the menu (not hold-to-speed): remembered for the
    /// show (1.22.0).
    func chooseSpeed(_ s: Double) {
        setSpeed(s)
        speedTouched = true
        remember { $0.speed = s }
    }

    /// The second subtitle (mpv's secondary-sid, drawn at the top): a
    /// second language under the first, for learning one (1.22.0).
    @Published private(set) var secondarySid = "no"

    func selectSecondSubtitle(id: Int?) {
        client?.set("secondary-sid", id.map(String.init) ?? "no")
        if let id, let t = tracks.first(where: { $0.type == "sub" && $0.id == id }) {
            remember { $0.secondSubtitle = SubtitleChoice(t) }
        } else {
            remember { $0.secondSubtitle = .turnedOff }
        }
    }

    // MARK: Skipping for one show (1.22.0)

    /// The open file's show, when its settings can be remembered (the
    /// player menu's "Always skip … for this show").
    @Published private(set) var memoryShowName: String?
    @Published private(set) var showAutoSkip: Set<String> = []

    func setAlwaysSkip(_ kind: SkipSegment.Kind, _ on: Bool) {
        if on { showAutoSkip.insert(kind.rawValue) } else { showAutoSkip.remove(kind.rawValue) }
        let list = showAutoSkip.sorted()
        remember { $0.autoSkip = list }
        if on, let seg = activeSegment, seg.kind == kind { skip(seg) }
        showToast(on ? "\(kind.chapterTitle)s skipped for this show" : "\(kind.chapterTitle)s shown again")
    }

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
    /// Delays set in the menus: remembered for the show, and the subtitle
    /// delay for this file too (a file's own delay wins over the show's).
    func setSubDelay(_ v: Double) {
        let v = (v * 1000).rounded() / 1000
        client?.set("sub-delay", v)
        delaysTouched = true
        guard rememberOn, let key = memoryKey(for: memoryItem) else { return }
        ShowMemoryStore.shared.setSubDelay(v, file: memoryItem.id, for: key)
        rememberedShow = key.name
    }
    func setAudioDelay(_ v: Double) {
        let v = (v * 1000).rounded() / 1000
        client?.set("audio-delay", v)
        delaysTouched = true
        remember { $0.audioDelay = v }
    }
    /// Your size times the style preset's (Large is a third larger).
    func setSubScale(_ v: Double) {
        defaults.set(v, forKey: SettingsKey.subScale)
        applySubtitleFraming()
    }

    func setSubPos(_ v: Int) {
        defaults.set(v, forKey: SettingsKey.subPos)
        applySubtitleFraming()
    }

    // MARK: Subtitles that follow the zoom (1.23.4)

    /// On the OpenGL renderer the frames are the video's shape (so PiP's
    /// window is) and Fill is the layer cropping them, subtitles and all:
    /// a two-line subtitle lost its second line below the screen (6 Nov
    /// recording; mpv's log: "Window size: 2346x1320", OSD borders 0 in Fill
    /// and Fit alike). A pinch scales the picture before mpv frames it again,
    /// on both renderers. Automatic moves and resizes them so they keep
    /// their place and size on what's visible (sub-pos, sub-scale); on Metal
    /// mpv's own Fill keeps text subtitles on the screen already (libass with
    /// margins, mpv's default sub-use-margins).
    var subtitlesFollowZoom: Bool { (defaults.string(forKey: SettingsKey.subFollowZoom) ?? "auto") != "manual" }

    /// A pinch's stand-in scale of the picture (1: none).
    private(set) var pinchScale: CGFloat = 1
    /// The stand-in scale gone with nothing applied yet: the caller applies
    /// the framing that replaces it (setZoom), so no subtitle placement
    /// counts both at once.
    func dropPinchScale() { pinchScale = 1 }
    func setPinchScale(_ s: CGFloat) {
        guard abs(s - pinchScale) > 0.004 || s == 1 else { return }
        pinchScale = s
        applySubtitleFraming()
    }

    /// How much bigger than fitted the frame is shown, and the part of its
    /// height that's on the screen.
    static func subtitleFraming(gl: Bool, fill: Bool, fillRatio: CGFloat, pinch: CGFloat,
                                video: CGSize, view: CGSize) -> (scale: CGFloat, visible: CGFloat) {
        guard gl else {
            // Metal: the frame is the view; mpv frames Fill itself.
            let k = max(0.05, pinch)
            return (k, min(1, 1 / k))
        }
        let k = max(0.05, (fill ? fillRatio : 1) * pinch)
        guard video.width > 0, video.height > 0, view.width > 0, view.height > 0 else { return (k, 1) }
        let fitH = min(view.height, view.width * video.height / video.width)
        return (k, min(1, view.height / (fitH * k)))
    }

    /// sub-pos and sub-scale for what's on screen: your position and size
    /// on the visible part of the picture (Automatic), or as set (Manual).
    static func subtitlePlacement(userPos: Double, userScale: Double, framing: (scale: CGFloat, visible: CGFloat),
                                  follow: Bool, gl: Bool) -> (pos: Int, scale: Double) {
        var pos = userPos, scale = userScale
        if follow {
            pos = userPos - 50 * (1 - Double(framing.visible))
            scale = userScale / Double(framing.scale)
        }
        pos = min(gl ? 100 : 150, max(0, pos))
        return (Int(pos.rounded()), scale)
    }

    func applySubtitleFraming() {
        guard let c = client else { return }
        let framing = Self.subtitleFraming(gl: onLayer, fill: zoomToFill, fillRatio: fillRatio, pinch: pinchScale,
                                           video: videoSize, view: videoView.bounds.size)
        let userScale = (defaults.object(forKey: SettingsKey.subScale) == nil ? 1 : defaults.double(forKey: SettingsKey.subScale)) * subtitleStyle.scaleFactor
        let userPos = defaults.object(forKey: SettingsKey.subPos) == nil ? 100 : Double(defaults.integer(forKey: SettingsKey.subPos))
        let p = Self.subtitlePlacement(userPos: userPos, userScale: userScale, framing: framing, follow: subtitlesFollowZoom, gl: onLayer)
        guard lastSubPlacement.map({ $0.pos != p.pos || abs($0.scale - p.scale) > 0.005 }) ?? true else { return }
        lastSubPlacement = p
        if pinchScale == 1 {
            dlog("player", String(format: "subtitles %@: picture %.2f× fitted, %.0f%% of its height on screen (%@) → sub-pos %d, sub-scale %.2f",
                                  subtitlesFollowZoom ? "kept on screen" : "as set", framing.scale, framing.visible * 100,
                                  (renderer == .gl ? "OpenGL" : onLayer ? "Metal (video layer)" : "Metal") + (zoomToFill ? " Fill" : " Fit"), p.pos, p.scale))
        }
        c.set("sub-pos", String(p.pos))
        c.set("sub-scale", String(format: "%.3f", p.scale))
    }
    private var lastSubPlacement: (pos: Int, scale: Double)?

    /// The saved subtitle options for this renderer. The sample-buffer
    /// renderer's frames are the video's shape, with no black bars to draw
    /// in: a position below the picture (over 100) was cut off (review,
    /// 2 Nov), so it stops at the bottom edge.
    private func subtitleOptions() -> [(String, String)] {
        let options = SubtitleStyle.savedOptions(defaults)
        guard onLayer else { return options }
        return options.map { k, v in k == "sub-pos" ? (k, String(min(100, Int(v) ?? 100))) : (k, v) }
    }

    /// The style preset with your size, position, bold and box, live.
    func applySubtitleStyle() {
        guard let c = client else { return }
        for (k, v) in subtitleOptions() { c.set(k, v) }
        lastSubPlacement = nil
        applySubtitleFraming()
    }

    /// How much bigger the picture is filled than fitted in the player view
    /// (1: the video is the view's shape). The pinch follows it (1.23.1).
    var fillRatio: CGFloat {
        let v = videoSize, b = videoView.bounds.size
        guard v.width > 0, v.height > 0, b.width > 0, b.height > 0 else { return 1 }
        let fit = min(b.width / v.width, b.height / v.height), fill = max(b.width / v.width, b.height / v.height)
        return fit > 0 ? fill / fit : 1
    }

    func toggleZoom() { setZoom(fill: !zoomToFill) }

    /// OpenGL: the layer's framing alone, for a pinch out of Fill, which
    /// shrinks Fit scaled up rather than Fill (1.27.1).
    func setLayerFill(_ fill: Bool) {
        if onLayer { pip.setFill(fill) }
    }

    /// Fit or Fill. On OpenGL the layer's gravity changes here and now, in
    /// the caller's transaction, not when mpv's echo of panscan arrives: a
    /// pinch drops its stand-in scale in the same screen update (1.23.4; the
    /// 6 Nov recording had a frame of each framing at once).
    func setZoom(fill: Bool, toast: Bool = true) {
        if onLayer { pip.setFill(fill) }
        zoomToFill = fill
        client?.set("panscan", fill ? 1.0 : 0.0)
        if toast { showToast(fill ? "Fill" : "Fit") }
        remember { $0.panscan = fill ? 1 : 0 }
        applySubtitleFraming()
    }

    /// Metal: a pinch frames the picture in mpv as the fingers move (panscan
    /// between Fit, 0, and Fill, 1), so there's no stand-in to hand over.
    func setLivePanscan(_ p: Double) {
        client?.set("panscan", min(1, max(0, p)))
    }

    func setAspect(_ value: String) {
        aspectOverride = value
        client?.set("video-aspect-override", value)
    }

    /// mpv writes the picture off the main thread, and the toast says what
    /// happened. It said "saved" whatever happened, and the save (a full
    /// frame to PNG) held the main thread (review, 2 Nov).
    func takeScreenshot(subtitles: Bool) {
        guard let c = client else { return }
        c.query({ $0.command(["screenshot", subtitles ? "subtitles" : "video"]) }) { [weak self] r in
            guard let self else { return }
            if r >= 0 {
                self.showToast("Screenshot saved")
            } else {
                dlog("player/error", "screenshot failed: \(String(cString: mpv_error_string(r)))")
                self.showToast("Screenshot failed")
            }
        }
    }

    func skip(_ segment: SkipSegment) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showToast("Skipped \((segment.name ?? segment.kind.chapterTitle).lowercased())")
        if segment.kind == .intro { introSkipped(segment) }
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

    /// The PiP button: the current frame into PiP's layer first (see aboutToLeave).
    func startPiP() {
        takeSnapshot(leaving: true)
        pip.start()
    }
    func stopPiP() { pip.stop() }

    // MARK: Toast

    func showToast(_ text: String) {
        toast = text
        // Said aloud too (1.27.0): VoiceOver users never heard them.
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: text) }
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }

    // MARK: History

    /// The item whose file mpv has open, for history. `item` follows
    /// queueIndex, and Next, a pick and auto-next set that before the next
    /// episode loads (and keep the last file playing while an addon is
    /// asked). Saved under `item`, the last file's position and length went
    /// to the next episode's entry, which load() then read as the place to
    /// start: a manual Next mid-episode opened the next one at the old time
    /// (review, 31 Oct).
    private var playingItem: MediaItem?

    func saveHistory(force: Bool = false) {
        guard fileLoaded, duration > 0 || position > 0 else { return }
        if !force && Date().timeIntervalSince(lastHistorySave) < 5 { return }
        lastHistorySave = Date()
        flushWatched()
        var stored = playingItem ?? item
        if stored.title.isEmpty { stored.title = mediaTitle }
        HistoryStore.shared.record(stored, position: leftFinished && duration > 0 ? duration : position, duration: duration)
        // Handoff: the other device can pick up here (Handoff.swift). Every
        // 30 s is near enough for picking up; each update has iOS encode and
        // advertise the activity (1.26.1: it was every 5 s for the whole film).
        if force || Date().timeIntervalSince(lastHandoff) >= 30 {
            lastHandoff = Date()
            HandoffActivity.playing(item: stored, position: position, duration: duration)
        }
        // Next episodes downloaded on Wi-Fi, when that's on (AutoDownload; once per file a run).
        if duration > 0, position / duration >= AutoDownload.threshold {
            AutoDownload.watched(item: stored, progress: position / duration)
        }
        // Trakt, AniList, MyAnimeList (1.26.0): once per file a session, at
        // the point history counts it as watched (HistoryEntry.isFinished).
        if duration > 0, !syncSent.contains(stored.id), SyncCenter.shared.anyOn,
           leftFinished || position / duration > 0.92 || (duration >= 600 && duration - position < 90) {
            syncSent.insert(stored.id)
            sendWatched(stored)
        }
    }

    // MARK: Sync (1.26.0)

    /// Files already sent to the sync services in this player.
    private var syncSent: Set<String> = []
    /// The playing file's IMDb identity ("tt…:1:3", "tt…"), found from its name (resolveShowKey).
    private var fileIdentity: (id: String, identity: String?)?

    private func sendWatched(_ it: MediaItem) {
        var identity: String?
        if case .addon = it.source { identity = TitleIdentity.fromAddonKey(it.historyKey ?? "") }
        else if fileIdentity?.id == it.id { identity = fileIdentity?.identity }
        let parts = identity?.split(separator: ":").map(String.init) ?? []
        let season = parts.count == 3 ? Int(parts[1]) : nil
        let episode = parts.count == 3 ? Int(parts[2]) : nil
        let name = it.resolvedURL?.lastPathComponent ?? it.title
        let fileName = TitleParser.isMedia(name) ? name : it.title
        let parsed = TitleParser.parse(fileName)
        var hint = it.anime ?? AnimeHint()
        if hint.title == nil { hint.title = it.streamPick?.context.name ?? parsed.title }
        if hint.episode == nil { hint.episode = it.streamPick?.context.episode ?? parsed.episode ?? episode }
        let isMovie = identity.map { _ in parts.count == 1 } ?? (hint.episode == nil)
        let fansub = fileName.hasPrefix("[") || fileName.range(of: #" - \d{1,4}\b"#, options: .regularExpression) != nil
        let known = hint.hasAnimeID || it.streamPick?.context.isAnime == true || fansub
        let title = memoryShowName ?? it.streamPick?.context.name ?? hint.title ?? it.displayTitle
        Task {
            var anime = known
            if !anime, !isMovie, let meta = await MetadataService.shared.lookup(filename: fileName) {
                anime = meta.genres?.contains { $0.localizedCaseInsensitiveContains("anim") } ?? false
            }
            SyncCenter.shared.watched(SyncEvent(title: title, imdb: parts.first, season: season, episode: episode, isMovie: isMovie,
                                                anime: isMovie ? nil : hint, looksLikeAnime: anime && !isMovie, watchedAt: Date()))
        }
    }

    private var lastHandoff = Date.distantPast

    // MARK: Watch time (WatchLog, 1.24.0)

    /// Time watched since the last save, in real seconds (at 2x, a minute
    /// of the file is 30 s). Only playback moving on by itself counts: a
    /// seek or a jump of more than 2 s doesn't.
    private var watchPending: Double = 0

    private func countWatched(from before: Double, to p: Double) {
        let d = p - before
        guard !paused, d > 0, d <= 2 else { return }
        watchPending += d / max(0.25, speed)
    }

    private func flushWatched() {
        guard watchPending >= 1 else { return }
        let stored = playingItem ?? item
        let e = HistoryEntry(item: stored, position: 0, duration: 0, updated: Date())
        let episode = HeroCard.parts(stored, meta: nil).number != nil
        HabitLog.shared.playedSomething()
        WatchLog.shared.add(seconds: watchPending, id: e.id, isEpisode: episode,
                            showKey: episode ? HistoryStore.showKey(e) : nil, showName: episode ? ShowCatalog.name(of: e) : nil)
        watchPending = 0
    }

    // MARK: Show memory (ShowMemory.swift)

    private var rememberOn: Bool { defaults.bool(forKey: SettingsKey.rememberPerShow) }
    /// The file mpv has open (see playingItem): what's remembered is for its show.
    private var memoryItem: MediaItem { playingItem ?? item }
    /// The open file's show, once known.
    private var showKey: (itemID: String, key: ShowKey)?
    private var memoryApplied = false
    /// While a show's settings are applied: they aren't a choice to remember.
    private var applyingMemory = false
    /// A remembered subtitle the file didn't have when its tracks were first
    /// read: an addon's subtitles are added after the file opens.
    private var pendingSubtitle: (choice: SubtitleChoice, until: Date)?
    /// The show's name when something is remembered for it (the menu's Forget row).
    @Published private(set) var rememberedShow: String?

    private func memoryKey(for item: MediaItem) -> ShowKey? {
        guard let k = showKey, k.itemID == item.id else { return nil }
        return k.key
    }

    /// The show of the file being opened: an addon item's IMDb id at once; a
    /// file's from its saved release match (TitleIdentity, no network), with
    /// its name as the other key.
    private func resolveShowKey(for item: MediaItem) {
        showKey = nil
        rememberedShow = nil
        memoryShowName = nil
        showAutoSkip = []
        hiddenIntros = []
        let id = item.id
        func showID(_ identity: String?) -> String? { identity.map { String($0.prefix { $0 != ":" }) } }
        if case .addon = item.source {
            setShowKey(ShowKey.make(item: item, imdb: showID(TitleIdentity.fromAddonKey(item.historyKey ?? ""))), for: id)
            return
        }
        let name = item.fileName
        var folder: String?
        if case .webdav = item.source, let u = URL(string: item.url) {
            let f = u.deletingLastPathComponent().lastPathComponent
            folder = f.removingPercentEncoding ?? f
        }
        Task { [weak self] in
            let identity = await TitleIdentity.forFile(name: name, folder: folder) { release in
                guard let m = await ReleaseMatcher.shared.saved(release), m.confident else { return nil }
                return m.imdbID
            }
            self?.fileIdentity = (id, identity)
            self?.setShowKey(ShowKey.make(item: item, imdb: showID(identity)), for: id)
        }
    }

    private func setShowKey(_ key: ShowKey?, for id: String) {
        guard memoryItem.id == id else { return }
        guard let key else { dlog("memory", "no show to remember settings for (\(memoryItem.fileName))"); return }
        showKey = (id, key)
        memoryShowName = key.name
        rememberedShow = ShowMemoryStore.shared.entry(for: key.keys) != nil ? key.name : nil
        hiddenIntros = Set(ShowMemoryStore.shared.entry(for: key.keys)?.settings.introHidden ?? [])
        if !hiddenIntros.isEmpty { dlog("skip", "\(key.name): intro pills hidden (watched in \(Self.introEpisodesToHide) episodes): \(hiddenIntros.sorted())") }
        applyMemoryIfReady()
    }

    /// A delay was changed in this player (by you or a show's memory): a
    /// show with none remembered goes back to 0. Until then a delay is left
    /// as it is, so one from mpv.conf (a Bluetooth headset's) still applies.
    private var delaysTouched = false
    /// The same for speed: a show with none remembered goes back to your
    /// default speed only after one was changed in this player.
    private var speedTouched = false

    /// Once per file, when it's open, its tracks are known and its show is:
    /// what's remembered for the show. Delays are the show's own: with none
    /// remembered, one set for another show in this player doesn't carry
    /// over to this one. The Anime4K mode likewise goes back to your default.
    private func applyMemoryIfReady() {
        guard rememberOn, fileLoaded, !memoryApplied, let c = client, let key = memoryKey(for: memoryItem),
              tracks.contains(where: { $0.type == "audio" || $0.type == "video" }) else { return }
        memoryApplied = true
        let entry = ShowMemoryStore.shared.entry(for: key.keys)
        let s = entry?.settings ?? ShowSettings()
        var done: [String] = []
        applyingMemory = true
        defer { applyingMemory = false }
        let sub = entry?.subDelay(file: memoryItem.id) ?? s.subDelay ?? (delaysTouched ? 0 : subDelay)
        if abs(sub - subDelay) > 0.0005 { c.set("sub-delay", sub); delaysTouched = true; done.append(String(format: "subtitle delay %+.2f s", sub)) }
        let audio = s.audioDelay ?? (delaysTouched ? 0 : audioDelay)
        if abs(audio - audioDelay) > 0.0005 { c.set("audio-delay", audio); delaysTouched = true; done.append(String(format: "audio delay %+.0f ms", audio * 1000)) }
        if let p = s.panscan, (p > 0.5) != zoomToFill { c.set("panscan", p); done.append(p > 0.5 ? "Fill" : "Fit") }
        let mode = s.anime4k.flatMap(Anime4KMode.init(rawValue:)) ?? Anime4K.mode
        if mode != anime4kMode { anime4kMode = mode; done.append("Anime4K \(mode.title)") }
        let wantSpeed = s.speed ?? (speedTouched ? defaults.double(forKey: SettingsKey.defaultSpeed) : speed)
        if abs(wantSpeed - speed) > 0.001, wantSpeed > 0 { c.set("speed", wantSpeed); speedTouched = true; done.append(String(format: "speed %.2g×", wantSpeed)) }
        showAutoSkip = Set(s.autoSkip ?? [])
        if !showAutoSkip.isEmpty { done.append("always skip \(showAutoSkip.sorted().joined(separator: ", "))") }
        if let second = s.secondSubtitle {
            if second.off {
                if secondarySid != "no" { c.set("secondary-sid", "no") }
            } else if let t = TrackMatch.subtitle(second, among: tracks.filter { !$0.selected }) {
                c.set("secondary-sid", String(t.id)); done.append("second subtitles \(t.id) \(t.label)")
            }
        }
        if let a = s.audio {
            if let t = TrackMatch.audio(a, among: tracks) {
                if !t.selected { c.set("aid", String(t.id)); done.append("audio \(t.id) \(t.label) \(t.detail)") }
            } else {
                done.append("no \(a.lang ?? "untagged") audio like the remembered one")
            }
        }
        if let sc = s.subtitle { applySubtitle(sc, c, &done) }
        dlog("memory", "\(key.name) [\(key.keys.joined(separator: ", "))]: "
             + (entry == nil ? "nothing remembered yet" + (done.isEmpty ? "" : "; " + done.joined(separator: ", "))
                : done.isEmpty ? "already as remembered" : done.joined(separator: ", ")))
    }

    private func applySubtitle(_ choice: SubtitleChoice, _ c: MPVClient, _ done: inout [String]) {
        if choice.off {
            if tracks.contains(where: { $0.type == "sub" && $0.selected }) { c.set("sid", "no"); done.append("subtitles off") }
            return
        }
        if let t = TrackMatch.subtitle(choice, among: tracks) {
            if !t.selected { c.set("sid", String(t.id)); done.append("subtitles \(t.id) \(t.label) \(t.detail)") }
            // An addon's file was remembered: one of those may still come.
            if choice.external && !t.external { pendingSubtitle = (choice, Date().addingTimeInterval(20)) }
        } else {
            pendingSubtitle = (choice, Date().addingTimeInterval(20))
            done.append("subtitles in \(choice.lang ?? "no language") not here yet")
        }
    }

    /// The tracks changed (a subtitle added): the remembered subtitle, if it
    /// wasn't there before, for 20 s after the file opened and until you
    /// pick one yourself.
    private func retryPendingSubtitle() {
        guard let p = pendingSubtitle, let c = client else { return }
        guard Date() < p.until, fileLoaded else { pendingSubtitle = nil; return }
        guard let t = TrackMatch.subtitle(p.choice, among: tracks), !(p.choice.external && !t.external) else { return }
        pendingSubtitle = nil
        guard !t.selected else { return }
        c.set("sid", String(t.id))
        dlog("memory", "subtitles \(t.id) \(t.label) \(t.detail), added after the file opened")
    }

    /// A choice of yours, for the show of the open file.
    private func remember(_ change: (inout ShowSettings) -> Void) {
        guard rememberOn, !applyingMemory, let key = memoryKey(for: memoryItem) else { return }
        ShowMemoryStore.shared.update(key) { change(&$0.settings) }
        rememberedShow = key.name
    }

    /// The player menu's "Forget settings for …".
    func forgetShow() {
        guard let key = memoryKey(for: memoryItem), let e = ShowMemoryStore.shared.entry(for: key.keys) else { return }
        ShowMemoryStore.shared.forget(e.id)
        rememberedShow = nil
        dlog("memory", "\(key.name): forgotten")
        showToast("Forgot settings for \(key.name)")
    }

    // MARK: Audio filters (AudioFilters.swift)

    /// The playing track's channels as decoded (audio-params), nil while unknown.
    private var audioLayout: String?
    /// The graph in mpv's af list now.
    private var appliedAudioGraph: String?
    private var appliedLayoutSpecific = false

    /// Which optional filters the engine has (once per app run), then the
    /// filters if they start on.
    private func probeAudioFilters(_ c: MPVClient) {
        if AudioFilters.available == nil {
            let probe = "@\(AudioFilters.label)-probe"
            let found = AudioFilters.probe { name in
                let ok = c.command(["af", "add", "\(probe):\(name)"]) >= 0
                if ok { c.command(["af", "remove", probe]) }
                return ok
            }
            AudioFilters.available = found
            dlog("audio", "optional audio filters in this engine: \(found.isEmpty ? "none" : found.sorted().joined(separator: ", ")) (asked for \(AudioFilters.optional.joined(separator: ", ")))")
        }
        if nightMode { dlog("audio", "night mode on at start: Dolby range compression \(AudioFilters.ac3drc(night: true))") }
    }

    /// Puts the graph for night mode and dialogue boost in mpv's af list
    /// (or takes it out), for the playing track's channels: the decoder's
    /// layout, or before it's known, the track's as the file gives it. Only
    /// a changed graph touches mpv (each change rebuilds its audio filters).
    private func updateAudioFilters(because why: String) {
        guard let c = client else { return }
        let on = nightMode || dialogueBoost
        let layout = audioLayout ?? tracks.first { $0.type == "audio" && $0.selected }?.channels
        if on && layout == nil { return }          // applied when the channels are known
        let plan = AudioFilters.plan(night: nightMode, dialogue: dialogueBoost, layout: layout, available: AudioFilters.available ?? [])
        if plan != audioFilterPlan { audioFilterPlan = plan }
        guard plan?.graph != appliedAudioGraph else { return }
        if appliedAudioGraph != nil {
            let r = c.command(["af", "remove", "@" + AudioFilters.label])
            if r < 0 { dlog("audio/error", "af remove @\(AudioFilters.label) -> \(String(cString: mpv_error_string(r)))") }
            appliedAudioGraph = nil
            appliedLayoutSpecific = false
        }
        guard let plan else { dlog("audio", "\(why): audio filters off"); return }
        let r = c.command(["af", "add", plan.entry])
        if r >= 0 {
            appliedAudioGraph = plan.graph
            appliedLayoutSpecific = plan.layoutSpecific
            dlog("audio", "\(why): \(layout ?? "?") → \(plan.entry)")
        } else {
            dlog("audio/error", "\(why): mpv refused \(plan.entry): \(String(cString: mpv_error_string(r)))")
        }
    }

    /// A new file: a graph made for the last track's channels comes out
    /// first (pan names its channels and fails on others).
    private func dropLayoutFilter(_ c: MPVClient) {
        audioLayout = nil
        guard appliedLayoutSpecific, appliedAudioGraph != nil else { return }
        c.command(["af", "remove", "@" + AudioFilters.label])
        appliedAudioGraph = nil
        appliedLayoutSpecific = false
    }

    /// mpv sends an observed value only when it changes: the next file's
    /// channels may be the last one's. Read once if none came.
    private func readAudioLayoutLater() {
        let id = memoryItem.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let c = self.client, self.memoryItem.id == id, self.audioLayout == nil else { return }
            c.query({ $0.string("audio-params/channels") }) { [weak self] l in
                guard let self, let l, self.audioLayout == nil, self.memoryItem.id == id else { return }
                self.audioLayout = l
                self.updateAudioFilters(because: "channels read")
            }
        }
    }

    // MARK: Skip segments

    private func maybeRequestSegments() {
        guard fileLoaded, chaptersRead, !segmentsRequested, duration > 0 else { return }
        segmentsRequested = true
        // Looked up even with the Skip button off: Up Next uses the credits time.
        if defaults.bool(forKey: SettingsKey.skipUseChapters) {
            let chs = chapters.map { ($0.title, $0.time) }
            let s = SkipService.tidy(SkipService.segments(fromChapters: chs, duration: duration), duration: duration, chapters: chs, anime: item.anime?.hasAnimeID == true)
            if !s.isEmpty { segments = s; dlog("skip", "from chapters: \(s.map { "\($0.label) \(Int($0.start))-\(Int($0.end))" })"); return }
        }

        let name = item.resolvedURL?.lastPathComponent ?? item.title
        let fileName = TitleParser.isMedia(name) ? name : item.title
        let parsed = TitleParser.parse(fileName)
        var hint = item.anime ?? AnimeHint()
        if hint.title == nil { hint.title = parsed.title }
        if hint.episode == nil { hint.episode = parsed.episode }
        // An anime database's id for it. Not just a hint: every episode file
        // gets one with its title and number (WebDAVClient.mediaItem and the
        // other sources), so "has a hint" was true for live-action shows too,
        // which then got anime lookups and Opening/Ending names (MobLand in
        // the 5 Nov log: "Skip Opening", "Skip Ending").
        let explicitAnime = item.anime?.hasAnimeID == true
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
            // Anime databases only for anime: an anime id, animation per IMDb,
            // or a title IMDb doesn't know (AniList's search decides). Never
            // for a show IMDb knows as live action.
            let animation = meta?.genres?.contains { $0.localizedCaseInsensitiveContains("anim") } ?? false
            if found.segments.isEmpty, hint.episode != nil, explicitAnime || animation || meta == nil {
                found.segments = await SkipService.shared.lookup(hint: hint, season: parsed.season, duration: dur, oatLength: len > 0 ? len : 90)
                dlog("skip", "anime lookup \(hint.title ?? "?") s\(parsed.season ?? 1)e\(hint.episode ?? 0): \(found.segments.count) segment(s)")
            }
            await MainActor.run {
                guard let self, self.item.id == key else { return }
                self.postCredits = found.postCredits
                guard !found.segments.isEmpty else { return }
                let anime = explicitAnime || animation || (meta == nil && fansubName) || found.segments.contains { $0.source == "AniSkip" || $0.source == "OAT" }
                self.segments = SkipService.tidy(found.segments, duration: dur, chapters: self.chapters.map { ($0.title, $0.time) }, anime: anime)
                dlog("skip", "segments: \(self.segments.map { "\($0.label) \(Int($0.start))-\(Int($0.end))" })")
                if self.defaults.bool(forKey: SettingsKey.skipInjectChapters), self.chapters.isEmpty {
                    self.injectChapters(self.segments)
                }
            }
        }
    }

    // MARK: Up Next

    struct UpNext: Equatable {
        let start: Double          // playback time the card appeared at
        let autoplay: Bool         // counts down and plays the next file
        let next: MediaItem
        /// The card's other button: what it lets you watch, named as the
        /// part is ("Watch Ending", "Watch Preview"). 1.23.2: it said
        /// "Watch Credits" over every part (6 Nov request).
        var stay = "Keep Watching"
    }
    @Published var upNext: UpNext?
    private var upNextDismissed = false
    private var postCredits = false
    static let upNextCountdown = 10.0

    /// When the card appears: the start of the credits (file chapters,
    /// IntroDB / TheIntroDB, AniSkip ending) if known, else 30 s before the end.
    ///
    /// 1.23.2 (6 Nov request): no card over the credits when a scene follows
    /// them (a post-credits scene, an epilogue chapter: more than 30 s of the
    /// episode after them that isn't a preview). It came up there without its
    /// countdown and covered the scene; now the scene plays, and the next
    /// episode starts when the file ends (autoplay). A preview after the
    /// credits is no scene, and some would rather not see it: the card comes
    /// at the credits, or at the preview when a scene comes in between.
    static func upNextTrigger(segments: [SkipSegment], duration: Double, postCredits: Bool, autoplay: Bool) -> (time: Double, autoplay: Bool, stay: String)? {
        func stay(_ s: SkipSegment) -> String { "Watch " + (s.name ?? (s.kind == .preview ? "Preview" : "Credits")) }
        let preview = segments.filter { $0.kind == .preview && $0.start > duration * 0.6 }.min { $0.start < $1.start }
        if let outro = segments.filter({ $0.kind == .outro && $0.start > duration * 0.5 }).min(by: { $0.start < $1.start }) {
            if let preview, preview.start >= outro.end - 2 {
                // Credits, then a preview: the card at the credits, unless a scene comes between them.
                return postCredits || preview.start - outro.end > 30 ? (preview.start, autoplay, stay(preview)) : (outro.start, autoplay, stay(outro))
            }
            if postCredits || duration - outro.end > 30 { return nil }
            return (outro.start, autoplay, stay(outro))
        }
        // No credits known but a skippable preview closes the episode: the card
        // takes over there instead of a "Skip Preview" pill.
        if let preview { return (preview.start, autoplay, stay(preview)) }
        if postCredits { return nil }
        return (max(duration * 0.9, duration - 30), autoplay, "Keep Watching")
    }

    private var upNextTrigger: (time: Double, autoplay: Bool, stay: String)? {
        guard hasNext, playbackMode == "playlist", defaults.bool(forKey: SettingsKey.upNextEnabled), duration > 120 else { return nil }
        return Self.upNextTrigger(segments: segments, duration: duration, postCredits: postCredits, autoplay: defaults.bool(forKey: SettingsKey.autoplayNext))
    }

    private func updateUpNext() {
        guard !upNextDismissed, let trigger = upNextTrigger else {
            if upNext != nil { upNext = nil }
            return
        }
        if position >= trigger.time && position < duration - 0.3 {
            if upNext == nil {
                upNext = UpNext(start: trigger.time, autoplay: trigger.autoplay, next: queue[queueIndex + 1], stay: trigger.stay)
                // Whether Play Next will be instant: the next file is in mpv's
                // playlist, and this one has been read to the end (mpv opens the
                // next one only then).
                let read = client.map(Self.fileReadToEnd) ?? false
                dlog("player", "up next card at \(Int(position)) s: next episode \(appended?.index == queueIndex + 1 ? "prepared" : preparing == queueIndex + 1 ? "still being prepared" : "not prepared"), this file \(read ? "read to the end" : "not read to the end yet")")
            }
            if trigger.autoplay, !paused, position >= trigger.time + Self.upNextCountdown {
                // Once: until the next file loads (load() clears this), the card
                // stays down. 1.17.0 put it back on the next position update while
                // an addon episode was still being looked up, finished it again,
                // and moved on again — six times in the 27 Oct log, from E1 to E6.
                upNext = nil
                upNextDismissed = true
                dlog("player", "up next: countdown finished")
                finishedHere()
                playNext()
            }
        } else if upNext != nil {
            upNext = nil      // seeked back before the credits
        }
    }

    /// The card's Play Now.
    func playNextFromCard() {
        dismissUpNext()
        finishedHere()
        playNext()
    }

    /// Up Next went on to the next episode: this one counts as watched,
    /// though its credits or preview didn't play. In the lab (6 Nov) an
    /// episode left at its "Ending" chapter stayed "2:10 / 2:30", in
    /// progress: 87% and 20 s left is under History's "finished" line.
    private func finishedHere() {
        leftFinished = true             // saveHistory records it played to its end
    }
    private var leftFinished = false

    func dismissUpNext() {
        upNextDismissed = true
        upNext = nil
    }

    private func injectChapters(_ segs: [SkipSegment]) {
        var marks: [(title: String, time: Double)] = []
        let sorted = segs.sorted { $0.start < $1.start }
        if let first = sorted.first, first.start > 1 { marks.append(("Episode", 0)) }
        for (i, s) in sorted.enumerated() {
            // The pill's own name (tidy's: the file's chapter, or Intro/Ending
            // by where it sits), so an intro moved to the end isn't an "Opening".
            marks.append((s.name ?? s.kind.chapterTitle, s.start))
            let nextStart = i + 1 < sorted.count ? sorted[i + 1].start : duration
            if s.end < nextStart - 1, s.end < duration - 1 { marks.append(("Episode", s.end)) }
        }
        client?.setChapters(marks)
    }

    // MARK: GPU work per frame (1.23.2)

    /// What the renderer does for each frame, from mpv's own count
    /// (`vo-passes`: every render pass with its GPU time, on both renderers),
    /// and the frames dropped or late since the last line. 20 s into a file,
    /// then every 2 minutes. Anime4K was said to lag on Metal and not on
    /// OpenGL: this shows which passes run on each, and what they cost on
    /// the phone, instead of a guess.
    private var passLog: Task<Void, Never>?
    private var lastDrops: (dropped: Int64, delayed: Int64)?

    private func startPassLog() {
        passLog?.cancel()
        lastDrops = nil
        let id = (playingItem ?? item).id
        passLog = Task { [weak self] in
            var wait: UInt64 = 20
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                wait = 120
                guard let self, !self.closed, (self.playingItem ?? self.item).id == id else { return }
                if !self.paused { self.logPasses() }
            }
        }
    }

    private func logPasses() {
        guard let c = client else { return }
        let renderer = renderer == .gl ? "OpenGL" : onLayer ? "Metal, video layer" : "Metal"
        let a4k = anime4kMode == .off ? "Anime4K off" : "Anime4K \(anime4kMode.rawValue)/\(anime4kQuality.rawValue)\(anime4kRestoreOnly ? " restore only" : "")"
        c.query({ c -> (String?, Int64, Int64, Double) in
            (c.string("vo-passes"), c.int("frame-drop-count") ?? 0, c.int("vo-delayed-frame-count") ?? 0, c.double("display-fps") ?? 0)
        }) { [weak self] r in
            guard let self else { return }
            let drops = (r.1, r.2)
            let since = self.lastDrops.map { (drops.0 - $0.dropped, drops.1 - $0.delayed) } ?? drops
            self.lastDrops = (drops.0, drops.1)
            let passes = r.0.flatMap { RenderPasses.summary($0) } ?? (r.0.map { "pass list unreadable: \($0.prefix(120))" } ?? "the renderer gives no pass list")
            dlog("player", "GPU per frame (\(renderer), \(a4k)): \(passes); \(since.0) dropped, \(since.1) late since the last line; display \(Int(r.3.rounded())) Hz")
        }
    }

    // MARK: Seeks and waits (1.23.2)

    /// How long the spinner waits before it shows. A local file is never
    /// waiting for data: a seek is the decoder's work from the keyframe
    /// before (0.14–0.43 s for your library files in the 5 Nov mpv log; the
    /// 0.43 s one waited for the sound to line up), so the spinner shows only
    /// after a second there. 350 ms for anything streamed.
    var spinnerDelay: Double {
        guard let u = (playingItem ?? item).resolvedURL, u.isFileURL else { return 0.35 }
        return 1.0
    }

    private var seekStarted: (at: CFTimeInterval, from: Double)?
    private var waitStarted: CFTimeInterval?

    /// A seek that took long enough to notice, in the log: from where, to
    /// where, how long, local or streamed.
    private func logSeekTime() {
        guard let s = seekStarted else { return }
        seekStarted = nil
        let ms = (CACurrentMediaTime() - s.at) * 1000
        guard ms >= 250, fileLoaded else { return }
        let local = (playingItem ?? item).resolvedURL?.isFileURL == true
        dlog("player", String(format: "seek %@ → %@: playing again after %.0f ms (%@%@)", Self.format(s.from), Self.format(position), ms,
                              local ? "local file" : "streamed", ms >= spinnerDelay * 1000 ? ", spinner shown" : ""))
    }

    /// mpv paused itself for data (paused-for-cache): when, for how long, and
    /// what the cache held, in the log.
    private func logWaitForData(_ waiting: Bool) {
        if waiting {
            guard waitStarted == nil, fileLoaded else { return }
            waitStarted = CACurrentMediaTime()
            client?.query({ c -> String in
                let ahead = c.double("demuxer-cache-duration") ?? 0
                let speed = (c.double("cache-speed") ?? 0) / 1_048_576
                return String(format: "%.1f s buffered ahead, reading %.1f MB/s", ahead, speed)
            }) { [weak self] s in
                guard let self else { return }
                dlog("player", "waiting for data at \(Self.format(self.position)) (\((self.playingItem ?? self.item).resolvedURL?.isFileURL == true ? "local file" : "streamed")): \(s)")
            }
        } else if let t = waitStarted {
            waitStarted = nil
            dlog("player", String(format: "waiting for data over after %.0f ms", (CACurrentMediaTime() - t) * 1000))
        }
    }

    // MARK: Opening a network file (1.23.2)

    private var openTimelineLogged = false
    /// The first picture of a network file: what mpv did to open it, from
    /// its log (OpenTimeline), in the app's log.
    private func logOpenTimelineOnce() {
        guard !openTimelineLogged, let u = (playingItem ?? item).resolvedURL, !u.isFileURL else { return }
        openTimelineLogged = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            guard let s = OpenTimeline.summary(MPVFiles.readText(MPVFiles.logFile)) else { return }
            dlog("player", s)
        }
    }

    // MARK: Intros you watch (1.23.2)

    /// Intro pills hidden for the open file's show, by name (lower-cased):
    /// you watched them through in two episodes without skipping. Some
    /// releases call the episode's first scene, which is the story, the
    /// intro (Classroom of the Elite S3: "Intro" 0:00–2:01, then "Opening").
    @Published private(set) var hiddenIntros: Set<String> = []
    /// Intro pills shown in this file (segment ids): only those count.
    private var introsShown: Set<String> = []
    static let introEpisodesToHide = 2
    private var learnIntrosOn: Bool { defaults.bool(forKey: SettingsKey.skipLearnIntros) }

    static func introName(_ s: SkipSegment) -> String { (s.name ?? s.kind.chapterTitle).lowercased() }

    private func introHidden(_ s: SkipSegment) -> Bool {
        s.kind == .intro && learnIntrosOn && hiddenIntros.contains(Self.introName(s))
    }

    /// Playback went on from `from` to `to`: an intro pill shown in this file
    /// whose end was played through, not skipped or jumped over (a seek moves
    /// more than 3 s at once), counts this episode for its name. Two
    /// episodes since you last skipped it, and it no longer shows for the show.
    private func learnIntros(from: Double, to: Double) {
        guard learnIntrosOn, to > from, to - from < 3, !introsShown.isEmpty, let key = memoryKey(for: memoryItem) else { return }
        for s in segments where s.kind == .intro && introsShown.contains(s.id) && !autoSkipped.contains(s.id) {
            let end = s.end - 1
            guard from < end, to >= end else { continue }
            let name = Self.introName(s), file = memoryItem.id
            var count = 0
            ShowMemoryStore.shared.update(key) { e in
                var watched = e.settings.introWatched ?? [:]
                var eps = watched[name] ?? []
                if !eps.contains(file) { eps.append(file) }
                eps = Array(eps.suffix(5))
                watched[name] = eps
                e.settings.introWatched = watched
                count = eps.count
                if count >= Self.introEpisodesToHide {
                    var hidden = Set(e.settings.introHidden ?? [])
                    hidden.insert(name)
                    e.settings.introHidden = hidden.sorted()
                }
            }
            dlog("skip", "\(key.name): “\(s.label)” watched through, not skipped (\(count) episode(s) since it was last skipped)")
            if count >= Self.introEpisodesToHide, !hiddenIntros.contains(name) {
                hiddenIntros.insert(name)
                showToast("“\(s.label)” won't show for \(key.name) any more")
            }
        }
    }

    /// You skipped an intro: it's one you skip, and the count starts again.
    private func introSkipped(_ s: SkipSegment) {
        guard let key = memoryKey(for: memoryItem) else { return }
        let name = Self.introName(s)
        guard ShowMemoryStore.shared.entry(for: key.keys)?.settings.introWatched?[name]?.isEmpty == false else { return }
        ShowMemoryStore.shared.update(key) { $0.settings.introWatched?[name] = nil }
    }

    /// The player menu's "Show intro pills again".
    func showIntrosAgain() {
        guard let key = memoryKey(for: memoryItem), let e = ShowMemoryStore.shared.entry(for: key.keys) else { return }
        ShowMemoryStore.shared.showIntrosAgain(e.id)
        hiddenIntros = []
        dlog("skip", "\(key.name): intro pills shown again")
        showToast("Skip Intro shows again for \(key.name)")
    }

    private func updateActiveSegment() {
        guard Date() >= skipSuppressedUntil, defaults.bool(forKey: SettingsKey.skipEnabled) else { return }
        let seg = segments.first { position >= $0.start && position < $0.end - 0.5 && !introHidden($0) }
        if seg != activeSegment { activeSegment = seg }
        guard let seg, !autoSkipped.contains(seg.id) else { return }
        if seg.kind == .intro { introsShown.insert(seg.id) }
        let key: String
        switch seg.kind {
        case .intro: key = SettingsKey.skipAutoIntro
        case .outro: key = SettingsKey.skipAutoOutro
        case .recap: key = SettingsKey.skipAutoRecap
        case .preview: key = SettingsKey.skipAutoPreview
        }
        if defaults.bool(forKey: key) || showAutoSkip.contains(seg.kind.rawValue) {
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
            break                       // every frame already goes into PiP's layer
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

    /// OpenGL: PiP's window has a new size. 0.5 s after it settles (never
    /// during PiP's opening animation) the frames become the video's own
    /// size, at most 1080p (PiPFrameSize). Until 1.22.2 they shrank to the
    /// smallest quarter or half of it that covered the window's reported
    /// size: 480×270 for a 1080p episode in a 418×235 window, stretched up
    /// and blurry (4 Nov report).
    private var pipSizeWork: DispatchWorkItem?
    /// Between PiP's willStop and didStop (OpenGL renderer).
    private var pipStopping = false

    private func pipWindowSized(_ size: CMVideoDimensions) {
        guard onLayer, isPiPActive, !pipStopping else { return }
        PiPTrace.event("PiP window renders at \(size.width)×\(size.height)")
        pipSizeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.isPiPActive, !self.pipStopping, self.pendingW > 0, self.pendingH > 0 else { return }
            self.frames?.setPiPSize(PiPFrameSize.pick(videoW: self.pendingW, videoH: self.pendingH))
        }
        pipSizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func stopPiPFeed() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
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
    /// `leaving`: the app is about to leave (willResignActive) and PiP may
    /// start from it; taken whatever the time since the last one.
    private func takeSnapshot(leaving: Bool = false) {
        #if targetEnvironment(simulator)
        return                        // the simulator's Metal driver aborts on readback
        #endif
        guard ownLayerMetal, mode == .main, fileLoaded, !isPiPActive,
              leaving || UIApplication.shared.applicationState == .active, let c = client else { return }
        // The frame only goes to the PiP layer: none with PiP off (it was read
        // back after every seek and pause regardless).
        guard defaults.bool(forKey: SettingsKey.pipEnabled), PiPManager.isSupported else { return }
        guard leaving || Date().timeIntervalSince(lastSnapshot) > 2 else { return }
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
    func labSwitchRenderer(software: Bool) {
        if software { labLayoutPending() }
        software ? switchToSoftware() : switchToMain()
    }

    /// Lab (-avLayoutPending): every view of the player's window waits to be
    /// laid out, as when iOS snapshots the app on the way to the Home Screen.
    func labLayoutPending() {
        guard CommandLine.arguments.contains("-avLayoutPending"), let w = videoContainer?.window else { return }
        var n = 0
        func mark(_ v: UIView) { v.setNeedsLayout(); v.setNeedsUpdateConstraints(); n += 1; v.subviews.forEach(mark) }
        mark(w)
        dlog("av", "layout waiting on \(n) views of the player's window")
    }

    /// Lab: the video view's size changes, so mpv rebuilds its swapchain on
    /// its Metal thread (MoltenVK sets the layer's properties there) while
    /// the view is in the window — as after a rotation or PiP restore.
    func labNudgeVideoSize() {
        guard CommandLine.arguments.contains("-avLayoutPending"), let mv = metalView, mv.superview != nil, let c = videoContainer else { return }
        let shrunk = mv.frame.height < c.bounds.height - 1
        mv.frame = shrunk ? c.bounds : c.bounds.insetBy(dx: 0, dy: 24)
        mv.layoutIfNeeded()
        dlog("av", "video view now \(Int(mv.frame.width))×\(Int(mv.frame.height))")
    }
    /// A/V lab: the decoder rebuild done after coming back while paused.
    func labRenewDecoder() { renewHardwareDecoder() }
    /// Lab: the app away for 3 s while playing (Notification Centre pulled
    /// down), then back — the buffer must still be there.
    func labAwayThenBack() {
        guard let c = client else { return }
        let before = c.double("demuxer-cache-duration") ?? -1
        outputOffForBackground(c)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let c = self.client else { return }
            let away = c.double("demuxer-cache-duration") ?? -1
            self.outputBackAfterAway(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let after = c.double("demuxer-cache-duration") ?? -1
                dlog("av", String(format: "away and back: buffer %.1f s before, %.1f s while away, %.1f s 1 s after (output %@)", before, away, after, c.string("current-vo") ?? "-"))
            }
        }
    }

    /// A/V lab: the "closed PiP from the background, then came back" path,
    /// without PiP or a real background transition.
    func labParkThenReturn() {
        if mode == .sw { sw.detach() }
        labLayoutPending()
        if mode == .main, ownLayerMetal { settleBeforeMetalThreadEnds() }   // vid=no ends mpv's Metal thread
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
    /// OpenGL (1.20.0, SampleBufferRenderer): nothing to switch.
    private func switchToSoftware() {
        guard mode == .main, let c = client else { return }
        if onLayer {
            // Nothing to switch: the frames already go into PiP's layer. Only
            // GPU work, if it was stopped for the background a moment before,
            // and the video track, if the app was away long enough for it to
            // go: PiP showed a still picture with sound (review, 2 Nov).
            awayToken += 1
            if let vid = c.string("vid"), vid != "no" {
                vidSaved = vid
            } else if videoOffForBackground {
                videoOffForBackground = false
                c.set("vid", vidSaved ?? "auto")
            }
            frames?.setRenderingAllowed(true, why: "PiP up")
            return
        }
        outputOffForAway = false            // PiP takes over the output from here
        awayToken += 1
        defer { traceAV("renderer → PiP") }
        if let vid = c.string("vid"), vid != "no" { vidSaved = vid }
        stopPiPFeed()
        snapshotQueue.sync {}
        settleBeforeMetalThreadEnds()   // the output swap below ends mpv's Metal thread
        do {
            sw.setVideoSize(width: Int(videoSize.width), height: Int(videoSize.height))
            try sw.attach(to: c)
            mode = .sw
        } catch {
            mode = .none
            showToast("PiP renderer failed")
        }
        swapOutput(c, to: "libmpv", label: "PiP: video output → CPU")
        if c.string("vid") == "no" { c.set("vid", vidSaved ?? "auto") }
    }

    /// PiP ended: back to the main renderer. Metal: the same output swap the
    /// other way (see switchToSoftware); the CPU renderer is freed once mpv
    /// has let go of it — freeing it while its output is still up makes mpv
    /// take the video track down (vo_libmpv.c: kill_video_async → error_on_track).
    private func switchToMain() {
        guard let c = client else { return }
        defer { traceAV("renderer → main (PiP ended)") }
        if ownLayerMetal, mode == .sw, sw.isAttached, let vid = c.string("vid"), vid != "no" {
            reattachMetalView()
            videoContainer?.layoutIfNeeded(); metalView?.layoutIfNeeded()
            swapOutput(c, to: "gpu-next", label: "PiP ended: video output → Metal")
            mode = .main
            pendingMain = false
            videoOffForBackground = false
            releaseSoftwareRenderer()
            startPiPFeed()
            return
        }
        if mode == .main, ownLayerMetal { settleBeforeMetalThreadEnds() }   // vid=no ends mpv's Metal thread
        c.set("vid", "no")
        if mode == .sw { sw.detach() }
        if let frames {
            frames.setRenderingAllowed(true, why: "back on screen")
        } else {
            reattachMetalView()
            c.set("vo", "gpu-next")
        }
        mode = .main
        pendingMain = false
        videoOffForBackground = false
        c.set("vid", vidSaved ?? "auto")
        startPiPFeed()
    }

    /// Swaps mpv's video output, then puts playback back where you were.
    ///
    /// After a `vo` change mpv seeks to its current playback time (command.c:
    /// queue_seek relative 0, exact), and while video plays that time is the
    /// last frame the output *showed* (playloop.c handle_playback_time:
    /// playback_pts = video_pts). When the old output stalls before it goes —
    /// a Metal layer waits up to a second for a drawable it can't get once its
    /// view is off screen (CAMetalLayer.nextDrawable docs) — that frame falls
    /// behind, and the seek played the last second again (27 Oct report, both
    /// ways). So the position is taken before the swap and moved on by what
    /// can have been heard meanwhile: the swap holds mpv's core, so sound goes
    /// on only until the audio output's buffer runs dry (`audio-buffer`,
    /// 0.2 s by default). The log has the numbers.
    private func swapOutput(_ c: MPVClient, to vo: String, label: String) {
        let video0 = c.double("time-pos")
        let audio0 = c.double("audio-pts")
        let buffer = c.double("audio-buffer") ?? 0.2
        let rate = paused ? 0 : (c.double("speed") ?? speed)
        let t0 = CACurrentMediaTime()
        swapSeekQuietUntil = t0 + 2
        let span = PiPTrace.begin("output swap")
        PiPTrace.event("output swap to \(vo) starts")
        c.set("vo", vo)
        let took = CACurrentMediaTime() - t0
        PiPTrace.end("output swap", span)
        PiPTrace.event("output swap to \(vo) done in \(Int(took * 1000)) ms (mpv held meanwhile)")
        guard let v = video0 ?? audio0, v > 0 else {
            dlog("player", "\(label) in \(Int(took * 1000)) ms (no position; mpv's own seek stands)")
            return
        }
        let target = v + min(took, buffer) * rate
        c.command(["seek", String(format: "%.3f", target), "absolute+exact"])
        dlog("player", String(format: "%@ in %.0f ms; picture at %.2f, sound at %.2f, audio buffer %.2f s → continue at %.2f (track and buffer kept)",
                              label, took * 1000, video0 ?? -1, audio0 ?? -1, buffer, target))
    }

    /// The seek after an output swap (above) is mpv rebuilding its picture
    /// from the buffer, not a wait for the network, so it shows no spinner:
    /// 2 Nov report, a spinner flashed each time Notification Centre was
    /// pulled down and on each PiP start and return. A real stall still
    /// shows one (paused-for-cache). Cleared by the seek's playback-restart.
    private var swapSeekQuietUntil: CFTimeInterval = 0

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
    /// Right before an mpv call that ends mpv's Metal video thread; the main
    /// thread waits in that call until the thread has ended.
    ///
    /// That thread (MoltenVK) changes the video layer, and Core Animation
    /// commits its changes when the thread ends, on that thread, laying out
    /// the layer tree they were made in. Whatever UIKit has waiting to be laid
    /// out in the player's window is then laid out off the main thread and
    /// Auto Layout throws: SIGTRAP on 24 Oct (PiP starting) and 27 Oct (Home
    /// Screen while playing; the stack: thread exit → Core Animation commit →
    /// view layout → Auto Layout exception, the main thread waiting in mpv
    /// for that thread). Taking the view out of the window (1.12.1) didn't
    /// prevent it, and itself left a layout waiting in the window. So: the
    /// view leaves the window, then everything UIKit has waiting is laid out
    /// and drawn now, on the main thread. The thread's commit finds nothing
    /// left to do in UIKit (MainThreadLayout is the safety net).
    private func settleBeforeMetalThreadEnds() {
        let window = metalView?.window ?? videoContainer?.window
        detachMetalView()
        if Self.labOldSwitch { return }
        window?.layer.layoutIfNeeded()
        CATransaction.flush()
    }
    /// Lab: the 1.17.0 steps (view out of the window only).
    private static let labOldSwitch = CommandLine.arguments.contains("-labOldPiPSwitch")

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
        // Coming back from PiP, PiP's layer stays in front until this view has
        // shown a frame of its own (waitForMetalFrame). Until 1.18.0 it was
        // sent behind here, as PiP ended, and the view's old picture (the
        // frame from when PiP started) showed: 29 Oct recording, 8.22–8.29 s.
        if pipLayerInFront { container.bringSubviewToFront(pip.view) } else { container.sendSubviewToBack(pip.view) }
        mv.setNeedsLayout()
        dlog("player", "metal view attached")
        PiPTrace.event("Metal view attached (\(Int(container.bounds.width))×\(Int(container.bounds.height)))")
    }

    /// While PiP hands back to the main renderer, keep the (correctly
    /// sized) PiP layer on top so the restore animation never shows a
    /// stretched or black frame.
    /// Coming back from PiP: PiP's layer (its last frame) stays in front until
    /// the Metal view shows a frame of the video as it is now: the first frame
    /// on screen (the drawable's presented handler) after mpv's
    /// playback-restart, the first frame of the seek that follows the switch.
    /// In the 29 Oct recording the view's first picture after the switch was
    /// an old frame (8.22–8.29 s), 60 ms after the switch and before the
    /// seek's frame, so frames before the restart don't count. 1.17–1.18.0
    /// used playback-restart + 150 ms, which says playback resumed, not that
    /// the output has shown anything. At most 1.5 s.
    private var metalWaitToken = 0
    private var metalWaitRestarted = false
    private func waitForMetalFrame() {
        metalWaitToken += 1
        metalWaitRestarted = false
        let token = metalWaitToken
        let t0 = CACurrentMediaTime()
        metalView?.metalLayer.onPresented = { @Sendable [weak self] shownAt in
            guard shownAt > 0 else { return }
            DispatchQueue.main.async { self?.metalFrameShown(token, ms: Int((shownAt - t0) * 1000)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.metalFrameShown(token, ms: nil) }
    }

    private func metalFrameShown(_ token: Int, ms: Int?) {
        guard token == metalWaitToken else { return }
        if let ms, !metalWaitRestarted {
            PiPTrace.event("Metal frame on screen \(ms) ms after PiP ended, before the seek's first frame: PiP layer stays in front")
            return
        }
        metalWaitToken += 1
        metalView?.metalLayer.onPresented = nil
        PiPTrace.event(ms.map { "Metal view's first frame after the seek on screen \($0) ms after PiP ended" } ?? "no Metal frame after the seek 1.5 s after PiP ended")
        if pipLayerInFront { setPiPLayerOnTop(false) }
    }

    private var pipLayerInFront = false
    private func setPiPLayerOnTop(_ onTop: Bool) {
        guard let container = videoContainer else { return }
        pipLayerInFront = onTop
        if !onTop { metalView?.metalLayer.onPresented = nil }
        if onTop { container.bringSubviewToFront(pip.view) } else { container.sendSubviewToBack(pip.view) }
        PiPTrace.event("PiP layer \(onTop ? "to the front" : "to the back") (its last frame came \(pip.lastFrameAge.map { "\(Int($0 * 1000)) ms ago" } ?? "never"), \(pip.framesEnqueued) frame(s) so far; Metal view \(metalView?.superview != nil ? "in" : "out of") the window)")
    }

    // MARK: App lifecycle

    /// iOS is short of memory (27 Oct: three warnings, then the app was
    /// ended while the next episode loaded). mpv's buffer is the one large
    /// thing here that can give some back: its limit drops to 64 MB ahead
    /// (16 MB behind) for the rest of this player session.
    private var bufferTrimmed = false
    private func memoryWarning() {
        guard !bufferTrimmed, let c = client, !c.isShutDown else { return }
        bufferTrimmed = true
        c.set("demuxer-max-bytes", "64MiB")
        c.set("demuxer-max-back-bytes", "16MiB")
        c.set("prefetch-playlist", "no")          // no second file buffering alongside
        URLCache.shared.removeAllCachedResponses()
        dlog("player/warn", "memory warning: buffer limit now 64 MB ahead, 16 MB behind (\(EnergyMonitor.memory))")
    }

    /// The addon video id of what's playing ("addon:tt…:1:5" history keys).
    private var addonVideoID: String? {
        guard let k = item.historyKey, k.hasPrefix("addon:") else { return nil }
        return String(k.dropFirst("addon:".count))
    }

    /// Subtitle files given to mpv for the file playing (by address).
    private var addedSubtitles: Set<String> = []

    /// Adds subtitle files not given to mpv yet; returns how many.
    @discardableResult
    private func addSubtitles(_ subs: [ExternalSubtitle]) -> Int {
        guard let c = client else { return 0 }
        var n = 0
        for sub in subs where addedSubtitles.insert(sub.url).inserted {
            c.commandAsync(["sub-add", sub.url, "auto", sub.title ?? sub.lang ?? "Addon", sub.lang ?? ""])
            n += 1
        }
        return n
    }

    private func registerLifecycle() {
        let nc = NotificationCenter.default
        // Subtitle addons answering after the stream started: into the playing
        // file when it's that video (before it has loaded, onFileLoaded adds them).
        observers.append(nc.addObserver(forName: AddonPlayback.lateSubtitlesArrived, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["videoId"] as? String, let subs = note.userInfo?["subtitles"] as? [ExternalSubtitle] else { return }
            MainActor.assumeIsolated {
                guard let self, self.fileLoaded, self.addonVideoID == id else { return }
                let n = self.addSubtitles(subs)
                if n > 0 { dlog("player", "late subtitles added to the playing file: \(n)") }
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Control Center only makes the app inactive: what a pull does to the picture (1.22.2).
                self?.traceTransition("app inactive (Control Center, Notification Centre or the app switcher)", seconds: 3)
                self?.aboutToLeave()
            }
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
                switch reason {
                case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
                    self?.routeChanged("route change \(reason.rawValue)")
                default: break
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged("Spatial Audio switched") }
        })
    }

    /// The app is about to leave the screen, and PiP may start from it on its
    /// own. PiP's opening animation shows whatever picture its layer holds,
    /// and that was refreshed only after seeks, pauses and every 45 s: the
    /// 29 Oct recording has PiP open on a shot from several seconds earlier
    /// (2.57–2.94 s) and jump to the current one (2.96 s). A current frame now
    /// goes into the layer first; the switch to PiP's renderer waits for it
    /// (switchToSoftware: snapshotQueue.sync).
    private func aboutToLeave() {
        if onLayer, !isPiPActive {
            // AVKit decides on automatic PiP from the playback state it last
            // read: the current one, and the setting as it is now (1.26.0).
            pipState.paused = paused
            pip.updatePlayback(position: position, rate: paused ? 0 : speed)
            pip.rearmAutoStart(defaults.bool(forKey: SettingsKey.pipAuto))
            return
        }
        guard ownLayerMetal, isPiPPossible, defaults.bool(forKey: SettingsKey.pipAuto), !isPiPActive else { return }
        PiPTrace.event("app about to leave: the PiP layer gets the current frame (its last one came \(pip.lastFrameAge.map { "\(Int($0 * 1000)) ms ago" } ?? "never"))")
        takeSnapshot(leaving: true)
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
    ///
    /// 1.17.2 (Metal): the video *output* goes instead (vo=null), whether
    /// paused or playing — the same swap as PiP, which keeps the track and
    /// its buffer (27 Oct report: pulling down Notification Centre, which
    /// sends the app to the background for a moment, lost the buffer, because
    /// video playing on was switched off at once). Coming back builds the
    /// output again, with a new decoder (iOS ends the VideoToolbox session of
    /// a background app; 1.17.1's decoder rebuild on return, done at the very
    /// moment the app became active, fell back to software decoding for the
    /// rest of the file — same log). Still away after 15 s with sound
    /// playing on, the video track goes off as before, so background
    /// listening doesn't decode video.
    private func didEnterBackground() {
        PiPTrace.event("app in background (PiP \(isPiPActive ? "up" : "not up"))")
        saveHistory(force: true)
        wentToBackground = true
        guard mode == .main, !isPiPActive, let c = client else { return }
        let keepPlaying = defaults.bool(forKey: SettingsKey.backgroundAudio)
        if !keepPlaying { setPaused(true) }
        if ownLayerMetal {
            outputOffForBackground(c)
            return
        }
        // On the layer (OpenGL, Metal on engine 3): no more GPU work, and
        // nothing taken down: coming back goes on drawing (1.28.0 for Metal).
        frames?.setRenderingAllowed(false, why: "app in the background without PiP")
        if keepPlaying {
            if paused {
                parkedPaused = true
                dlog("player", "background while paused: video and buffer kept")
            } else {
                glTrackOffLater()
            }
        }
    }

    /// Sample-buffer renderer, playing on in the background without PiP: the
    /// picture stops at once (no rendering), the video track only after 15 s
    /// away. A quick trip to the Home Screen or the app switcher then comes
    /// back to the same buffer with nothing to reload. Turning the track off
    /// at once made mpv drop its video buffer and read it again on return: a
    /// stutter and a spinner (review, 2 Nov; Metal has waited since 1.17.2).
    private func glTrackOffLater() {
        awayToken += 1
        let token = awayToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.awayToken == token, !self.paused, !self.isPiPActive,
                  UIApplication.shared.applicationState == .background, let c = self.client else { return }
            self.videoOffForPlayback(c)
        }
    }

    /// Metal: no video output while the app is away (see didEnterBackground).
    private var outputOffForAway = false
    private var awayToken = 0

    private func outputOffForBackground(_ c: MPVClient) {
        guard !outputOffForAway, let vid = c.string("vid"), vid != "no" else { return }
        hardwareBeforeAway = !(hwdecCurrent.isEmpty || hwdecCurrent == "no")
        settleBeforeMetalThreadEnds()          // the swap ends mpv's Metal thread
        swapOutput(c, to: "null", label: "background: video output off")
        outputOffForAway = true
        if !paused { trackOffLater() }
    }

    /// Sound playing on in the background: the video track goes off after
    /// 15 s still away (no video decoding for background listening).
    private func trackOffLater() {
        awayToken += 1
        let token = awayToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.awayToken == token, self.outputOffForAway, !self.paused,
                  UIApplication.shared.applicationState == .background, let c = self.client else { return }
            self.outputOffForAway = false
            self.videoOffForPlayback(c)
        }
    }

    /// Back on screen: the video output again, with a new decoder, from the
    /// buffer (swapOutput seeks exactly to where the sound is).
    private func outputBackAfterAway(_ c: MPVClient) {
        outputOffForAway = false
        awayToken += 1
        reattachMetalView()
        videoContainer?.layoutIfNeeded(); metalView?.layoutIfNeeded()
        swapOutput(c, to: "gpu-next", label: "back: video output on")
    }

    /// A new hardware decoder after the app was away while paused (video kept,
    /// 1.16.1). iOS ended the old VideoToolbox session in the meantime: the
    /// 27 Oct mpv log, on Play after coming back, has "Failed to decode frame
    /// (invalid session, -12903)", a restarted session missing its reference
    /// frames ("Could not find ref with POC"), and mpv falling back to
    /// copy-back — sound with a still picture until the next keyframe, 5–6 s.
    /// Changing `hwdec` makes mpv rebuild the decoder and seek exactly to the
    /// frame on screen (command.c, UPDATE_HWDEC: VDCTRL_REINIT, then
    /// queue_seek to video_pts, exact) — from the cache, nothing is
    /// downloaded again. Setting the same value changes nothing
    /// (m_config_set_option_raw only notifies a changed value), so it goes to
    /// another hardware value and straight back (both rebuild a VideoToolbox
    /// session; software decoding is never involved).
    private func renewHardwareDecoder() {
        guard let c = client, fileLoaded, let hw = c.string("hwdec"), hw != "no",
              let vid = c.string("vid"), vid != "no" else { return }
        swapSeekQuietUntil = CACurrentMediaTime() + 2   // its seek is from the buffer too
        c.set("hwdec", hw == "videotoolbox-copy" ? "videotoolbox" : "videotoolbox-copy")
        c.set("hwdec", hw)
        dlog("player", "back while paused: new hardware decoder (\(hw))")
    }

    private func videoOffForPlayback(_ c: MPVClient) {
        guard let vid = c.string("vid"), vid != "no" else { return }
        vidSaved = vid
        videoOffForBackground = true
        if ownLayerMetal { settleBeforeMetalThreadEnds() }   // no video track: mpv ends its video output
        c.set("vid", "no")
        dlog("player", "background playback: video off (15 s away)")
    }

    /// Playback resumed while the app is in the background (Lock Screen,
    /// headphones) after it was left paused: video off now, as if it had
    /// been playing when the app was left.
    private func resumedInBackground() {
        guard UIApplication.shared.applicationState == .background, mode == .main, let c = client else { return }
        if outputOffForAway { trackOffLater(); return }
        guard parkedPaused else { return }
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
        if !isPiPActive, mode == .main, outputOffForAway, let c = client {
            // 1.22.2: the picture and the main thread for 4 s after a trip
            // away (Notification Centre), so a report shows what holds the
            // picture up (4 Nov: "the stutter is back" on Metal).
            traceTransition("coming forward (\(ownLayerMetal ? "Metal: video output back" : onLayer && renderer == .metal ? "Metal (video layer)" : "OpenGL"))")
            outputBackEarly(c)
            return
        }
        if isPiPActive { traceTransition("coming back to the app while PiP plays (return to player: \(defaults.bool(forKey: SettingsKey.pipReturnOnOpen)))") }
        guard isPiPActive, defaults.bool(forKey: SettingsKey.pipReturnOnOpen) else { return }
        PiPTrace.event("stop request 1 (app state \(UIApplication.shared.applicationState == .active ? "active" : UIApplication.shared.applicationState == .inactive ? "inactive" : "background"))")
        dlog("player", "app opened while in PiP: back to the player")
        pipRestoring = true
        returnFromPiP = true
        stopPiP()
    }

    /// Coming back from Notification Centre or the Home Screen (no PiP): the
    /// video output comes back as the app comes forward, not once it's active.
    /// 1 Nov log, Notification Centre at 20:12: "will enter foreground" at
    /// 10.966, active at 11.814, and only then the output swap; the picture
    /// moved again at 12.034, a second after the app started coming back.
    /// Between those, Notification Centre slid up over a still picture, and
    /// the swap's seek came after it was gone (2 Nov report: a stutter and a
    /// spinner each time). Now the swap and its seek run while it slides up.
    /// The app is in the foreground then (inactive, as under Control Centre,
    /// where the Metal view draws on), so the GPU may be used.
    /// If the decoder comes back in software (iOS hadn't let go of its
    /// hardware decoder yet), it's built again once the app is active.
    private var outputBackWhileComing = false
    private func outputBackEarly(_ c: MPVClient) {
        PiPTrace.event("coming forward: video output back now, before the app is active")
        outputBackWhileComing = true
        outputBackAfterAway(c)
    }

    /// Whether the file was on the hardware decoder when the app left: one
    /// VideoToolbox can't decode (AV1 on older chips, MPEG-2) is in software
    /// anyway, and isn't rebuilt on every return (review, 2 Nov).
    private var hardwareBeforeAway = false

    private func checkDecoderAfterEarlyReturn() {
        guard outputBackWhileComing else { return }
        outputBackWhileComing = false
        guard hardwareBeforeAway else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.mode == .main, self.fileLoaded,
                  self.defaults.string(forKey: SettingsKey.hwdec) != "no",
                  self.hwdecCurrent.isEmpty || self.hwdecCurrent == "no" else { return }
            dlog("player/warn", "back early: the decoder came back in software; building it again")
            self.renewHardwareDecoder()
        }
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
        PiPTrace.event("stop request \(attempt + 1) (PiP still up)")
        pipRestoring = true
        stopPiP()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finishReturnFromPiP(attempt: attempt + 1) }
    }

    private func didBecomeActive() {
        PiPTrace.event("app active (PiP \(isPiPActive ? "up" : "not up"), renderer mode \(mode))")
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
        if onLayer {
            awayToken += 1              // back within 15 s: the track never went
            frames?.setRenderingAllowed(true, why: "app active")
        }
        checkDecoderAfterEarlyReturn()
        if outputOffForAway, let c = client {
            outputBackAfterAway(c)
        } else if videoOffForBackground, let c = client {
            videoOffForBackground = false
            parkedPaused = false
            if ownLayerMetal {
                reattachMetalView()
                // The drawable must have the screen's current size before mpv
                // builds its video output (26 Oct mpv log: built at the old
                // landscape size 2868×1320 on a portrait screen).
                videoContainer?.layoutIfNeeded(); metalView?.layoutIfNeeded()
                if c.string("vo") == "null" { c.set("vo", "gpu-next") }   // output went off first (didEnterBackground)
            }
            c.set("vid", vidSaved ?? "auto")
        } else if parkedPaused {
            parkedPaused = false
            if ownLayerMetal { reattachMetalView(); videoContainer?.layoutIfNeeded(); metalView?.layoutIfNeeded() }
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
        audioRoute = AudioRoute.current()
    }

    /// A new route (1.27.0): its channel count asked for, and mpv's audio
    /// output reopened when that changes. mpv opens its output for the route
    /// it starts on, so HDMI or AirPlay to a receiver connected mid-film
    /// stayed stereo until the next file.
    private func routeChanged(_ why: String) {
        updateOutputChannels()
        let now = AudioRoute.current()
        let was = audioRoute
        guard now != was else { return }
        audioRoute = now
        dlog("player", "audio route: \(now.describe) (\(why))")
        guard let was, was.maxChannels != now.maxChannels || was.spatial != now.spatial,
              defaults.bool(forKey: SettingsKey.surroundAudio), let c = client, !closed else { return }
        _ = c.command(["ao-reload"])
        dlog("player", "audio output reopened for the new route")
    }

    /// Spatial Audio switched in the player's panel (1.26.0): applied now,
    /// not at the next session. The switch only wrote the setting.
    func setSurround(_ on: Bool) {
        _ = client?.set("audio-channels", on ? "auto" : "stereo")
        try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(on)
        updateOutputChannels()
        dlog("player", "spatial audio \(on ? "on" : "off") for this session")
    }

    private func updateOutputChannels() {
        guard defaults.bool(forKey: SettingsKey.surroundAudio) else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setPreferredOutputNumberOfChannels(s.maximumOutputNumberOfChannels)
    }

    // MARK: Now Playing / remote commands

    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    /// The picture Control Center and the Lock Screen show (1.23.0): the
    /// title's own art, found as the library's rows find theirs (until
    /// then only the saved frame, which a file not played before doesn't
    /// have: no picture, 5 Nov). Looked up once per file, off the main thread.
    private var nowPlayingArt: (id: String, image: UIImage)?
    private var nowPlayingArtFor: String?
    private var nowPlayingArtTask: Task<Void, Never>?

    private var nowPlayingArtwork: MPMediaItemArtwork? {
        let id = (playingItem ?? item).id
        guard let art = nowPlayingArt, art.id == id else { return nil }
        let img = art.image
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private func findNowPlayingArt(_ it: MediaItem) {
        guard nowPlayingArtFor != it.id else { return }
        nowPlayingArtFor = it.id
        nowPlayingArtTask?.cancel()
        nowPlayingArtTask = Task { [weak self] in
            let found = await NowPlayingArt.find(for: it)
            guard let self, !Task.isCancelled, !self.closed, (self.playingItem ?? self.item).id == it.id else { return }
            guard let found else { dlog("player", "Now Playing: no picture found for \(it.displayTitle)"); return }
            self.nowPlayingArt = (it.id, found.image)
            dlog("player", "Now Playing picture: \(found.source), \(Int(found.image.size.width))×\(Int(found.image.size.height))")
            self.updateNowPlaying()
        }
    }

    private func setUpRemoteCommands() {
        // A player not built on AVPlayer has to ask for remote control events
        // itself to become the Now Playing app (Control Center, the Lock
        // Screen, headphones). Without it Folio could be left out of Control
        // Center (4 Nov report).
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let cc = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            cmd.isEnabled = true
            remoteTargets.append((cmd, cmd.addTarget(handler: handler)))
        }
        add(cc.playCommand) { [weak self] _ in self?.setPaused(false); return .success }
        add(cc.pauseCommand) { [weak self] _ in self?.setPaused(true); return .success }
        add(cc.togglePlayPauseCommand) { [weak self] _ in self?.togglePause(); return .success }
        // Forward and back as in the player (1.25.0: back used the forward
        // step, so the Lock Screen, Control Center and AirPods went back 30 s
        // with Backward skip at 10 s).
        let step = NSNumber(value: max(1, defaults.integer(forKey: SettingsKey.seekStep)))
        let back = NSNumber(value: max(1, defaults.integer(forKey: SettingsKey.seekBackStep)))
        cc.skipForwardCommand.preferredIntervals = [step]
        cc.skipBackwardCommand.preferredIntervals = [back]
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
        let it = playingItem ?? item
        findNowPlayingArt(it)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: it.title.isEmpty ? (mediaTitle.isEmpty ? it.displayTitle : mediaTitle) : it.displayTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let sub = it.subtitle { info[MPMediaItemPropertyArtist] = sub }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if nowPlayingLoggedFor != it.id {
            // 1.22.2: Control Center said "Not Playing" (4 Nov recording) with
            // no trace of why. What iOS goes by: the audio session, and
            // whether another app's sound plays.
            nowPlayingLoggedFor = it.id
            let a = AVAudioSession.sharedInstance()
            let cc = MPRemoteCommandCenter.shared()
            let enabled = [cc.playCommand, cc.pauseCommand, cc.togglePlayPauseCommand, cc.changePlaybackPositionCommand].filter(\.isEnabled).count
            dlog("player", "Now Playing set: audio session \(a.category.rawValue), \(a.mode.rawValue), options \(a.categoryOptions.rawValue), route sharing \(a.routeSharingPolicy.rawValue); other audio playing \(a.isOtherAudioPlaying); output \(a.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")) (\(AudioRoute.current().describe)); \(enabled) of 4 commands on; \(info.count) fields")
        }
    }
    private var nowPlayingLoggedFor: String?

    /// The audio session as mpv's audio output left it, once a file plays
    /// (1.22.7). mpv sets the session itself when its output starts, after
    /// Folio's own setup (ao_audiounit.m), so this is what iOS goes by.
    private func logAudioSessionOnce() {
        let id = (playingItem ?? item).id
        guard audioSessionLoggedFor != id else { return }
        audioSessionLoggedFor = id
        let a = AVAudioSession.sharedInstance()
        let mixes = a.categoryOptions.contains(.mixWithOthers)
        dlog("player", "audio session while playing: \(a.category.rawValue), \(a.mode.rawValue), options \(a.categoryOptions.rawValue)\(mixes ? " (mixes with others: iOS won't make Folio the Now Playing app)" : ""), route sharing \(a.routeSharingPolicy.rawValue)")
    }
    private var audioSessionLoggedFor: String?

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
                // A link found for this episode (an addon's, redirected) may
                // have expired: Try again finds it again (review, 5 Nov).
                if queue.indices.contains(queueIndex), resolvedItems[queueIndex] != nil, queue[queueIndex].url != item.url {
                    resolvedItems[queueIndex] = nil
                }
                // A download address may have expired: Try again goes back to the item's own.
                playLinks[(playingItem ?? item).id] = nil
                diagnose(playingItem ?? item, reason: String(cString: mpv_error_string(error)))
            }
        case .playbackRestart:
            logAudioSessionOnce()
            logOpenTimelineOnce()
            logSeekTime()
            skipLanded()
            buffering = false
            swapSeekQuietUntil = 0
            metalWaitRestarted = true
            PiPTrace.event("mpv: playback restart (first frame after the seek)")
            if ownLayerMetal { scheduleSnapshot(after: 0.8) }
            updateNowPlaying()              // Control Center's time after a seek
        case .videoReconfig:
            PiPTrace.event("mpv: video reconfig")
        case .clientMessage(let args):
            if args.first == "folio-toast", args.count > 1 { showToast(args[1]) }
        case .shutdown:
            // mpv quit by itself: "q" on a hardware keyboard (mpv's default
            // bindings are on and keys are forwarded), `quit` in the console
            // or from a script. The player used to stay up with no mpv behind
            // it. Close it the way its close button does; MPVClient keeps the
            // handle until close() has freed the renderers.
            guard !closed else { break }
            dlog("player", "mpv quit by itself (a quit key, the console or a script): closing the player")
            if let closeScreen { closeScreen() } else { close() }
        case .log, .seek:
            break
        }
    }

    private func handleProperty(_ name: String, _ value: MPVValue) {
        switch name {
        case "time-pos":
            let p = value.double ?? 0
            let before = position
            position = p
            learnIntros(from: before, to: p)
            countWatched(from: before, to: p)
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
            applyDuration(value.double ?? 0)
        case "mute":
            mpvMuted = value.bool ?? false
        case "pause":
            paused = value.bool ?? false
            pipState.paused = paused
            pip.updatePlayback(position: position, rate: paused ? 0 : speed)
            if paused || isPiPActive { pip.invalidate() } else { pip.rearmAutoStart(defaults.bool(forKey: SettingsKey.pipAuto)) }
            updateNowPlaying()
            UIApplication.shared.isIdleTimerDisabled = !paused
            if paused { saveHistory(force: true); scheduleSnapshot(after: 0.3) } else { resumedInBackground() }
        case "paused-for-cache":
            let waiting = value.bool ?? false
            buffering = waiting
            logWaitForData(waiting)
        case "seeking":
            if value.bool == true, CACurrentMediaTime() > swapSeekQuietUntil {
                buffering = true
                if seekStarted == nil { seekStarted = (CACurrentMediaTime(), position) }
            }
        case "eof-reached":
            if value.bool == true { handleEOF() }
            // Left the end (a seek back): Play continues from there. It used
            // to restart the file from 0 (review, 2 Nov).
            else if ended { ended = false }
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
        case "secondary-sid":
            secondarySid = value.string ?? "no"
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
            let software = hwdecCurrent.isEmpty || hwdecCurrent == "no"
            dlog("player", "decoder: \(software ? "software" : hwdecCurrent)")
            if !software { hardwareSeenForFile = true } else { checkCopyFallback() }
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
            // Logged as mpv reports it: a decoder restart reports none for a moment.
            dlog("player", "video gamma: \(value.string.map { $0.isEmpty ? "(empty)" : $0 } ?? "(none)")")
            updateVideoFormat(gamma: value.string ?? "")
        case "audio-out-params/channels":
            audioOut = value.string ?? ""
        case "audio-params/channels":
            let l = value.string
            guard l != audioLayout else { break }
            audioLayout = l
            if let l { updateAudioFilters(because: "audio decoded as \(l)") }
        case "demuxer-cache-duration":
            let v = value.double ?? 0
            if abs(v - clock.cacheAhead) > 1 { clock.cacheAhead = v }
        case "panscan":
            // Only a change publishes: Metal's pinch sets panscan on every
            // frame, and each echo redrew the whole player (review, 9 Nov).
            let fill = (value.double ?? 0) > 0.5
            if fill != zoomToFill { zoomToFill = fill }
            // Fill did nothing on the sample-buffer renderer (review, 2 Nov).
            if onLayer { pip.setFill(zoomToFill) }
            applySubtitleFraming()
        default:
            break
        }
    }

    private func applyVideoSize() {
        let size = CGSize(width: pendingW, height: pendingH)
        if size != videoSize { videoSize = size; refitAnime4K(); applySubtitleFraming() }
        if pendingW > 0, pendingH > 0, ownLayerMetal {
            sw.setVideoSize(width: pendingW, height: pendingH)
        }
        if pendingW > 0, pendingH > 0 { frames?.setVideoSize(pendingW, pendingH) }
    }

    private func handleEOF() {
        saveHistory(force: true)
        // The picker is up for the next episode: wait for the choice.
        if pickRequest != nil { ended = true; return }
        // A stream that ends well before its length: the connection dropped
        // and mpv gave up, which it reports as the end. Said so, with Try
        // again (from where it stopped) and Play next, instead of going on
        // to the next episode or closing as if it had ended (review, 5 Nov).
        let it = playingItem ?? item
        if let u = it.resolvedURL, !u.isFileURL, duration > 120, position < duration - max(30, duration * 0.03) {
            let where_ = serverName(of: it)
            dlog("player", "the stream stopped at \(Self.format(position)) of \(Self.format(duration)): not the end")
            playLinks[it.id] = nil          // Try again: the item's own address, redirected afresh
            show(ServerProblem(kind: .stoppedEarly, title: "The stream stopped at \(Self.format(position)) of \(Self.format(duration))",
                               detail: "The connection to \(where_.name) dropped. Try again to go on from there.", icon: "wifi.exclamationmark"), for: it)
            return
        }
        if playbackMode == "playlist", defaults.bool(forKey: SettingsKey.autoplayNext), hasNext {
            playNext()
        } else {
            // The end: back to where you came from. There was a Replay / Close
            // card; playing it again is a tap on its tile (user request, 4 Nov).
            ended = true
            dlog("player", "end of file: closing the player")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.ended, !self.closed else { return }
                self.closeScreen?()
            }
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
            self.traceTransition("PiP will start (app \(UIApplication.shared.applicationState == .active ? "active" : "not active"); the PiP layer's picture came \(self.pip.lastFrameAge.map { "\(Int($0 * 1000)) ms ago" } ?? "never"))", seconds: 3)
            self.isPiPActive = true
            self.pipRestoring = false
            self.switchToSoftware()
        }
    }

    nonisolated func pipDidStart() { onMain { PiPTrace.event("PiP did start") } }

    nonisolated func pipWillStop() {
        onMain { [weak self] in
            PiPTrace.event("PiP will stop")
            guard let self else { return }
            if self.onLayer {
                // Full-size frames again as the window grows back (at
                // willStop). A size change PiP reports while it closes is
                // ignored (pipWindowSized), so none lands after this.
                self.pipStopping = true
                self.pipSizeWork?.cancel()
                self.frames?.setPiPSize(nil)
            } else {
                self.setPiPLayerOnTop(true)
            }
        }
    }

    nonisolated func pipDidStop() {
        onMain { [weak self] in
            guard let self else { return }
            PiPTrace.event("PiP did stop")
            self.isPiPActive = false
            self.pipStopping = false
            self.returnFromPiP = false
            let state = UIApplication.shared.applicationState
            dlog("player", "pip stopped (app \(state == .active ? "active" : state == .inactive ? "inactive" : "background"), restoring=\(self.pipRestoring))")
            // Only a truly backgrounded app parks the video. `.inactive` is the
            // moment the user is already coming back (switcher, PiP's ✕ while
            // returning): parking there left the picture off with audio on,
            // because the "became active" event that un-parks had already fired.
            if state == .background && !self.pipRestoring {
                if self.mode == .sw { self.sw.detach() }
                self.frames?.setRenderingAllowed(false, why: "PiP closed with the app in the background")
                self.mode = .none
                self.pendingMain = true
                self.client?.set("vid", "no")
                self.setPaused(true)
                self.scheduleParkedCheck()
            } else if self.ownLayerMetal {
                self.waitForMetalFrame()
                self.switchToMain()
            }
            self.pipRestoring = false
        }
    }

    nonisolated func pipFailed(_ error: Error) {
        let message = error.localizedDescription
        onMain { [weak self] in
            guard let self else { return }
            self.isPiPActive = false
            self.pipStopping = false
            self.showToast("PiP failed: \(message)")
            self.setPiPLayerOnTop(false)
            if self.mode == .sw { self.switchToMain() }
            // Failed after the app had already left: as if it left without
            // PiP, so no GPU work goes on in the background (iOS ends apps
            // for that) and Metal's output isn't rebuilt there (review, 9 Nov).
            if UIApplication.shared.applicationState == .background { self.didEnterBackground() }
        }
    }

    nonisolated func pipRestoreUI(_ completion: @escaping (Bool) -> Void) {
        onMain { [weak self] in
            PiPTrace.event("PiP asks to restore the player UI; answered at once")
            self?.pipRestoring = true
        }
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
