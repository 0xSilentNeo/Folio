import SwiftUI

/// Glass panel anchored above the right pill: Settings, Tracks or Now Playing.
struct PlayerPanel: View {
    let kind: PlayerUIState.Panel
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    let size: CGSize
    let safe: EdgeInsets
    let compact: Bool
    let onLoadSubtitle: () -> Void
    let onRotationLock: (Bool) -> Void
    /// Namespace shared with the pill buttons: the panel's glass carries the
    /// same `glassEffectID` as its button, so iOS 26 morphs one into the other.
    var glassNS: Namespace.ID

    @State private var contentHeight: CGFloat = 0
    @MainActor static var lastHeights: [String: CGFloat] = [:]
    @ObservedObject private var tune = UITune.shared

    var body: some View {
        let width = compact ? size.width - 40 : min(tune.panelMax, size.width * tune.panelWidth)
        let bottom = compact ? 128.0 : 70.0
        let maxH = size.height - bottom - max(safe.top, 8) - 52   // keep clear of the close / PiP row
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                let height = min(max(contentHeight > 0 ? contentHeight : (PlayerPanel.lastHeights[kind.rawValue] ?? 260), 120), maxH)
                ScrollView {
                    content.padding(14)
                        .dynamicTypeSize(tune.typeSize)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: HeightKey.self, value: g.size.height)
                        })
                }
                .onPreferenceChange(HeightKey.self) { h in
                    if h > 0 { contentHeight = h; PlayerPanel.lastHeights[kind.rawValue] = h }
                }
                .scrollIndicators(.hidden)
                .frame(width: width, height: height)
                .modifier(PanelGlass(id: kind.rawValue, ns: glassNS))
                .animation(.spring(response: 0.36, dampingFraction: 0.84), value: contentHeight)
                .padding(.trailing, 20)
                .padding(.bottom, bottom)
            }
        }
        .foregroundStyle(.white)
        .ignoresSafeArea(.container, edges: .horizontal)
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

/// Panel background: Liquid Glass carrying the morph id on iOS 26, material otherwise.
struct PanelGlass: ViewModifier {
    let id: String
    let ns: Namespace.ID
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .glassEffectID(id, in: ns)
        } else {
            content.glass(cornerRadius: 24)
        }
        #else
        content.glass(cornerRadius: 24)
        #endif
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

