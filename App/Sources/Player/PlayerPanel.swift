import SwiftUI

/// Content of a panel popover: Settings, Tracks or Now Playing on a glass
/// card sized to its content (the popover takes its preferred size from it).
struct PlayerPanel: View {
    let kind: PlayerUIState.Panel
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    let width: CGFloat
    let maxHeight: CGFloat
    let onLoadSubtitle: () -> Void
    let onRotationLock: (Bool) -> Void
    /// Drawn on someone else's glass (popover, or the glass panel pill): no glass of its own.
    var bare = false
    /// Receives the content's full height (before any scrolling), so the
    /// glass panel opens at its content's height (GlassPanels.swift).
    var onNaturalHeight: ((CGFloat) -> Void)? = nil

    @ObservedObject private var tune = UITune.shared

    var body: some View {
        Group {
            if kind == .nowPlaying {
                // Fixed height so switching tabs never resizes the panel. The
                // header and tabs stay put; only the list under them scrolls.
                NowPlayingPanelContent(model: model, ui: ui, pinnedHeader: true)
                    .dynamicTypeSize(tune.typeSize)
                    .frame(width: width, height: maxHeight, alignment: .top)
            } else {
                // Sized to its content on the very first layout (the popover reads
                // it before presenting, so it never resizes mid-animation);
                // scrolls only when taller than the screen allows.
                ViewThatFits(in: .vertical) {
                    padded
                    ScrollView { padded }
                }
                .frame(width: width)
                .frame(maxHeight: maxHeight)
            }
        }
        .scrollIndicators(.hidden)
        .background {
            if let onNaturalHeight, kind != .nowPlaying {
                // Ideal height of the unscrolled content (fixedSize proposes no height).
                padded.fixedSize(horizontal: false, vertical: true).hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onNaturalHeight($0) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .modifier(OptionalGlass(enabled: !bare))
        .foregroundStyle(.white)
        .tint(Theme.accent)
        .toggleStyle(BrandSwitchStyle())
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    private var padded: some View {
        content
            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 16)
            .dynamicTypeSize(tune.typeSize)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .settings: SettingsPanelContent(model: model, ui: ui, onRotationLock: onRotationLock)
        case .tracks: TracksPanelContent(model: model, onLoadSubtitle: onLoadSubtitle)
        case .nowPlaying: NowPlayingPanelContent(model: model, ui: ui)
        }
    }
}

struct OptionalGlass: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.glass(cornerRadius: 24) } else { content }
    }
}

// MARK: - Shared rows

struct PanelHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.bold))
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
        }
        .padding(.top, 4)
    }
}

struct PanelRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.55)) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 42)
    }
}

/// A whole-row button with a chevron (navigates or opens something).
struct PanelLink: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let action: () -> Void
    init(icon: String, title: String, subtitle: String? = nil, action: @escaping () -> Void) {
        self.icon = icon; self.title = title; self.subtitle = subtitle; self.action = action
    }
    var body: some View {
        Button(action: action) {
            PanelRow(icon: icon, title: title, subtitle: subtitle) {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6)).padding(8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .foregroundStyle(.white)
    }
}

struct Stepper3: View {
    let text: String
    let minus: () -> Void
    let plus: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            RoundButton("minus", action: minus)
            Text(text).font(.subheadline.monospacedDigit().weight(.medium)).frame(minWidth: 40)
            RoundButton("plus", action: plus)
        }
    }
}

struct RoundButton: View {
    let icon: String
    let action: () -> Void
    init(_ icon: String, action: @escaping () -> Void) { self.icon = icon; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(PressStyle(scale: 0.85))
    }
}

/// Inline value picker (tap to cycle, long-press menu for all options).
struct ValueMenu<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { o in
                Button { selection = o.0 } label: {
                    if selection == o.0 { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.0 == selection }?.1 ?? "").font(.subheadline)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .trailing)   // the whole free part of the row opens the menu
            .contentShape(Rectangle())
        }
        .tint(.white)
    }
}

// MARK: - Settings

