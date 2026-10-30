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
    /// Extra toolbar width found to be needed (PanelToolbarView.onOverflow).
    @State private var toolbarExtra: CGFloat = 0
    /// A touch that began on the menus' tap catcher is still down.
    @GestureState private var catcherTouched = false
    @AppStorage(SettingsKey.controlsWidth) private var controlsWidth = 0.8
    @ObservedObject private var tune = UITune.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNS
    /// Read once when the player opens: switching path mid-playback would
    /// leave a panel from the other path on screen.
    @State private var nativeMorph = UserDefaults.standard.object(forKey: SettingsKey.nativePanelMorph) as? Bool ?? true

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

                // iOS 26: while a panel is open, a tap anywhere outside it closes
                // it. Under the controls (the panel is part of them), whose other
                // buttons ignore touches while a panel is open, so those taps land here.
                if !legacyPanels && ui.panel != nil {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dlog("ui", "panel: tap outside")
                            ui.closePanel()
                        }
                        .accessibilityHidden(true)
                }

                // Locked, only the lock pill shows (controls(): the rest fades out).
                if ui.controlsVisible {
                    controls(geo, compact: compact).transition(.opacity)
                }

                skipButton(geo)
                upNextCard(geo)

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

                if ui.showConsole {
                    ConsoleBar(model: model, ui: ui).transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // While a panel is open (or opening), every tap outside it lands
                // here and closes it — including where the pill is. The panel
                // itself lets touches through to the player, so this does not
                // depend on how UIKit treats a tap outside a popover.
                //
                // It stays up while the panel's closing morph runs: iOS has not
                // given the pill buttons back yet (sourceItem docs: the popover
                // "replaces the specified item until … dismisses"), so a tap on a
                // button's spot is taken here and opens that panel as soon as the
                // close ends, instead of falling through to the video.
                //
                // It also stays until a touch that began on it ends. A touch that
                // began in the last moments of a close and ended after it was lost:
                // the close ended, this layer went away under the finger, and its
                // tap was cancelled (27 Oct lab touch log: down on this layer 21 ms
                // before "closed", up 44 ms after, no panel opened).
                if legacyPanels && (ui.panel != nil || ui.panelClosing || catcherTouched) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .updating($catcherTouched) { _, touched, _ in touched = true }
                            .onEnded { v in
                            guard hypot(v.translation.width, v.translation.height) < TouchTracker.tapSlop else { return }
                            let point = v.location
                            let spot = ui.pillFrames.first(where: { $0.value.insetBy(dx: -6, dy: -8).contains(point) })?.key
                            if ui.panel != nil {
                                // While a menu is open the buttons are hidden (the
                                // menu morphed out of their glass), so a tap where
                                // one was closes the menu like any tap outside it.
                                // 1.17.1 switched to that button's menu — a menu
                                // you couldn't see the button for (27 Oct report).
                                dlog("ui", "panel: tap outside\(spot.map { " (where the hidden \($0.rawValue) button is)" } ?? "")")
                                ui.closePanel()
                            } else if let kind = spot {
                                dlog("ui", "panel: \(kind.rawValue) tapped while the last panel was closing")
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                ui.toggle(kind)
                            } else {
                                dlog("ui", "panel: tap at (\(Int(point.x)), \(Int(point.y))) while the last panel was closing, on no button (buttons at \(ui.pillFrames.map { "\($0.key.rawValue) \(Int($0.value.minX))–\(Int($0.value.maxX))" }.sorted().joined(separator: ", ")))")
                            }
                        })
                        .accessibilityHidden(true)
                }

                // Above the menus' tap catcher, so it takes taps while a menu is
                // still closing behind it.
                // .id: a new request is a new picker (its stream list loads for that episode).
                if let r = model.pickRequest { pickerCard(r, geo).id(r.id).transition(.opacity.combined(with: .scale(scale: 0.96))) }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.pickRequest)
            .animation(.easeOut(duration: 0.18), value: ui.controlsVisible)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: ui.gestureHUD != nil)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: ui.gestureHUD?.kind)
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: ui.showStats || ui.showInfo)
            .animation(.spring(response: 0.4, dampingFraction: 0.84), value: ui.showTune)
            .animation(.easeOut(duration: 0.18), value: model.toast)
            .animation(.easeOut(duration: 0.18), value: model.holdSpeedActive)
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: model.upNext != nil)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            ui.scheduleHide()
            if TouchTracker.logs {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    for w in UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }) { TouchTracker.install(on: w) }
                }
            }
            guard legacyPanels else { return }          // iOS 26: GlassPanelPill draws the panels
            ui.presentNow = { presentPanel($0, immediate: true) }
            PanelPresenter.shared.onClosing = { [weak ui] closing in if ui?.panelClosing != closing { ui?.panelClosing = closing } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { prewarmPanels() }
        }
        .onChange(of: ui.panel) { _, new in
            guard legacyPanels else { return }
            if let new { presentPanel(new) } else { PanelPresenter.shared.hide() }
        }
        .onDisappear { if legacyPanels { PanelPresenter.shared.reset() } }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // New size after a rotation: build the panels for it ahead of time.
            if legacyPanels { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { prewarmPanels() } }
        }
        .onChange(of: model.paused) { _, paused in
            if paused { ui.showControls(autoHide: false) } else if ui.panel == nil { ui.scheduleHide() }
        }
        // An episode with no stream of the release being watched: the picker
        // is drawn in the player (see pickerCard), and an open menu closes.
        .onChange(of: model.pickRequest) { _, r in if r != nil, ui.panel != nil { ui.closePanel() } }
        .fileImporter(isPresented: $showSubtitlePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.addSubtitle(url: url) }
        }
    }

    /// The stream picker for an episode without the release being watched.
    /// Drawn in the player rather than presented as a sheet: 1.17.0's sheet was
    /// a second presentation from the player while the Now Playing menu (a
    /// popover) was still presented from it, which UIKit doesn't do — one
    /// presented controller per presenter (UIViewController.present docs) —
    /// so it never appeared (27 Oct report).
    private func pickerCard(_ r: PlayerModel.PickRequest, _ geo: GeometryProxy) -> some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.cancelPick() }
            StreamPickerSheet(context: r.context, onPick: { s, addon in model.playPicked(s, from: addon, for: r) },
                              onCancel: { model.cancelPick() })
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: min(560, geo.size.width - 32), maxHeight: geo.size.height * 0.86)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        }
    }

    /// Presents the panel as a system popover from its button (a bar item on
    /// iOS 26, so the button's glass morphs into the panel).
    private func presentPanel(_ kind: PlayerUIState.Panel, immediate: Bool = false) {
        let source: PanelSource
        let sourceView: UIView?
        if let item = ui.barItems[kind], ui.panelBar?.window != nil {
            source = .item(item); sourceView = ui.panelBar
        } else if let anchor = ui.anchors[kind], anchor.window != nil {
            source = .view(anchor); sourceView = anchor
        } else {
            dlog("ui/error", "no source for \(kind.rawValue)")
            ui.panel = nil
            return
        }
        guard let window = sourceView?.window, let root = window.rootViewController else { return }
        // Remember where the pill buttons are (iOS replaces the item while its panel is up).
        for (k, item) in ui.barItems { if let f = item.frame(in: window), f.width > 0 { ui.pillFrames[k] = f } }
        let (width, maxHeight, sizeKey) = panelSize(in: window)
        let content = panelContent(kind, width: width, maxHeight: maxHeight)
        // Any tap outside the panel closes it, including where the pill was
        // (the pill is hidden by iOS while a panel is open); the popover
        // asks the presenter, which closes it itself.
        dlog("ui", "present panel \(kind.rawValue) from \(ui.barItems[kind] != nil && ui.panelBar?.window != nil ? "bar item" : "view") \(Int(width))×≤\(Int(maxHeight))")
        var bottomInset: CGFloat = 8
        if let bar = sourceView {
            let f = bar.convert(bar.bounds, to: window)
            bottomInset = max(8, window.bounds.height - f.minY + 6)
        }
        PanelPresenter.shared.show(kind: kind.rawValue, sizeKey: sizeKey, owner: ObjectIdentifier(model), content: content,
                                   source: source, anchor: sourceView, from: root,
                                   bottomInset: bottomInset, immediate: immediate) { [weak ui] in
            // Closed by a tap outside.
            if ui?.panel == kind { ui?.panel = nil }
            ui?.scheduleHide()
        }
    }

    private func panelSize(in window: UIWindow) -> (CGFloat, CGFloat, String) {
        let size = window.bounds.size
        let compact = size.width < 640
        let width = compact ? min(size.width - 40, 380) : min(tune.panelMax, size.width * tune.panelWidth)
        var maxHeight = max(180, size.height - (compact ? 150 : 84) - window.safeAreaInsets.top - 66)
        // Upright, at most half the screen: 1.17.1 let a menu grow to nearly
        // the whole screen (27 Oct screenshot: Tracks from the close button
        // down to the time bar). A longer list scrolls.
        if size.height > size.width { maxHeight = min(maxHeight, max(300, size.height * 0.5)) }
        return (width, maxHeight, "\(Int(width))x\(Int(maxHeight))")
    }

    private func panelContent(_ kind: PlayerUIState.Panel, width: CGFloat, maxHeight: CGFloat) -> () -> AnyView {
        { [model, ui, onRotationLock] in
            AnyView(PlayerPanel(kind: kind, model: model, ui: ui, width: width, maxHeight: maxHeight,
                                onLoadSubtitle: { showSubtitlePicker = true }, onRotationLock: onRotationLock, bare: true))
        }
    }

    /// Builds the three panels in the background of an idle moment (one per
    /// run-loop turn) so the first tap on each opens straight away.
    private func prewarmPanels(attempt: Int = 0) {
        guard let bar = ui.panelBar, let window = bar.window else {
            if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { prewarmPanels(attempt: attempt + 1) } }
            return
        }
        let (width, maxHeight, sizeKey) = panelSize(in: window)
        for (i, kind) in [PlayerUIState.Panel.tracks, .settings, .nowPlaying].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) {
                guard ui.panel == nil else { return }
                PanelPresenter.shared.prewarm(kind: kind.rawValue, sizeKey: sizeKey, owner: ObjectIdentifier(model),
                                              content: panelContent(kind, width: width, maxHeight: maxHeight))
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ geo: GeometryProxy, compact: Bool) -> some View {
        // Landscape: the controls span `controlsWidth` of the screen (default
        // 80%), centred, ignoring the horizontal safe area. Portrait: 16 pt.
        let fullWidth = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        let side: CGFloat = compact ? 16 : max(20, fullWidth * (1 - min(1, max(0.6, controlsWidth))) / 2)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GlassIcon("xmark", size: 17) { onClose() }
                    .accessibilityLabel("Close player")
                    .opacity(ui.locked ? 0 : 1)
                    .allowsHitTesting(!ui.locked)
                    .accessibilityHidden(ui.locked)
                Spacer()
                // Grows to the left into the pill, so PiP beside it stays put.
                LockControl(locked: ui.locked, onLock: { setLocked(true) }, onUnlock: { setLocked(false) })
                if PiPManager.isSupported && UserDefaults.standard.bool(forKey: SettingsKey.pipEnabled) {
                    GlassIcon(model.isPiPActive ? "pip.exit" : "pip.enter", size: 17) {
                        model.isPiPActive ? model.stopPiP() : model.startPiP()
                    }
                    .opacity(ui.locked ? 0 : model.isPiPPossible || model.isPiPActive ? 1 : 0.35)
                    .disabled(!model.isPiPPossible && !model.isPiPActive)
                    .allowsHitTesting(!ui.locked)
                    .accessibilityHidden(ui.locked)
                    .accessibilityLabel(model.isPiPActive ? "Exit Picture in Picture" : "Picture in Picture")
                }
            }
            .padding(.horizontal, side)
            .padding(.top, geo.safeAreaInsets.top > 0 ? 4 : 14)
            .allowsHitTesting(otherControlsLive)
            Spacer()
            if !ui.locked { bottomControls(geo, compact: compact, side: side).transition(.opacity) }
        }
        .foregroundStyle(.white)
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// Locks or unlocks the controls. Locked: only the lock pill shows (with
    /// the controls: a tap on the video shows it for 4 s); the video's
    /// gestures, Skip and Up Next are off (VideoSurface, skipButton, upNextCard).
    private func setLocked(_ on: Bool) {
        ui.closePanel()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4)) { ui.locked = on }
        ui.showControls()
        dlog("ui", on ? "controls locked" : "controls unlocked")
    }

    @ViewBuilder
    private func bottomControls(_ geo: GeometryProxy, compact: Bool, side: CGFloat) -> some View {
        Group {
            if compact {
                VStack(spacing: 8) {
                    TimeBar(model: model, ui: ui, clock: model.clock).allowsHitTesting(otherControlsLive)
                    HStack {
                        transportPill.allowsHitTesting(otherControlsLive)
                        Spacer()
                        panelPill(geo, compact: compact)
                    }
                }
                .padding(.horizontal, side)
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 6 : 14)
            } else {
                HStack(spacing: 10) {
                    transportPill.allowsHitTesting(otherControlsLive)
                    TimeBar(model: model, ui: ui, clock: model.clock).allowsHitTesting(otherControlsLive)
                    panelPill(geo, compact: compact)
                }
                .padding(.horizontal, side)
                // Clear of the home-indicator strip so taps are never eaten by it.
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 10 : 18)
            }
        }
    }

    private var step: Int { max(1, UserDefaults.standard.integer(forKey: SettingsKey.seekStep)) }
    private var backStep: Int { max(1, UserDefaults.standard.integer(forKey: SettingsKey.seekBackStep)) }
    private func icon(_ s: Int) -> Int { [5, 10, 15, 30, 45, 60, 75, 90].contains(s) ? s : 10 }

    private var transportPill: some View {
        GlassGroup(unionID: "transport", ns: glassNS) {
            PillIcon("gobackward.\(icon(backStep))", size: 18, unionID: "transport", ns: glassNS) { model.seek(by: -Double(backStep)) }
            PillIcon(model.ended ? "arrow.counterclockwise" : (model.paused ? "play.fill" : "pause.fill"), size: 21, unionID: "transport", ns: glassNS) {
                model.togglePause()
                ui.showControls()
            }
            PillIcon("goforward.\(icon(step))", size: 18, unionID: "transport", ns: glassNS) { model.seek(by: Double(step)) }
        }
    }

    /// iOS 26: while a panel is open, the other controls let taps through to
    /// the tap-catcher under them, which closes the panel (as with the popover).
    private var otherControlsLive: Bool { legacyPanels || ui.panel == nil }

    /// The system popover from a UIKit pill (PanelPopover.swift): always before
    /// iOS 26; on iOS 26 when "Native menu morph" is on (its Liquid Glass morph
    /// out of the bar button). Off: SwiftUI glass panels (GlassPanels.swift).
    private var legacyPanels: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return nativeMorph }
        #endif
        return true
    }

    @ViewBuilder
    private func panelPill(_ geo: GeometryProxy, compact: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !legacyPanels {
            GlassPanelPill(model: model, ui: ui, ns: glassNS,
                           width: compact ? max(240, geo.size.width - 40) : min(tune.panelMax, geo.size.width * tune.panelWidth),
                           maxHeight: max(180, geo.size.height - (tune.pillHeight + 26) - 58),
                           onLoadSubtitle: { showSubtitlePicker = true }, onRotationLock: onRotationLock)
        } else if #available(iOS 26.0, *) {
            // Native menu morph: bar items in a toolbar; the popover morphs
            // out of the item's Liquid Glass (as in 1.14.0).
            // Wider (to the left, where the toolbar is empty) whenever its
            // buttons don't all fit; the glass capsule stays where it is.
            PanelToolbarView(ui: ui, onOverflow: {
                guard toolbarExtra < 96 else { return }
                toolbarExtra += 12
                dlog("ui", "player toolbar: its buttons didn't all fit; now \(Int(PanelToolbarView.width + toolbarExtra)) pt wide")
            })
                .frame(width: PanelToolbarView.width + toolbarExtra, height: 50)
                .padding(.leading, -(PanelToolbarView.outside.leading + toolbarExtra))
                .padding(.trailing, -PanelToolbarView.outside.trailing)
        } else {
            PanelPillView(ui: ui, height: tune.pillHeight)
                .frame(width: tune.pillHeight * 3 + 8, height: tune.pillHeight)
        }
        #else
        PanelPillView(ui: ui, height: tune.pillHeight)
            .frame(width: tune.pillHeight * 3 + 8, height: tune.pillHeight)
        #endif
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

    @ViewBuilder
    private func skipButton(_ geo: GeometryProxy) -> some View {
        // The Up Next card replaces the Skip pill while it is up (it covers the
        // same moment: credits / preview at the end of an episode).
        if let seg = model.activeSegment, !ui.locked, ui.panel == nil, model.upNext == nil {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { model.skip(seg) } label: {
                        HStack(spacing: 6) {
                            Text(seg.label)
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

    @ViewBuilder
    private func upNextCard(_ geo: GeometryProxy) -> some View {
        if let next = model.upNext, !ui.locked, ui.panel == nil {
            let fullWidth = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
            let compact = geo.size.width < 640
            let side: CGFloat = compact ? 16 : max(20, fullWidth * (1 - min(1, max(0.6, controlsWidth))) / 2)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    UpNextCard(upNext: next, model: model, clock: model.clock)
                        .frame(maxWidth: 380)
                }
                .padding(.trailing, side)
                .padding(.bottom, ui.controlsVisible ? (compact ? 122 : 74) : 24)
            }
            .ignoresSafeArea(.container, edges: .horizontal)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: ui.controlsVisible)
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
            Text("Details: Settings → Help & Diagnostics").font(.caption).foregroundStyle(.white.opacity(0.5))
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
    /// Called when the finger goes down (a head start for what the tap opens).
    var onPress: (() -> Void)? = nil
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
        if let onPress {
            pressed.onChange(of: configuration.isPressed) { _, down in if down { onPress() } }
        } else {
            pressed      // as before 1.17.4 (menus, player buttons)
        }
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

/// The lock button, and the "Locked" pill it becomes: the pills' glass,
/// height (UITune.pillHeight), capsule shape, caption type and padding.
///
/// One button on one glass capsule that changes size: 44 pt wide and high
/// (a capsule that size is the round button), then the pill's width and
/// height, with the words fading in. It grows to the left, so PiP beside it
/// stays put; a tap mid-way turns it round from where it is (SwiftUI's
/// animations carry on from the current value: "Animations are
/// interruptible", WWDC23 "Explore SwiftUI animation").
///
/// 1.20.0's first take put the round button and the pill in one
/// GlassEffectContainer with the same glassEffectID (Apple, "Applying
/// Liquid Glass to custom views"). The lab recording (run 41080455561, 30
/// Oct) has no morph: the round button at +0.127 s, the whole pill at
/// +0.153 s, while the close button beside it faded over 0.4 s in the same
/// animation.
///
/// Reduce Motion, and systems before iOS 26: the round button and the pill
/// fade into each other.
struct LockControl: View {
    let locked: Bool
    let onLock: () -> Void
    let onUnlock: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var tune = UITune.shared

    var body: some View {
        Group {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                if reduceMotion {
                    fade
                } else {
                    Button(action: locked ? onUnlock : onLock) {
                        face(pill: locked)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .modifier(LockAccessibility(locked: locked))
                }
            } else {
                fade
            }
            #else
            fade
            #endif
        }
        // The pill is a little taller than the round buttons: the row keeps
        // one height either way, so nothing beside it moves.
        .frame(height: max(44, tune.pillHeight))
        .foregroundStyle(.white)
    }

    /// The round button (pill: false) or the pill.
    private func face(pill: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pill ? "lock.fill" : "lock")
                .font(.system(size: pill ? 15 : 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            if pill {
                Text("Locked").font(.caption.weight(.semibold))
                Text("Tap to unlock").font(.caption).foregroundStyle(.white.opacity(0.65))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, pill ? 16 : 0)
        .frame(minWidth: 44)
        .frame(height: pill ? tune.pillHeight : 44)
    }

    @ViewBuilder
    private var fade: some View {
        if locked {
            Button(action: onUnlock) { face(pill: true).glass(cornerRadius: tune.pillHeight / 2, interactive: true) }
                .buttonStyle(PressStyle())
                .modifier(LockAccessibility(locked: true))
                .transition(.opacity)
        } else {
            Button(action: onLock) { face(pill: false).glassCircle() }
                .buttonStyle(PressStyle())
                .modifier(LockAccessibility(locked: false))
                .transition(.opacity)
        }
    }

    private struct LockAccessibility: ViewModifier {
        let locked: Bool
        func body(content: Content) -> some View {
            content.accessibilityElement(children: .ignore)
                .accessibilityLabel(locked ? "Controls locked" : "Lock controls")
                .accessibilityHint(locked ? "Double-tap to unlock" : "")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(locked ? "lockPill" : "lockButton")
        }
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
