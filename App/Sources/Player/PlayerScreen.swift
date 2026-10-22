import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Player chrome: close / PiP at the top, three Liquid Glass pills at the
/// bottom (transport · progress · panels) and panels that grow out of
/// their buttons. Only `TimeBar` re-renders while a video plays.
struct PlayerScreen: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    var onClose: () -> Void = {}
    var onRotationLock: (Bool) -> Void = { _ in }

    @State private var showSubtitlePicker = false
    @ObservedObject private var tune = UITune.shared
    @Namespace private var glassNS
    /// The open panel popover (UIKit); see PanelPopover.swift.
    @State private var popover: PanelPopoverController?

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 640
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

                if (model.buffering || model.isLoading) && model.errorMessage == nil {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                        .offset(y: ui.controlsVisible && !ui.locked ? -10 : 0)
                }

                if ui.controlsVisible && !ui.locked {
                    controls(geo, compact: compact).transition(.opacity)
                }

                if ui.locked && ui.controlsVisible { lockedOverlay.transition(.opacity) }

                skipButton(geo)

                if model.holdSpeedActive {
                    topPill(Label(String(format: "%g×", model.holdSpeed), systemImage: "forward.fill"), top: geo.safeAreaInsets.top)
                }
                if let hud = ui.gestureHUD, hud.kind == .brightness || hud.kind == .volume {
                    LevelHUD(hud: hud, top: geo.safeAreaInsets.top)
                        .id("levelhud")
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let hud = ui.gestureHUD, hud.kind != .brightness && hud.kind != .volume {
                    GestureHUDView(hud: hud).allowsHitTesting(false)
                        .id("gesturehud")
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if ui.showStats || ui.showInfo {
                    MediaCard(model: model, ui: ui)
                        .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
                }
                if let toast = model.toast, ui.gestureHUD == nil, !model.holdSpeedActive {
                    topPill(Text(toast), top: geo.safeAreaInsets.top + (ui.controlsVisible ? 56 : 0))
                }

                if let error = model.errorMessage { errorView(error) }
                if model.ended && !model.hasNext && model.errorMessage == nil { endedView }

                if ui.showTune {
                    TuneCard(ui: ui).transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
                }
                if ui.showStats || ui.showInfo {
                    MediaCard(model: model, ui: ui)
                        .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
                }
                if let toast = model.toast, ui.gestureHUD == nil, !model.holdSpeedActive {
                    topPill(Text(toast), top: geo.safeAreaInsets.top + (ui.controlsVisible ? 56 : 0))
                }

                if let error = model.errorMessage { errorView(error) }
                if model.ended && !model.hasNext && model.errorMessage == nil { endedView }

                if ui.showTune {
                    TuneCard(ui: ui).transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
                }
                if ui.showStats || ui.showInfo {
                    MediaCard(model: model, ui: ui)
                        .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
                }
                if let toast = model.toast, ui.gestureHUD == nil, !model.holdSpeedActive {
                    topPill(Text(toast), top: geo.safeAreaInsets.top + (ui.controlsVisible ? 56 : 0))
                }

                if let error = model.errorMessage { errorView(error) }
                if model.ended && !model.hasNext && model.errorMessage == nil { endedView }

                if ui.showConsole {
                    ConsoleBar(model: model, ui: ui).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: ui.controlsVisible)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: ui.gestureHUD != nil)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: ui.gestureHUD?.kind)
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: ui.showStats || ui.showInfo)
            .animation(.spring(response: 0.4, dampingFraction: 0.84), value: ui.showTune)
            .animation(.easeOut(duration: 0.18), value: model.toast)
            .animation(.easeOut(duration: 0.18), value: model.holdSpeedActive)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { ui.scheduleHide() }
        .onChange(of: ui.panel) { _, new in
            // Dismiss whatever is up, then present the new one from its button.
            if let p = popover {
                popover = nil
                p.dismiss(animated: true) { if let new { presentPanel(new) } }
            } else if let new {
                presentPanel(new)
            }
        }
        .onChange(of: model.paused) { _, paused in
            if paused { ui.showControls(autoHide: false) } else if ui.panel == nil { ui.scheduleHide() }
        }
        .fileImporter(isPresented: $showSubtitlePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.addSubtitle(url: url) }
        }
    }

    /// Presents the panel as a popover from its pill button (Outplayer's
    /// approach; iOS 26 morphs the popover out of the source view).
    private func presentPanel(_ kind: PlayerUIState.Panel) {
        guard let anchor = ui.anchors[kind], let window = anchor.window, let root = window.rootViewController else {
            dlog("ui/error", "no anchor for \(kind.rawValue)")
            return
        }
        let size = window.bounds.size
        let compact = size.width < 640
        let width = compact ? size.width - 40 : min(tune.panelMax, size.width * tune.panelWidth)
        let maxHeight = size.height - (compact ? 150 : 90) - window.safeAreaInsets.top - 56
        let body = PlayerPanel(kind: kind, model: model, ui: ui, width: width, maxHeight: maxHeight,
                               onLoadSubtitle: { showSubtitlePicker = true }, onRotationLock: onRotationLock)
        let vc = PanelPopoverController(content: AnyView(body), anchor: anchor, passthrough: Array(ui.anchors.values)) {
            // Dismissed by a tap outside.
            if ui.panel == kind { ui.panel = nil }
            popover = nil
            ui.scheduleHide()
        }
        popover = vc
        dlog("ui", "present popover \(kind.rawValue) \(Int(width))×≤\(Int(maxHeight))")
        root.topMostPresented.present(vc, animated: true)
        DispatchQueue.main.async { AnimTracer.trace("popover \(kind.rawValue)", view: vc.view) }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ geo: GeometryProxy, compact: Bool) -> some View {
        // Like Outplayer: the pills span the screen, 20 pt from the physical
        // edges, ignoring the horizontal safe area (the notch sits higher).
        let side: CGFloat = 20
        VStack(spacing: 0) {
            HStack {
                GlassIcon("xmark", size: 17) { onClose() }
                Spacer()
                if PiPManager.isSupported && UserDefaults.standard.bool(forKey: SettingsKey.pipEnabled) {
                    GlassIcon(model.isPiPActive ? "pip.exit" : "pip.enter", size: 17) {
                        model.isPiPActive ? model.stopPiP() : model.startPiP()
                    }
                    .opacity(model.isPiPPossible || model.isPiPActive ? 1 : 0.35)
                    .disabled(!model.isPiPPossible && !model.isPiPActive)
                }
            }
            .padding(.horizontal, side)
            .padding(.top, geo.safeAreaInsets.top > 0 ? 4 : 10)
            Spacer()
            if compact {
                VStack(spacing: 8) {
                    TimeBar(model: model, ui: ui, clock: model.clock)
                    HStack {
                        transportPill
                        Spacer()
                        panelPill
                    }
                }
                .padding(.horizontal, side)
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 4 : 12)
            } else {
                HStack(spacing: 10) {
                    transportPill
                    TimeBar(model: model, ui: ui, clock: model.clock)
                    panelPill
                }
                .padding(.horizontal, side)
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 2 : 12)
            }
        }
        .foregroundStyle(.white)
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    private var step: Int { max(1, UserDefaults.standard.integer(forKey: SettingsKey.seekStep)) }
    private var stepIcon: Int { [5, 10, 15, 30, 45, 60, 75, 90].contains(step) ? step : 10 }

    private var transportPill: some View {
        GlassGroup(unionID: "transport", ns: glassNS) {
            PillIcon("gobackward.\(stepIcon)", size: 18, unionID: "transport", ns: glassNS) { model.seek(by: -Double(step)) }
            PillIcon(model.ended ? "arrow.counterclockwise" : (model.paused ? "play.fill" : "pause.fill"), size: 21, unionID: "transport", ns: glassNS) {
                model.togglePause()
                ui.showControls()
            }
            PillIcon("goforward.\(stepIcon)", size: 18, unionID: "transport", ns: glassNS) { model.seek(by: Double(step)) }
        }
    }

    private var panelPill: some View {
        GlassGroup(unionID: "panels", ns: glassNS) {
            PillIcon("switch.2", size: 17, active: ui.panel == .tracks, unionID: "panels", ns: glassNS, onAnchor: { ui.anchors[.tracks] = $0 }) { ui.toggle(.tracks) }
            PillIcon("slider.horizontal.3", size: 17, active: ui.panel == .settings, unionID: "panels", ns: glassNS, onAnchor: { ui.anchors[.settings] = $0 }) { ui.toggle(.settings) }
            PillIcon("list.bullet", size: 17, active: ui.panel == .nowPlaying, unionID: "panels", ns: glassNS, onAnchor: { ui.anchors[.nowPlaying] = $0 }) { ui.toggle(.nowPlaying) }
        }
    }

    // MARK: Overlays

    private func topPill<V: View>(_ content: V, top: CGFloat) -> some View {
        VStack {
            content
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glass(cornerRadius: 18)
                .padding(.top, top + 14)
            Spacer()
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .transition(.opacity)
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
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glass(cornerRadius: 22, interactive: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.bottom, 36)
        }
    }

    @ViewBuilder
    private func skipButton(_ geo: GeometryProxy) -> some View {
        if let seg = model.activeSegment, !ui.locked, ui.panel == nil {
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
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .glass(cornerRadius: 20, interactive: true)
                        .padding(10)                     // generous hit area; a miss must not reach the video
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .foregroundStyle(.white)
                }
                .padding(.trailing, 10)
                .padding(.bottom, ui.controlsVisible ? (geo.size.width < 640 ? 112 : 58) : 20)
            }
            .ignoresSafeArea(.container, edges: .horizontal)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.activeSegment)
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
            Text("Details: Settings → Advanced → Diagnostics").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .padding(22)
        .frame(maxWidth: 400)
        .glass(cornerRadius: 24)
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
        .glass(cornerRadius: 20)
        .offset(y: 90)
    }
}