struct SettingsPanelContent: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    let onRotationLock: (Bool) -> Void
    @AppStorage(SettingsKey.seekStep) private var seekStep = 10
    @AppStorage(SettingsKey.landscapeOnOpen) private var autoRotate = true
    @AppStorage(SettingsKey.surroundAudio) private var spatial = true
    @AppStorage(SettingsKey.subScale) private var subScale = 1.0
    @AppStorage(SettingsKey.subPos) private var subPos = 100
    @AppStorage(SettingsKey.subFollowZoom) private var subFollowZoom = "auto"
    @AppStorage("screenshotSubs") private var screenshotSubs = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(title: "Playback")
            PanelRow(icon: "gauge.with.dots.needle.67percent", title: "Speed") {
                Stepper3(text: String(format: "%g×", (model.speed * 100).rounded() / 100),
                         minus: { model.chooseSpeed(max(0.25, model.speed - 0.25)) },
                         plus: { model.chooseSpeed(min(4, model.speed + 0.25)) })
            }
            PanelRow(icon: "hand.tap", title: "Hold to speed up", subtitle: model.holdEnabled ? "Press and hold the video" : "Off") {
                HStack(spacing: 8) {
                    if model.holdEnabled {
                        ValueMenu(options: [1.5, 2.0, 2.5, 3.0, 4.0].map { ($0, String(format: "%g×", $0)) }, selection: $model.holdSpeed)
                    }
                    Toggle("Hold to speed up", isOn: $model.holdEnabled).labelsHidden()
                }
            }
            PanelRow(icon: "rectangle.on.rectangle", title: "Mode") {
                ValueMenu(options: [("playlist", "Playlist"), ("single", "Single"), ("loop", "Loop")], selection: $model.playbackMode)
            }

            PanelHeader(title: "Video")
            PanelRow(icon: "sparkles.tv", title: "Picture", subtitle: model.pictureMode.hint) {
                ValueMenu(options: PictureMode.allCases.map { ($0, $0.title) }, selection: $model.pictureMode)
            }
            PanelRow(icon: "wand.and.stars", title: "Anime4K", subtitle: model.anime4kMode.hint) {
                ValueMenu(options: Anime4KMode.allCases.map { ($0, $0.title) }, selection: $model.anime4kMode)
            }
            if model.anime4kMode != .off {
                PanelRow(icon: "dial.medium", title: "Anime4K quality", subtitle: model.anime4kQuality.hint) {
                    ValueMenu(options: Anime4KQuality.allCases.map { ($0, $0.title) }, selection: $model.anime4kQuality)
                }
            }
            PanelRow(icon: "aspectratio", title: "Aspect ratio") {
                ValueMenu(options: [("no", "Auto"), ("16:9", "16:9"), ("4:3", "4:3"), ("2.35:1", "2.35:1"), ("1:1", "1:1")],
                          selection: Binding(get: { model.aspectOverride }, set: { model.setAspect($0) }))
            }
            PanelRow(icon: "arrow.up.left.and.arrow.down.right", title: "Fill screen") {
                Toggle("Fill screen", isOn: Binding(get: { model.zoomToFill }, set: { _ in model.toggleZoom() })).labelsHidden()
            }
            if !MPVFiles.shadersRecent().isEmpty {
                PanelRow(icon: "square.stack.3d.up", title: "Your shaders", subtitle: model.activeShaders.isEmpty ? "Off" : "\(model.activeShaders.count) active") {
                    Menu {
                        Button { model.setShaders([]) } label: {
                            if model.activeShaders.isEmpty { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                        }
                        ForEach(MPVFiles.shadersRecent(), id: \.self) { f in
                            let name = f.lastPathComponent
                            Button {
                                var list = model.activeShaders
                                if let i = list.firstIndex(of: name) { list.remove(at: i) } else { list.append(name) }
                                model.setShaders(list)
                            } label: {
                                if model.activeShaders.contains(name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    } label: { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .tint(.white)
                }
            }

            PanelHeader(title: "Audio")
            PanelRow(icon: "person.wave.2", title: "Spatial Audio", subtitle: "Surround output, head-tracked on AirPods") {
                Toggle("Spatial Audio", isOn: $spatial).labelsHidden()
                    .onChange(of: spatial) { _, on in model.setSurround(on) }
            }
            PanelRow(icon: "speaker.wave.3", title: "Boost") {
                ValueMenu(options: [(0, "Off"), (50, "+50%"), (100, "+100%")], selection: $model.audioBoost)
            }
            // 1.20.3: for this player session (the defaults are in Settings → Audio & Subtitles).
            PanelRow(icon: "moon.zzz", title: "Night mode", subtitle: model.nightMode ? model.audioFilterPlan?.night ?? "On" : "Loud scenes softer") {
                Toggle("Night mode", isOn: $model.nightMode).labelsHidden()
            }
            PanelRow(icon: "quote.bubble", title: "Dialogue boost", subtitle: model.dialogueBoost ? model.audioFilterPlan?.dialogue ?? "On" : "Voices clearer") {
                Toggle("Dialogue boost", isOn: $model.dialogueBoost).labelsHidden()
            }
            PanelRow(icon: "timer", title: "Audio delay") {
                Stepper3(text: String(format: "%+.0f ms", model.audioDelay * 1000),
                         minus: { model.setAudioDelay(model.audioDelay - 0.05) }, plus: { model.setAudioDelay(model.audioDelay + 0.05) })
            }

            PanelHeader(title: "Interface")
            PanelRow(icon: "arrow.counterclockwise", title: "Skip interval") {
                // 60 as Settings has it; the back step follows only when it
                // was the same as this one (review, 5 Nov: it was overwritten,
                // and 60 showed as 5).
                SegmentPicker(options: [(5, "5"), (10, "10"), (15, "15"), (30, "30"), (60, "60")],
                              selection: Binding(get: { seekStep }, set: { new in
                                  let d = UserDefaults.standard
                                  if d.integer(forKey: SettingsKey.seekBackStep) == seekStep { d.set(new, forKey: SettingsKey.seekBackStep) }
                                  seekStep = new
                              }))
                    .frame(width: 200)
            }
            PanelRow(icon: "rectangle.landscape.rotate", title: "Auto-Rotate", subtitle: ui.rotationLocked ? "Locked" : nil) {
                Toggle("Auto-Rotate", isOn: Binding(get: { !ui.rotationLocked }, set: { on in
                    ui.rotationLocked = !on
                    onRotationLock(ui.rotationLocked)
                })).labelsHidden()
            }
            PanelRow(icon: "camera.viewfinder", title: "Screenshots") {
                ValueMenu(options: [(true, "With Subtitles"), (false, "Video Only")], selection: $screenshotSubs)
            }

            PanelHeader(title: "Subtitles")
            PanelRow(icon: "paintpalette", title: "Style", subtitle: model.subtitleStyle.hint) {
                ValueMenu(options: SubtitleStyle.allCases.map { ($0, $0.title) }, selection: $model.subtitleStyle)
            }
            PanelRow(icon: "textformat.size", title: "Size") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { subScale }, set: { subScale = $0; model.setSubScale($0) }), in: 0.6...1.6)
                        .frame(width: 120)
                    RoundButton("arrow.counterclockwise") { subScale = 1; model.setSubScale(1) }
                }
            }
            PanelRow(icon: "arrow.up.and.down.text.horizontal", title: "Position") {
                Stepper3(text: "\(subPos)",
                         minus: { subPos = max(50, subPos - 5); model.setSubPos(subPos) },
                         plus: { subPos = min(150, subPos + 5); model.setSubPos(subPos) })
            }
            PanelRow(icon: "arrow.up.left.and.arrow.down.right", title: "When zoomed",
                     subtitle: subFollowZoom == "manual" ? "Stay as set" : "Keep on screen") {
                ValueMenu(options: [("auto", "Adjust automatically"), ("manual", "Stay as set")],
                          selection: Binding(get: { subFollowZoom }, set: { subFollowZoom = $0; model.applySubtitleFraming() }))
            }
            PanelRow(icon: "timer", title: "Delay") {
                Stepper3(text: String(format: "%+.1f s", model.subDelay),
                         minus: { model.setSubDelay(model.subDelay - 0.1) }, plus: { model.setSubDelay(model.subDelay + 0.1) })
            }

            PanelHeader(title: "More")
            // 1.22.0: openings skipped by themselves for this show only.
            if let show = model.memoryShowName, UserDefaults.standard.bool(forKey: SettingsKey.rememberPerShow) {
                PanelRow(icon: "forward.end", title: "Always skip openings", subtitle: show) {
                    Toggle("Always skip openings", isOn: Binding(get: { model.showAutoSkip.contains(SkipSegment.Kind.intro.rawValue) },
                                             set: { model.setAlwaysSkip(.intro, $0) })).labelsHidden()
                }
            }
            if !model.hiddenIntros.isEmpty, let show = model.memoryShowName {
                // 1.23.2: intro pills you watched through in two episodes.
                Button { model.showIntrosAgain() } label: {
                    PanelRow(icon: "forward.frame", title: "Show Skip Intro again", subtitle: show) { EmptyView() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .foregroundStyle(.white)
            }
            if let show = model.rememberedShow {
                // What's remembered for this show (Settings → Playback → Remember per show).
                Button { model.forgetShow() } label: {
                    PanelRow(icon: "arrow.uturn.backward.circle", title: "Forget this show's settings", subtitle: show) { EmptyView() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .foregroundStyle(.white)
            }
            PanelLink(icon: "info.circle", title: "Media info") {
                ui.closePanel()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) { ui.showInfo = true }
            }
            PanelLink(icon: "slider.horizontal.below.square.filled.and.square", title: "Tune UI", subtitle: "Sizes and animation, live") {
                ui.closePanel()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) { ui.showTune = true }
            }
            Menu {
                ForEach(ScriptCommandStore.recent) { c in Button(c.name) { model.run(command: c.command) } }
                Divider()
                Button { ui.closePanel(); ui.showConsole = true } label: { Label("Run mpv command…", systemImage: "terminal") }
            } label: {
                PanelRow(icon: "command", title: "Commands", subtitle: "Your saved mpv commands") { chevron }
                    .contentShape(Rectangle())
            }
            .tint(.white)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6)).padding(8)
    }
}