/// Segmented control with a sliding thumb. The thumb is glass while it is
/// moving (tap or drag) and takes the accent colour once it has settled;
/// it can be dragged across like the main tab bar.
struct SegmentPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @State private var moving = false
    @State private var dragX: CGFloat?      // thumb centre while dragging
    @State private var settle: DispatchWorkItem?

    private var index: Int { options.firstIndex { $0.0 == selection } ?? 0 }
    /// Equal segments sized for the longest label (the control keeps an intrinsic width).
    private var segmentWidth: CGFloat {
        let longest = options.map { $0.1.count }.max() ?? 1
        return CGFloat(longest) * 8.6 + 26
    }

    var body: some View {
        let n = max(options.count, 1)
        GeometryReader { g in
            let segW = g.size.width / CGFloat(n)
            let centre = dragX.map { min(max($0, segW / 2), g.size.width - segW / 2) } ?? (segW * (CGFloat(index) + 0.5))
            ZStack(alignment: .leading) {
                Group {
                    if moving {
                        Capsule().fill(.white.opacity(0.12)).glass(cornerRadius: 16)
                    } else {
                        Capsule().fill(Color.accentColor)
                    }
                }
                .frame(width: segW, height: 32)
                .position(x: centre, y: g.size.height / 2)
                .animation(dragX == nil ? .spring(response: 0.32, dampingFraction: 0.78) : nil, value: centre)
                .animation(.easeOut(duration: 0.18), value: moving)
                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                        Text(o.1).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                            .frame(width: segW, height: 32)
                            .contentShape(Rectangle())
                            .onTapGesture { select(i) }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        dragX = v.location.x
                        if !moving { moving = true }
                        let i = min(n - 1, max(0, Int(v.location.x / segW)))
                        if options[i].0 != selection { selection = options[i].0 }
                    }
                    .onEnded { _ in dragX = nil; settleSoon() }
            )
        }
        .frame(maxWidth: segmentWidth * CGFloat(n))
        .frame(height: 32)
        .padding(3)
        .background(.white.opacity(0.12), in: Capsule())
    }

    private func select(_ i: Int) {
        guard options[i].0 != selection else { return }
        moving = true
        selection = options[i].0
        settleSoon()
    }

    private func settleSoon() {
        settle?.cancel()
        let w = DispatchWorkItem { moving = false }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: w)
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
    @AppStorage("screenshotSubs") private var screenshotSubs = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(title: "Playback")
            PanelRow(icon: "gauge.with.dots.needle.67percent", title: "Speed") {
                Stepper3(text: String(format: "%g×", (model.speed * 100).rounded() / 100),
                         minus: { model.setSpeed(max(0.25, model.speed - 0.25)) },
                         plus: { model.setSpeed(min(4, model.speed + 0.25)) })
            }
            PanelRow(icon: "hand.tap", title: "Hold to speed up", subtitle: model.holdEnabled ? "Press and hold the video" : "Off") {
                HStack(spacing: 8) {
                    if model.holdEnabled {
                        ValueMenu(options: [1.5, 2.0, 2.5, 3.0, 4.0].map { ($0, String(format: "%g×", $0)) }, selection: $model.holdSpeed)
                    }
                    Toggle("", isOn: $model.holdEnabled).labelsHidden()
                }
            }
            PanelRow(icon: "rectangle.on.rectangle", title: "Mode") {
                ValueMenu(options: [("playlist", "Playlist"), ("single", "Single"), ("loop", "Loop")], selection: $model.playbackMode)
            }

            PanelHeader(title: "Video")
            PanelRow(icon: "sparkles.tv", title: "Enhanced Quality", subtitle: "Improved scaling and color processing") {
                Toggle("", isOn: $model.enhancedQuality).labelsHidden()
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
                Toggle("", isOn: Binding(get: { model.zoomToFill }, set: { _ in model.toggleZoom() })).labelsHidden()
            }
            if !MPVFiles.shaders().isEmpty {
                PanelRow(icon: "square.stack.3d.up", title: "Your shaders", subtitle: model.activeShaders.isEmpty ? "Off" : "\(model.activeShaders.count) active") {
                    Menu {
                        Button { model.setShaders([]) } label: {
                            if model.activeShaders.isEmpty { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                        }
                        ForEach(MPVFiles.shaders(), id: \.self) { f in
                            let name = f.lastPathComponent
                            Button {
                                var list = model.activeShaders
                                if let i = list.firstIndex(of: name) { list.remove(at: i) } else { list.append(name) }
                                model.setShaders(list)
                            } label: {
                                if model.activeShaders.contains(name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    } label: { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6)).padding(8) }
                    .tint(.white)
                }
            }

            PanelHeader(title: "Audio")
            PanelRow(icon: "person.wave.2", title: "Spatial Audio", subtitle: "Surround output, head-tracked on AirPods") {
                Toggle("", isOn: $spatial).labelsHidden()
            }
            PanelRow(icon: "speaker.wave.3", title: "Boost") {
                ValueMenu(options: [(0, "Off"), (50, "+50%"), (100, "+100%")], selection: $model.audioBoost)
            }
            PanelRow(icon: "timer", title: "Audio delay") {
                Stepper3(text: String(format: "%+.0f ms", model.audioDelay * 1000),
                         minus: { model.setAudioDelay(model.audioDelay - 0.05) }, plus: { model.setAudioDelay(model.audioDelay + 0.05) })
            }

            PanelHeader(title: "Interface")
            PanelRow(icon: "arrow.counterclockwise", title: "Skip interval") {
                SegmentPicker(options: [(5, "5"), (10, "10"), (15, "15"), (30, "30")], selection: $seekStep)
            }
            PanelRow(icon: "rectangle.landscape.rotate", title: "Auto-Rotate", subtitle: ui.rotationLocked ? "Locked" : nil) {
                Toggle("", isOn: Binding(get: { !ui.rotationLocked }, set: { on in
                    ui.rotationLocked = !on
                    onRotationLock(ui.rotationLocked)
                })).labelsHidden()
            }
            PanelRow(icon: "camera.viewfinder", title: "Screenshots") {
                ValueMenu(options: [(true, "With Subtitles"), (false, "Video Only")], selection: $screenshotSubs)
            }
            PanelLink(icon: "lock", title: "Lock controls") { ui.locked = true; ui.closePanel(); ui.showControls() }

            PanelHeader(title: "Subtitles")
            PanelRow(icon: "textformat.size", title: "Size") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { subScale }, set: { subScale = $0; model.setSubScale($0) }), in: 0.6...1.6)
                        .frame(width: 120)
                    RoundButton("arrow.counterclockwise") { subScale = 1; model.setSubScale(1) }
                }
            }
            PanelRow(icon: "arrow.up.and.down.text.horizontal", title: "Position") {
                Stepper3(text: "\(subPos)",
                         minus: { subPos = max(50, subPos - 5); model.run(command: "set sub-pos \(subPos)") },
                         plus: { subPos = min(150, subPos + 5); model.run(command: "set sub-pos \(subPos)") })
            }
            PanelRow(icon: "timer", title: "Delay") {
                Stepper3(text: String(format: "%+.1f s", model.subDelay),
                         minus: { model.setSubDelay(model.subDelay - 0.1) }, plus: { model.setSubDelay(model.subDelay + 0.1) })
            }

            PanelHeader(title: "More")
            PanelLink(icon: "info.circle", title: "Media info") {
                ui.closePanel()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) { ui.showInfo = true }
            }
            PanelLink(icon: "slider.horizontal.below.square.filled.and.square", title: "Tune UI", subtitle: "Sizes and animation, live") {
                ui.closePanel()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) { ui.showTune = true }
            }
            Menu {
                ForEach(ScriptCommandStore.all) { c in Button(c.name) { model.run(command: c.command) } }
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
            Button(action: onLoadSubtitle) {
                Label("Load subtitle file…", systemImage: "folder").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
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
    @State private var tab = 0
    @AppStorage("screenshotSubs") private var screenshotSubs = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOW PLAYING").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.white.opacity(0.55))
            Text(model.item.displayTitle).font(.headline).lineLimit(3)
            HStack(spacing: 10) {
                SegmentPicker(options: [(0, "Playlist"), (1, "Chapters"), (2, "Markers")], selection: $tab)
                Spacer()
                Button {
                    model.run(command: screenshotSubs ? "screenshot subtitles" : "screenshot video")
                    model.showToast("Screenshot saved")
                } label: {
                    Image(systemName: "camera").font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38).background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
            }
            Group {
            switch tab {
            case 0:
                ForEach(Array(model.queue.enumerated()), id: \.offset) { i, item in
                    PlaylistRow(item: item, active: i == model.queueIndex) {
                        model.queueIndex = i
                        model.load(item)
                    }
                }
            case 1:
                if model.chapters.isEmpty { Text("No chapters").foregroundStyle(.white.opacity(0.5)).padding(.vertical, 8) }
                ForEach(model.chapters) { ch in
                    ListRow(icon: "bookmark", title: ch.title, trailing: PlayerModel.format(ch.time), active: ch.id == model.currentChapter) {
                        model.jump(to: ch)
                    }
                }
            default:
                ForEach(model.userMarkers) { m in
                    ListRow(icon: "bookmark.fill", title: m.title, trailing: PlayerModel.format(m.time), active: false) { model.seek(to: m.time) }
                        .contextMenu { Button(role: .destructive) { model.removeMarker(m) } label: { Label("Remove", systemImage: "trash") } }
                }
                Button { model.addMarker() } label: {
                    Label("Add marker at \(PlayerModel.format(model.clock.position))", systemImage: "plus")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                Text("Long-press a marker to remove it.").font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
            }
            .id(tab)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: tab)
        .onAppear { if !model.chapters.isEmpty && model.queue.count <= 1 { tab = 1 } }
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
    }
}

/// Playlist entry with its thumbnail (saved frame, artwork or metadata art).
struct PlaylistRow: View {
    let item: MediaItem
    let active: Bool
    let action: () -> Void
    @StateObject private var thumb = ThumbLoader()
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
                    else { GeneratedArt(seed: item.displayTitle) }
                    if active { Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).shadow(radius: 3) }
                }
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(thumb.meta?.name ?? item.displayTitle).font(.subheadline.weight(active ? .semibold : .regular)).lineLimit(1)
                    if let sub = thumb.meta?.episodeTitle ?? item.subtitle, !sub.isEmpty {
                        Text(sub).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.9) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .onAppear {
            thumb.load(key: item.historyKey ?? item.url, fileURL: item.url.hasPrefix("/") ? URL(fileURLWithPath: item.url) : nil,
                       artwork: item.artwork, lookupName: item.resolvedURL?.lastPathComponent ?? item.title)
        }
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