// MARK: - Progress pill

struct TimeBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 12) {
            Text(PlayerModel.format(ui.scrubTime ?? clock.position))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 38, alignment: .leading)
            SeekTrack(model: model, ui: ui, clock: clock)
            Button { ui.showRemaining.toggle() } label: {
                Text(ui.showRemaining ? "-" + PlayerModel.format(max(0, clock.duration - (ui.scrubTime ?? clock.position))) : PlayerModel.format(clock.duration))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 38, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: UITune.shared.pillHeight)
        .glass(cornerRadius: UITune.shared.pillHeight / 2, interactive: true)
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
            let h: CGFloat = dragging ? 7 : 4
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
                        Capsule().fill(prefs.color.opacity(0.9)).frame(width: 2, height: h + 8).offset(x: w * t / d - 1)
                    }
                } else if prefs.markerStyle == "dots" {
                    ForEach(chapterTimes, id: \.self) { t in
                        Circle().fill(prefs.color).frame(width: 5, height: 5).offset(x: w * t / d - 2.5, y: -(h / 2 + 6))
                    }
                }
                ForEach(model.userMarkers) { m in
                    Rectangle().fill(Color.yellow).frame(width: 7, height: 7).rotationEffect(.degrees(45))
                        .offset(x: w * min(1, m.time / d) - 3.5, y: -(h / 2 + 7))
                }
                Circle().fill(.white)
                    .frame(width: dragging ? 16 : 10, height: dragging ? 16 : 10)
                    .offset(x: w * frac - (dragging ? 8 : 5))
                if dragging {
                    ScrubBubble(time: shown, chapter: prefs.showChapterTitle ? chapterTitle(at: shown) : nil)
                        .fixedSize()
                        .offset(x: min(max(w * frac - 60, -10), w - 110), y: -54)
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
                        if clock.duration > 0 { model.seek(to: min(1, max(0, v.location.x / w)) * clock.duration) }
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

// MARK: - Buttons

/// Press feedback shared by every control in the player: a quick spring
/// scale with a slight dim, like the system's glass buttons.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct GlassIcon: View {
    let icon: String
    var size: CGFloat = 18
    let action: () -> Void
    init(_ icon: String, size: CGFloat = 18, action: @escaping () -> Void) { self.icon = icon; self.size = size; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.white)
    }
}