// MARK: - Tracks

struct TracksPanelContent: View {
    @ObservedObject var model: PlayerModel
    let onLoadSubtitle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.tracks("video").isEmpty {
                PanelHeader(title: "Video")
                ForEach(model.tracks("video")) { t in
                    TrackRow(title: videoTitle(t), subtitle: t.detail, selected: t.selected) { model.selectTrack("video", id: t.id) }
                }
            }
            PanelHeader(title: "Audio")
            TrackRow(title: "Off", subtitle: nil, selected: !model.tracks("audio").contains { $0.selected }) { model.selectTrack("audio", id: nil) }
            ForEach(model.tracks("audio")) { t in
                TrackRow(title: t.label, subtitle: t.detail, selected: t.selected) { model.selectTrack("audio", id: t.id) }
            }
            PanelHeader(title: "Subtitles")
            TrackRow(title: "Off", subtitle: nil, selected: !model.tracks("sub").contains { $0.selected }) { model.selectTrack("sub", id: nil) }
            ForEach(model.tracks("sub")) { t in
                TrackRow(title: t.label, subtitle: t.detail, selected: t.selected) { model.selectTrack("sub", id: t.id) }
            }
            // 1.22.0: a second language at the top of the picture.
            let others = model.tracks("sub").filter { !$0.selected }
            if model.tracks("sub").count > 1 {
                PanelHeader(title: "Second subtitles (top)")
                TrackRow(title: "Off", subtitle: nil, selected: model.secondarySid == "no") { model.selectSecondSubtitle(id: nil) }
                ForEach(others) { t in
                    TrackRow(title: t.label, subtitle: t.detail, selected: model.secondarySid == String(t.id)) { model.selectSecondSubtitle(id: t.id) }
                }
            }
            Button(action: onLoadSubtitle) {
                Label("Load subtitle file…", systemImage: "folder").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            // 1.20.3: the installed subtitle addons, asked for the title playing (SubtitleSearch).
            Button { model.searchSubtitles() } label: {
                Label("Search subtitles…", systemImage: "magnifyingglass").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("searchSubtitles")
        }
    }

