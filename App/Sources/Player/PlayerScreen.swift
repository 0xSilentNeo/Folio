import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Minimal Outplayer-style player chrome: plain white glyphs over soft
/// gradients, native menus for everything else.
struct PlayerScreen: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    var onClose: () -> Void = {}
    var onRotationLock: (Bool) -> Void = { _ in }

    @State private var showSubtitlePicker = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(model: model, ui: ui).ignoresSafeArea()

                if model.isPiPActive {
                    VStack(spacing: 10) {
                        Image(systemName: "pip").font(.system(size: 40, weight: .light))
                        Text("Playing in Picture in Picture").font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .allowsHitTesting(false)
                }

                if (model.buffering || model.isLoading) && model.errorMessage == nil && !(ui.controlsVisible && !ui.locked) {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                }

                if ui.controlsVisible && !ui.locked {
                    PlayerControls(model: model, ui: ui, clock: model.clock, safe: geo.safeAreaInsets,
                                   onClose: onClose, onRotationLock: onRotationLock,
                                   onLoadSubtitle: { showSubtitlePicker = true })
                        .transition(.opacity)
                }

                if ui.locked && ui.controlsVisible { lockedOverlay.transition(.opacity) }

                skipButton(geo)

                if model.holdSpeedActive {
                    VStack {
                        Label(String(format: "%g×", model.holdSpeed), systemImage: "forward.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.top, geo.safeAreaInsets.top + 18)
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if let hud = ui.gestureHUD { GestureHUDView(hud: hud).allowsHitTesting(false) }

                if let toast = model.toast, ui.gestureHUD == nil, !model.holdSpeedActive {
                    VStack {
                        Text(toast).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(.top, geo.safeAreaInsets.top + (ui.controlsVisible ? 64 : 18))
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if let error = model.errorMessage { errorView(error) }
                if model.ended && !model.hasNext && model.errorMessage == nil { endedView }
                if ui.showInfo { InfoCard(model: model, ui: ui).transition(.opacity) }
                if ui.showConsole {
                    ConsoleBar(model: model, ui: ui).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: ui.controlsVisible)
            .animation(.easeOut(duration: 0.18), value: model.toast)
            .animation(.easeOut(duration: 0.18), value: model.holdSpeedActive)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { ui.scheduleHide() }
        .onChange(of: model.paused) { _, paused in
            if paused { ui.showControls(autoHide: false) } else { ui.scheduleHide() }
        }
        .fileImporter(isPresented: $showSubtitlePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.addSubtitle(url: url) }
        }
    }

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            Button {
                ui.locked = false
                ui.showControls()
            } label: {
                Label("Unlock", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.bottom, 36)
        }
    }

    @ViewBuilder
    private func skipButton(_ geo: GeometryProxy) -> some View {
        if let seg = model.activeSegment, !ui.locked {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { model.skip(seg) } label: {
                        HStack(spacing: 6) {
                            Text(seg.kind.label)
                            Image(systemName: "chevron.right.2")
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    }
                }
                .padding(.trailing, max(20, geo.safeAreaInsets.trailing + 8))
                .padding(.bottom, ui.controlsVisible ? 124 : 30)
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: model.activeSegment)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(Theme.accent)
            Text(message).multilineTextAlignment(.center).font(.callout)
            HStack(spacing: 12) {
                Button("Retry") { model.load(model.item) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Close") { onClose() }.buttonStyle(.bordered)
            }
            Text("Details: Settings → mpv → Last playback log").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .padding(22)
        .frame(maxWidth: 400)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
    }

    private var endedView: some View {
        HStack(spacing: 12) {
            Button { model.seek(to: 0); model.setPaused(false); model.ended = false } label: {
                Label("Replay", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            Button("Close") { onClose() }.buttonStyle(.bordered)
        }
        .padding(14)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
        .offset(y: 90)
    }
}

// MARK: - Controls

struct PlayerControls: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    let clock: PlaybackClock
    let safe: EdgeInsets
    let onClose: () -> Void
    let onRotationLock: (Bool) -> Void
    let onLoadSubtitle: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerControls
                Spacer()
                VStack(spacing: 6) {
                    bottomRow
                    TimeBar(model: model, ui: ui, clock: clock)
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, max(14, min(max(safe.leading, safe.trailing), 48)))
            .padding(.top, 4)
            .padding(.bottom, safe.bottom > 0 ? 0 : 8)
        }
        .foregroundStyle(.white)
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .center, spacing: 6) {
            Glyph("xmark", size: 18) { onClose() }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !subtitleLine.isEmpty {
                    Text(subtitleLine).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if PiPManager.isSupported && UserDefaults.standard.bool(forKey: SettingsKey.pipEnabled) {
                Glyph(model.isPiPActive ? "pip.exit" : "pip.enter") {
                    model.isPiPActive ? model.stopPiP() : model.startPiP()
                }
                .opacity(model.isPiPPossible || model.isPiPActive ? 1 : 0.35)
                .disabled(!model.isPiPPossible && !model.isPiPActive)
            }
            AirPlayButton().frame(width: 40, height: 40)
        }
    }

    private var subtitleLine: String {
        var parts: [String] = []
        if let s = model.item.subtitle, !s.isEmpty { parts.append(s) }
        else if let ch = model.chapters.first(where: { $0.id == model.currentChapter }) { parts.append(ch.title) }
        if !model.videoFormat.isEmpty, model.videoFormat != "SDR" { parts.append(model.videoFormat) }
        if let a = model.tracks.first(where: { $0.type == "audio" && $0.selected }),
           a.profile?.localizedCaseInsensitiveContains("atmos") == true {
            parts.append("Atmos")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Center

    private var centerControls: some View {
        HStack(spacing: 52) {
            Glyph("gobackward.\(stepIcon)", size: 28) { model.seek(by: -Double(step)) }
            Glyph(model.ended ? "arrow.counterclockwise" : (model.paused ? "play.fill" : "pause.fill"), size: 44, box: 72) {
                model.togglePause()
                ui.showControls()
            }
            Glyph("goforward.\(stepIcon)", size: 28) { model.seek(by: Double(step)) }
        }
    }

    private var step: Int { max(1, UserDefaults.standard.integer(forKey: SettingsKey.seekStep)) }
    private var stepIcon: Int { [5, 10, 15, 30, 45, 60, 75, 90].contains(step) ? step : 10 }

    // MARK: Bottom

    private var bottomRow: some View {
        HStack(spacing: 4) {
            Glyph("lock.open", size: 17) {
                ui.locked = true
                ui.showControls()
            }
            Glyph(ui.rotationLocked ? "lock.rotation" : "rotate.right", size: 17) {
                ui.rotationLocked.toggle()
                onRotationLock(ui.rotationLocked)
                model.showToast(ui.rotationLocked ? "Rotation locked" : "Rotation unlocked")
            }
            Glyph(model.zoomToFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 16) {
                model.toggleZoom()
            }
            Spacer()
            MenuButton(icon: "captions.bubble", size: 18, ui: ui) {
                PlayerMenus.subtitles(model, onLoad: onLoadSubtitle)
            }
            .frame(width: 44, height: 44)
            MenuButton(icon: "waveform", size: 17, ui: ui) { PlayerMenus.audio(model) }
                .frame(width: 44, height: 44)
            MenuButton(icon: "gauge.with.dots.needle.67percent",
                       text: model.speed == 1 ? nil : String(format: "%g×", (model.speed * 100).rounded() / 100),
                       size: 17, ui: ui) { PlayerMenus.speed(model) }
                .frame(width: 44, height: 44)
            MenuButton(icon: "ellipsis.circle", size: 18, ui: ui) { PlayerMenus.more(model, ui: ui) }
                .frame(width: 44, height: 44)
            if model.hasNext {
                Glyph("forward.end.fill", size: 17) { model.playNext() }
            }
        }
    }
}

/// Liquid Glass progress capsule: times, buffered range, chapter markers
/// (style/colour from SeekBarPrefs), skip segments and your own markers.
/// The only part of the controls that re-renders while playing.
struct TimeBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 12) {
            Text(PlayerModel.format(ui.scrubTime ?? clock.position))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 40, alignment: .leading)
            SeekTrack(model: model, ui: ui, clock: clock)
            Button { ui.showRemaining.toggle() } label: {
                Text(ui.showRemaining ? "-" + PlayerModel.format(max(0, clock.duration - (ui.scrubTime ?? clock.position))) : PlayerModel.format(clock.duration))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .glass(cornerRadius: 23, interactive: true)
    }
}

struct SeekTrack: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @ObservedObject var clock: PlaybackClock
    @ObservedObject private var prefs = SeekBarPrefs.shared
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let d = max(clock.duration, 0.001)
            let shown = ui.scrubTime ?? clock.position
            let frac = min(1, max(0, shown / d))
            let cacheFrac = min(1, max(0, (clock.position + clock.cacheAhead) / d))
            let h: CGFloat = dragging ? 8 : 5
            let chapterTimes = model.chapters.dropFirst().map(\.time).filter { $0 > 0 && $0 < d }

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.22))
                    Rectangle().fill(.white.opacity(0.30)).frame(width: w * cacheFrac)
                    if prefs.showSkipSegments {
                        ForEach(model.segments) { s in
                            Rectangle().fill(Theme.accent.opacity(0.55))
                                .frame(width: max(2, w * (s.end - s.start) / d))
                                .offset(x: w * s.start / d)
                        }
                    }
                    Rectangle().fill(.white).frame(width: w * frac)
                }
                .frame(height: h)
                .mask {
                    if prefs.markerStyle == "segments" && !chapterTimes.isEmpty {
                        SegmentMask(times: chapterTimes, duration: d, gap: 3)
                    } else {
                        Capsule()
                    }
                }

                if prefs.markerStyle == "ticks" {
                    ForEach(chapterTimes, id: \.self) { t in
                        Capsule().fill(prefs.color.opacity(0.9))
                            .frame(width: 2, height: h + 8)
                            .offset(x: w * t / d - 1)
                    }
                } else if prefs.markerStyle == "dots" {
                    ForEach(chapterTimes, id: \.self) { t in
                        Circle().fill(prefs.color)
                            .frame(width: 5, height: 5)
                            .offset(x: w * t / d - 2.5, y: -(h / 2 + 6))
                    }
                }

                ForEach(model.userMarkers) { m in
                    Rectangle().fill(Color.yellow)
                        .frame(width: 7, height: 7)
                        .rotationEffect(.degrees(45))
                        .offset(x: w * min(1, m.time / d) - 3.5, y: -(h / 2 + 7))
                }

                Circle().fill(.white)
                    .frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                    .offset(x: w * frac - (dragging ? 9 : 6))

                if dragging {
                    ScrubBubble(time: shown, chapter: prefs.showChapterTitle ? chapterTitle(at: shown) : nil)
                        .fixedSize()
                        .offset(x: min(max(w * frac - 60, -10), w - 110), y: -46)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 46)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard clock.duration > 0 else { return }
                        if !dragging { dragging = true; ui.scrubbing = true }
                        let t = min(1, max(0, v.location.x / w)) * clock.duration
                        ui.scrubTime = t
                        model.scrub(to: t)
                    }
                    .onEnded { v in
                        if clock.duration > 0 {
                            model.seek(to: min(1, max(0, v.location.x / w)) * clock.duration)
                        }
                        dragging = false
                        ui.scrubbing = false
                        ui.scrubTime = nil
                        ui.scheduleHide()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 46)
    }

    private func chapterTitle(at t: Double) -> String? {
        if let m = model.userMarkers.last(where: { abs($0.time - t) < 3 }) { return m.title }
        return model.chapters.last(where: { $0.time <= t + 0.01 })?.title
    }
}