/// A row of buttons on one glass capsule.
struct GlassGroup<Content: View>: View {
    let unionID: String
    let ns: Namespace.ID
    @ViewBuilder var content: Content
    init(unionID: String, ns: Namespace.ID, @ViewBuilder content: () -> Content) {
        self.unionID = unionID; self.ns = ns; self.content = content()
    }
    var body: some View {
        let h = UITune.shared.pillHeight
        HStack(spacing: 0) { content }.padding(.horizontal, 4).frame(height: h).glass(cornerRadius: h / 2, interactive: true)
    }
}

struct PillIcon: View {
    let icon: String
    var size: CGFloat = 18
    var active = false
    let unionID: String
    let ns: Namespace.ID
    /// Receives the UIKit view behind the button (popover source).
    var onAnchor: ((UIView) -> Void)? = nil
    let action: () -> Void
    @ObservedObject private var tune = UITune.shared

    init(_ icon: String, size: CGFloat = 18, active: Bool = false, unionID: String, ns: Namespace.ID, onAnchor: ((UIView) -> Void)? = nil, action: @escaping () -> Void) {
        self.icon = icon; self.size = size; self.active = active; self.unionID = unionID; self.ns = ns; self.onAnchor = onAnchor; self.action = action
    }

    var body: some View {
        let h = tune.pillHeight
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: h, height: h)
                .background(active ? Color.white.opacity(0.2) : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.82))
        .foregroundStyle(.white)
        .background { if let onAnchor { AnchorView(onView: onAnchor) } }
    }
}

/// Level indicator in the style of the system volume HUD: a horizontal
/// capsule at the top centre, dark track, white fill, the icon inside the
/// leading end. No text. Scales in and out.
struct LevelHUD: View {
    let hud: PlayerUIState.GestureHUD
    let top: CGFloat

    var body: some View {
        let level = min(1, max(0, hud.progress ?? 0))
        VStack {
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.18)).glass(cornerRadius: 10)
                GeometryReader { g in
                    Capsule().fill(.white).frame(width: max(g.size.height, g.size.width * level))
                        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.9), value: level)
                }
                Image(systemName: hud.icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(level > 0.08 ? Color.black : Color.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, height: 18)
                    .padding(.leading, 1)
            }
            .frame(width: 180, height: 20)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(.top, top + 10)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

/// Centre indicator for seeks: icon, target time and a slim position strip.
/// The video underneath already shows the frame being scrubbed to.
struct GestureHUDView: View {
    let hud: PlayerUIState.GestureHUD
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hud.icon).font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 5) {
                Text(hud.text).font(.caption.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
                if let p = hud.progress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(.white).frame(width: g.size.width * min(1, max(0, p)))
                        }
                    }
                    .frame(width: 110, height: 3)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glass(cornerRadius: 16)
        .animation(.easeOut(duration: 0.12), value: hud.text)
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
