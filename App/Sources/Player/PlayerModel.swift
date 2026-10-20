import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine

struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let type: String          // video | audio | sub
    let title: String?
    let lang: String?
    let codec: String?
    let selected: Bool
    let external: Bool
    let isDefault: Bool
    let channels: String?

    var label: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let lang, !lang.isEmpty { parts.append(Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()) }
        if parts.isEmpty { parts.append("Track \(id)") }
        return parts.joined(separator: " · ")
    }
    var detail: String {
        var parts: [String] = []
        if let codec { parts.append(codec.uppercased()) }
        if let channels, !channels.isEmpty { parts.append(channels) }
        if external { parts.append("External") }
        if isDefault { parts.append("Default") }
        return parts.joined(separator: " · ")
    }
}

struct MediaChapter: Identifiable, Hashable {
    let id: Int
    let title: String
    let time: Double
}

@MainActor
final class PlayerModel: ObservableObject {
    // MARK: Published state
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var paused = false
    @Published var buffering = false
    @Published var cacheAhead: Double = 0
    @Published var speed: Double = 1
    @Published var mediaTitle: String = ""
    @Published var tracks: [MediaTrack] = []
    @Published var chapters: [MediaChapter] = []
    @Published var currentChapter: Int = -1
    @Published var aid = "auto"
    @Published var sid = "auto"
    @Published var subDelay: Double = 0
    @Published var audioDelay: Double = 0
    @Published var videoSize: CGSize = .zero
    @Published var hwdecCurrent = ""
    @Published var volume: Double = 100
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

    let queue: [MediaItem]
    var item: MediaItem { queue[queueIndex] }
    var hasNext: Bool { queueIndex + 1 < queue.count }
    var hasPrevious: Bool { queueIndex > 0 }

    let renderView: MPVRenderView
    let pip = PiPManager()
    nonisolated let pipState = PiPStateBox()
    private lazy var sw = MPVSoftwareRenderer(output: pip.makeSink())
    private(set) var client: MPVClient?

    private enum RenderMode { case gl, sw, none }
    private var mode: RenderMode = .none
    private var vidBeforeSwitch: String?
    private var vidBeforeBackground: String?
    private var appActive = true
    private var pendingGL = false
    private var pipRestoring = false
    private var scopedURL: URL?
    private var lastHistorySave = Date.distantPast
    private var autoSkipped: Set<String> = []
    private var segmentsRequested = false
    private var fileLoaded = false
    private var observers: [NSObjectProtocol] = []
    private var toastWork: DispatchWorkItem?
    private var speedBeforeHold: Double = 1
    private var closed = false
    var onClose: (() -> Void)?

    private let defaults = UserDefaults.standard

    init?(queue: [MediaItem], startIndex: Int = 0) {
        guard !queue.isEmpty, let view = MPVRenderView.make() else { return nil }
        self.queue = queue
        self.queueIndex = min(max(0, startIndex), queue.count - 1)
        self.renderView = view
    }

    // MARK: Lifecycle