    private func videoTitle(_ t: MediaTrack) -> String {
        if let w = t.width, let h = t.height, w > 0 { return "\(w) × \(h)" }
        return t.label
    }
}

struct TrackRow: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(selected ? .white : .white.opacity(0.75))
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.5)) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }
}

// MARK: - Now playing

struct NowPlayingPanelContent: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    /// The title and tabs stay pinned at the top and only the list scrolls
    /// (until 1.14.1 the whole panel scrolled and the tabs went off screen).
    var pinnedHeader = false
    @State private var tab: Int
    /// Rows' frames in the list (1.26.3): where the marker for the current row goes.
    @State private var rowFrames: [String: CGRect] = [:]
    /// A tab picked by hand stays (1.25.0: otherwise Chapters is chosen once they arrive).
    @State private var picked = false
    @AppStorage("screenshotSubs") private var screenshotSubs = true
    @AppStorage(SettingsKey.playlistNames) private var playlistNames = "episode"

    init(model: PlayerModel, ui: PlayerUIState, pinnedHeader: Bool = false) {
        self.model = model
        self.ui = ui
        self.pinnedHeader = pinnedHeader
        // One file with chapters: open on Chapters.
        _tab = State(initialValue: !model.chapters.isEmpty && model.queue.count <= 1 ? 1 : 0)
    }

    /// The current row's id on a tab: "q<index>" (Playlist), "c<chapter>"
    /// (Chapters). Markers have no current one. (Until 1.19.0 rows were
    /// ids 0, 1, 2… and the list around them was id `tab` — also 0 on the
    /// Playlist tab, so "scroll to episode 1" scrolled to the whole list and
    /// centred it: E05/E06 showed while E01 played, 30 Oct screenshot.)
    static func current(_ model: PlayerModel, tab: Int) -> String? {
        switch tab {
        case 0: return model.queue.indices.contains(model.queueIndex) ? "q\(model.queueIndex)" : nil
        case 1: return model.currentChapter >= 0 ? "c\(model.currentChapter)" : nil
        default: return nil
        }
    }

    var body: some View {
        content
            // A stream's chapters can come after the panel was built (it's
            // kept between openings): one file with chapters opens on them
            // unless a tab was picked by hand (1.25.0).
            .onChange(of: model.chapters.isEmpty) { _, empty in
                if !picked, !empty, model.queue.count <= 1, tab == 0 { tab = 1 }
            }
    }

    private var content: some View {
        Group {
            if pinnedHeader {
                VStack(alignment: .leading, spacing: 12) {
                    header.padding(.horizontal, 16).padding(.top, 22)
                    ScrollViewReader { proxy in
                        ScrollView {
                            list.padding(.horizontal, 16)
                                .coordinateSpace(.named(Self.space))
                                .background(alignment: .topLeading) { marker }
                        }
                        .scrollIndicators(.hidden)
                        // Rows fade out under the tabs and at the bottom edge instead
                        // of being cut by a hard line; at rest none is faded.
                        .contentMargins(.vertical, 14, for: .scrollContent)
                        .mask(edgeFade)
                        .onAppear {
                            // Built (ahead of time, or the glass panel inserted): on the current row.
                            scroll(proxy, animated: false)
                            LibTrace.panel.log("now playing built on \(Self.current(model, tab: tab) ?? "no row") (tab \(tab), item \(model.queueIndex + 1) of \(model.queue.count), chapter \(model.currentChapter))")
                        }
                        // Every opening (1.26.2): the panel is kept between openings,
                        // so onAppear doesn't come again. Without animating, before
                        // it shows; whatever was scrolled to last time doesn't stay.
                        .onReceive(NotificationCenter.default.publisher(for: .playerPanelOpening)) { n in
                            scroll(proxy, animated: false)
                            LibTrace.panel.log("now playing opens on \(Self.current(model, tab: tab) ?? "no row") at \(n.object as? String ?? "glass"), row at \(rowFrames[Self.current(model, tab: tab) ?? ""].map { "y \(Int($0.minY))" } ?? "not laid out") (tab \(tab), item \(model.queueIndex + 1) of \(model.queue.count), chapter \(model.currentChapter))")
                        }
                        .modifier(ScrollOffsetTrace(label: "now playing"))
                        // The marker moves to the new row in this update; scrolled to in the next.
                        .onChange(of: model.queueIndex) { _, _ in DispatchQueue.main.async { scroll(proxy, animated: true) } }
                        .onChange(of: model.currentChapter) { _, _ in DispatchQueue.main.async { scroll(proxy, animated: true) } }
                        .onChange(of: tab) { _, _ in DispatchQueue.main.async { scroll(proxy, animated: false) } }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) { header; list }
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: tab)
    }

    /// The current row, centred so the ones before and after show too (the
    /// panel is about three rows tall). Opening and switching tabs: at once.
    /// The next episode started (Up Next, auto-next) or the chapter moved on:
    /// the list follows, smoothly.
    ///
    /// 1.19.0 lab run: an initial scrollPosition(id:) value left the list at
    /// the top when the panel opened on episode 6 ("opens on q5", the row
    /// not on screen). 1.26.3: scrolled to through `marker` on every opening
    /// (`.playerPanelOpening`), since the panel is built ahead of time and kept.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let key = Self.current(model, tab: tab), rowFrames[key] != nil else { return }
        let id = Self.markerID
        if animated {
            withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    private static let space = "nowPlayingList"
    private static let markerID = "nowPlayingCurrent"

    /// An empty view where the current row is, outside the ForEach, with an id
    /// of its own: what the list scrolls to (1.26.3). An .id() on the row
    /// itself, inside a ForEach with ids of its own, wasn't found on iOS 27
    /// (lab run: scrolled to at every step of opening, even once on screen,
    /// the list never moved), nor was the ForEach's own id; the marker was.
    @ViewBuilder
    private var marker: some View {
        if let key = Self.current(model, tab: tab), let f = rowFrames[key] {
            VStack(spacing: 0) {
                Color.clear.frame(width: 1, height: max(0, f.minY))
                Color.clear.frame(width: 1, height: max(1, f.height)).id(Self.markerID)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOW PLAYING").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.white.opacity(0.55))
            Text(playlistNames == "filename" ? model.item.fileName : model.item.displayTitle)
                .font(playlistNames == "filename" ? .subheadline.weight(.semibold) : .headline).lineLimit(3)
            HStack(spacing: 10) {
                SegmentPicker(options: [(0, "Playlist"), (1, "Chapters"), (2, "Markers")],
                              selection: Binding(get: { tab }, set: { tab = $0; picked = true }))
                    .frame(maxWidth: .infinity)
                Button {
                    model.takeScreenshot(subtitles: screenshotSubs)
                } label: {
                    Image(systemName: "camera").font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38).background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take screenshot")
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tab {
            case 0:
                // Rows known by their file (1.24.1), not their place: when a
                // queue is replaced (adoptQueue) a row at the same place kept
                // the old file's picture and title.
                // 1.26.3: scrolled to through a marker at the row's place (see
                // `marker`), not an .id() on the row.
                ForEach(Array(model.queue.enumerated()), id: \.element.id) { i, item in
                    PlaylistRow(item: item, active: i == model.queueIndex, state: model.episodeStates[i]) {
                        model.playFromPlaylist(i)
                    }
                    .accessibilityIdentifier("q\(i)")
                    .modifier(RowFrame(key: "q\(i)", frames: $rowFrames))
                }
            case 1:
                if model.chapters.isEmpty { Text("No chapters").foregroundStyle(.white.opacity(0.5)).padding(.vertical, 8) }
                ForEach(model.chapters) { ch in
                    ListRow(icon: "bookmark", title: ch.title, trailing: PlayerModel.format(ch.time), active: ch.id == model.currentChapter) {
                        model.jump(to: ch)
                    }
                    .accessibilityIdentifier("c\(ch.id)")
                    .modifier(RowFrame(key: "c\(ch.id)", frames: $rowFrames))
                }
            default:
                ForEach(model.userMarkers) { m in
                    ListRow(icon: "bookmark.fill", title: m.title, trailing: PlayerModel.format(m.time), active: false) { model.seek(to: m.time) }
                        .contextMenu { Button(role: .destructive) { model.removeMarker(m) } label: { Label("Remove", systemImage: "trash") } }
                }
                Button { model.addMarker() } label: {
                    // Follows the clock itself (1.25.0: it kept the time the tab was opened at).
                    AddMarkerLabel(clock: model.clock)
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                Text("Long-press a marker to remove it.").font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("tab\(tab)")
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }
}

struct ListRow: View {
    let icon: String
    let title: String
    let trailing: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 22)
                Text(title).font(.subheadline).lineLimit(2)
                Spacer()
                Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(active ? .white : .white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(active ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Playlist entry with its thumbnail (saved frame, artwork or metadata art).
struct PlaylistRow: View {
    let item: MediaItem
    let active: Bool
    /// Addon seasons: what the season check found (1.17.0).
    var state: PlayerModel.EpisodeState? = nil
    let action: () -> Void
    @StateObject private var thumb = ThumbLoader()
    @AppStorage(SettingsKey.playlistNames) private var names = "episode"

    private var parsed: TitleParser.Parsed { TitleParser.parse(item.fileName) }
    /// "S01E02 · Episode title" (or the full file name, per Settings).
    private var titleLine: String {
        if names == "filename" { return item.fileName }
        let p = parsed
        if let e = p.episode {
            let code = String(format: "S%02dE%02d", p.season ?? 1, e)
            if let t = thumb.meta?.episodeTitle ?? item.subtitle, !t.isEmpty { return "\(code) · \(t)" }
            return "\(code) · \(thumb.meta?.name ?? p.title)"
        }
        return thumb.meta?.name ?? item.displayTitle
    }
    private var subtitleLine: String? {
        if names == "filename" { return nil }
        if parsed.episode != nil { return thumb.meta?.name ?? parsed.title }
        return thumb.meta?.episodeTitle ?? item.subtitle
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    // The memory copy first (1.24.1): a rebuilt row showed generated art for a frame.
                    if let img = thumb.image ?? ThumbLoader.cached(key: item.historyKey ?? item.url, points: 64) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else { GeneratedArt(seed: item.displayTitle) }
                    if active { Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).shadow(radius: 3) }
                }
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleLine).font(.subheadline.weight(active ? .semibold : .regular))
                        .lineLimit(names == "filename" ? 2 : 1)
                    if let sub = subtitleLine, !sub.isEmpty {
                        Text(sub).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    if state == .pick {
                        Text("Other release only · pick a stream").font(.caption2.weight(.semibold)).foregroundStyle(.orange).lineLimit(1)
                    } else if state == .unavailable {
                        Text("Not available from this addon").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.9) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .accessibilityAddTraits(active ? .isSelected : [])
        .task(id: item.id) {
            thumb.load(key: item.historyKey ?? item.url, fileURL: item.url.hasPrefix("/") ? URL(fileURLWithPath: item.url) : nil,
                       artwork: item.artwork, lookupName: item.resolvedURL?.lastPathComponent ?? item.title, points: 64)
        }
    }
}



/// "Add marker at 12:34", following the playback clock (1.25.0).
private struct AddMarkerLabel: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        Label("Add marker at \(PlayerModel.format(clock.position))", systemImage: "plus")
    }
}