/// Track split into rounded segments at chapter boundaries.
struct SegmentMask: View {
    let times: [Double]
    let duration: Double
    let gap: CGFloat

    var body: some View {
        GeometryReader { g in
            let edges = [0.0] + times.map { $0 / duration } + [1.0]
            ZStack(alignment: .leading) {
                ForEach(0..<(edges.count - 1), id: \.self) { i in
                    let x0 = g.size.width * edges[i] + (i == 0 ? 0 : gap / 2)
                    let x1 = g.size.width * edges[i + 1] - (i == edges.count - 2 ? 0 : gap / 2)
                    Capsule().frame(width: max(1, x1 - x0)).offset(x: x0)
                }
            }
        }
    }
}

struct ScrubBubble: View {
    let time: Double
    let chapter: String?

    var body: some View {
        VStack(spacing: 2) {
            if let chapter { Text(chapter).font(.caption2.weight(.semibold)).lineLimit(1) }
            Text(PlayerModel.format(time)).font(.caption.monospacedDigit().weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: 220)
        .glass(cornerRadius: 14)
    }
}

// MARK: - Glyphs

struct Glyph: View {
    let icon: String
    var size: CGFloat = 20
    var box: CGFloat = 44
    let action: () -> Void

    init(_ icon: String, size: CGFloat = 20, box: CGFloat = 44, action: @escaping () -> Void) {
        self.icon = icon; self.size = size; self.box = box; self.action = action
    }

    var body: some View {
        Button(action: action) { GlyphLabel(icon, size: size, box: box) }
            .buttonStyle(.plain)
    }
}

struct GlyphLabel: View {
    let icon: String
    var size: CGFloat
    var box: CGFloat

    init(_ icon: String, size: CGFloat = 20, box: CGFloat = 44) {
        self.icon = icon; self.size = size; self.box = box
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: box, height: box)
            .contentShape(Rectangle())
    }
}

struct GestureHUDView: View {
    let hud: PlayerUIState.GestureHUD
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hud.icon).font(.system(size: 24, weight: .semibold))
            Text(hud.text).font(.subheadline.monospacedDigit().weight(.semibold))
            if let p = hud.progress {
                ProgressView(value: min(1, max(0, p))).tint(.white).frame(width: 120)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