    func start() {
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

        do {
            try renderView.attach(to: c)
            mode = .gl
        } catch {
            errorMessage = "Video output failed: \(error.localizedDescription)"
        }

        if defaults.bool(forKey: SettingsKey.pipEnabled), PiPManager.isSupported {
            pip.delegate = self
            pip.onPossibleChanged = { [weak self] in self?.isPiPPossible = $0 }
            pip.setUp(autoStart: defaults.bool(forKey: SettingsKey.pipAuto))
            renderView.setPiPFeed(pip.makeSink())
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
        pip.tearDown()
        renderView.setPiPFeed(nil)
        if mode == .sw { sw.detach() }
        renderView.detach()
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
        onClose?()
    }

    private func applyOptions(_ c: MPVClient) {
        c.setOption("vo", "libmpv")
        c.setOption("gpu-api", "opengl")
        c.setOption("opengl-es", "yes")
        switch defaults.string(forKey: SettingsKey.hwdec) ?? "auto" {
        case "copy": c.setOption("hwdec", "videotoolbox-copy")
        case "no": c.setOption("hwdec", "no")
        // The copy fallback is what makes the CPU (PiP) renderer work with
        // hardware decoding: zero-copy interop only exists for OpenGL.
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
        c.observe("sid", .string)
        c.observe("sub-delay", .double)
        c.observe("audio-delay", .double)
        c.observe("dwidth", .int)
        c.observe("dheight", .int)
        c.observe("hwdec-current", .string)
        c.observe("volume", .double)
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
        duration = item.durationHint ?? 0
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
                codec: c.string(p + "codec"), selected: c.flag(p + "selected") ?? false,
                external: c.flag(p + "external") ?? false, isDefault: c.flag(p + "default") ?? false,
                channels: type == "audio" ? c.string(p + "demux-channels") : nil
            ))
        }
        tracks = list
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refreshTracks() }
    }

    func addSubtitle(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        // Copy so mpv can read it after the security scope ends.
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        if scoped { url.stopAccessingSecurityScopedResource() }
        client?.command(["sub-add", dest.path, "select"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshTracks() }
    }

    // MARK: Transport

    func togglePause() {
        if ended { seek(to: 0); client?.set("pause", false); ended = false; return }
        client?.set("pause", !paused)
    }
    func setPaused(_ p: Bool) { client?.set("pause", p) }

    func seek(by seconds: Double) {
        client?.command(["seek", String(seconds), "relative+exact"])
        showToast(seconds >= 0 ? "+\(Int(seconds))s" : "\(Int(seconds))s")
    }

    func seek(to seconds: Double, exact: Bool = true) {
        client?.command(["seek", String(max(0, seconds)), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func setSpeed(_ s: Double) {
        client?.set("speed", s)
    }

    func beginHoldSpeed() {
        guard defaults.bool(forKey: SettingsKey.holdToSpeed), !paused, !holdSpeedActive else { return }
        speedBeforeHold = speed
        holdSpeedActive = true
        setSpeed(defaults.double(forKey: SettingsKey.holdSpeedValue))
    }

    func endHoldSpeed() {
        guard holdSpeedActive else { return }
        holdSpeedActive = false
        setSpeed(speedBeforeHold)
    }

    func setVolume(_ v: Double) { client?.set("volume", min(130, max(0, v))) }
    func setSubDelay(_ v: Double) { client?.set("sub-delay", v) }
    func setAudioDelay(_ v: Double) { client?.set("audio-delay", v) }

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
        let paths = MPVFiles.activeShaderPaths
        client?.set("glsl-shaders", paths.joined(separator: ":"))
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
            let name = item.resolvedURL.map { $0.lastPathComponent.removingPercentEncoding ?? $0.lastPathComponent } ?? item.title
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
                self.showToast("Found \(found.count) skip marker\(found.count == 1 ? "" : "s") (\(found[0].source))")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refreshChapters() }
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

    // MARK: Renderer switching (PiP)

    private func switchToSoftware() {
        guard mode == .gl, let c = client else { return }
        let vid = c.string("vid")
        if let vid, vid != "no" { vidBeforeSwitch = vid }
        renderView.setPiPFeed(nil)
        renderView.detach()
        do {
            sw.setVideoSize(width: Int(videoSize.width), height: Int(videoSize.height))
            try sw.attach(to: c)
            mode = .sw
        } catch {
            mode = .none
            showToast("PiP renderer failed")
        }
        c.set("vid", "no")
        c.set("vid", vidBeforeSwitch ?? "auto")
    }

    private func switchToGL() {
        guard let c = client else { return }
        if mode == .sw { sw.detach() }
        do {
            try renderView.attach(to: c)
            mode = .gl
        } catch {
            mode = .none
            errorMessage = "Video output failed: \(error.localizedDescription)"
            return
        }
        renderView.setRenderingAllowed(true)
        if defaults.bool(forKey: SettingsKey.pipEnabled) {
            renderView.setPiPFeed(pip.makeSink())
        }
        let vid = vidBeforeBackground ?? vidBeforeSwitch ?? "auto"
        vidBeforeBackground = nil
        c.set("vid", "no")
        c.set("vid", vid)
        pendingGL = false
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
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.setPaused(true) }
        })
    }

    private func didEnterBackground() {
        appActive = false
        saveHistory(force: true)
        guard mode == .gl else { return }
        renderView.setRenderingAllowed(false)
        guard !isPiPActive, let c = client else { return }
        if defaults.bool(forKey: SettingsKey.backgroundAudio) {
            let vid = c.string("vid")
            if let vid, vid != "no" {
                vidBeforeBackground = vid
                c.set("vid", "no")
            }
        } else {
            setPaused(true)
        }
    }

    private func didBecomeActive() {
        appActive = true
        if pendingGL {
            switchToGL()
            return
        }
        guard mode == .gl else { return }
        renderView.setRenderingAllowed(true)
        if let vid = vidBeforeBackground, let c = client {
            vidBeforeBackground = nil
            c.set("vid", vid)
        }
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? s.setActive(true)
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
        cc.skipForwardCommand.preferredIntervals = [NSNumber(value: defaults.integer(forKey: SettingsKey.seekStep))]
        cc.skipBackwardCommand.preferredIntervals = [NSNumber(value: defaults.integer(forKey: SettingsKey.seekStep))]
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
            position = value.double ?? 0
            updateActiveSegment()
            pip.updatePlayback(position: position, rate: paused ? 0 : speed)
            saveHistory()
        case "duration":
            duration = value.double ?? 0
            pipState.duration = duration
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
            if paused { saveHistory(force: true) }
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
        case "track-list/count":
            refreshTracks()
        case "chapter-list/count":
            refreshChapters()
        case "chapter":
            currentChapter = Int(value.int ?? -1)
        case "aid":
            aid = value.string ?? "no"
        case "sid":
            sid = value.string ?? "no"
        case "sub-delay":
            subDelay = value.double ?? 0
        case "audio-delay":
            audioDelay = value.double ?? 0
        case "dwidth", "dheight":
            let w = client?.int("dwidth") ?? 0, h = client?.int("dheight") ?? 0
            videoSize = CGSize(width: Int(w), height: Int(h))
            if w > 0, h > 0 {
                renderView.setVideoAspect(Double(w) / Double(h))
                sw.setVideoSize(width: Int(w), height: Int(h))
            }
        case "hwdec-current":
            hwdecCurrent = value.string ?? ""
        case "volume":
            volume = value.double ?? 100
        case "demuxer-cache-duration":
            cacheAhead = value.double ?? 0
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

    nonisolated func pipDidStop() {
        onMain { [weak self] in
            guard let self else { return }
            self.isPiPActive = false
            if UIApplication.shared.applicationState == .background {
                if self.mode == .sw { self.sw.detach() }
                self.mode = .none
                self.pendingGL = true
                if let c = self.client {
                    self.vidBeforeBackground = self.vidBeforeSwitch
                    c.set("vid", "no")
                }
                if !self.pipRestoring { self.setPaused(true) }
            } else {
                self.switchToGL()
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
            if self.mode == .sw { self.switchToGL() }
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
