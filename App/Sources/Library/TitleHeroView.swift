import SwiftUI
import CoreMotion

/// Landing page for a library file: backdrop, poster, synopsis, rating, a
/// 3D play button, and the other files of the same title (episodes) in the
/// chosen view style.
struct TitleHeroView: View {
    let group: LibraryGroup
    let file: URL
    @ObservedObject private var local = LocalMediaStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @StateObject private var thumb = ThumbLoader()
    @AppStorage("heroView") private var viewMode = LibraryViewMode.details.rawValue
    @AppStorage(SettingsKey.showRatings) private var showRatings = true
    @AppStorage(SettingsKey.hideSpoilers) private var hideSpoilers = false

    /// Episode synopsis, unless spoilers are hidden and it hasn't been watched
    /// (then the show's own description).
    private func spoilerSafe(_ m: MediaMeta?) -> String? {
        guard let m else { return nil }
        if hideSpoilers, m.episodeOverview != nil, HistoryStore.shared.entry(forURL: file.path)?.isFinished != true { return m.description }
        return m.synopsis
    }
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var season: Int?

    /// A series page (all episodes merged) or a single file.
    init(group: LibraryGroup, focus: URL? = nil) {
        self.group = group
        self.file = focus ?? group.nextUp
    }
    init(file: URL) {
        let g = LibraryOrganizer.groups(LocalMediaStore.shared.files).first { $0.files.contains(file) }
            ?? LibraryGroup(id: file.path, title: TitleParser.clean(file.lastPathComponent), files: [file], isSeries: false, date: .distantPast, size: 0)
        self.init(group: g, focus: file)
    }

    private var parsed: TitleParser.Parsed { TitleParser.parse(file.lastPathComponent) }
    private var meta: MediaMeta? { thumb.meta }
    private var title: String { meta?.name ?? group.title }
    private var entry: HistoryEntry? { history.entry(forURL: file.path) }

    /// Episodes of this title currently in the library (live, so deletions update).
    private var siblings: [URL] {
        let live = local.files.filter { group.files.contains($0) }
        let extra = local.files.filter { f in !group.files.contains(f) && group.isSeries && TitleParser.parse(f.lastPathComponent).title.lowercased() == TitleParser.parse(file.lastPathComponent).title.lowercased() }
        return (live + extra).sorted(by: LibraryOrganizer.episodeOrder)
    }
    private var seasons: [Int] { Array(Set(siblings.compactMap { TitleParser.parse($0.lastPathComponent).season })).sorted() }
    private var shownEpisodes: [URL] {
        guard seasons.count > 1, let season else { return siblings }
        return siblings.filter { TitleParser.parse($0.lastPathComponent).season == season }
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    backdrop(width: geo.size.width, wide: wide)
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 16) {
                            TiltPlayButton(title: entry?.canResume == true ? "Resume" : "Play",
                                           subtitle: entry?.canResume == true ? "from \(PlayerModel.format(entry!.position))" : nil) { play(file) }
                            if entry?.canResume == true {
                                Button { restart() } label: {
                                    Label("Start over", systemImage: "arrow.counterclockwise").font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 16).frame(height: 44).glass(cornerRadius: 22, interactive: true)
                                }
                                .buttonStyle(PressStyle())
                            }
                        }
                        if let s = spoilerSafe(meta), !s.isEmpty {
                            ExpandableText(text: s, lines: 3)
                        }
                        if let g = meta?.genres, !g.isEmpty {
                            Text(g.prefix(5).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                        }
                        fileFacts
                        if siblings.count > 1 { episodes }
                    }
                    .padding(.horizontal, wide ? 28 : 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
        }
        .background(HomeBackdrop().ignoresSafeArea())
        .background(BackSwipeProbe().frame(width: 1, height: 1))
        // The system navigation bar (transparent): its own Back button and the
        // native back swipe that follows your finger.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { moreButton } }
        .onAppear {
            dlog("nav", "title page appear \(file.lastPathComponent)")
            thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, preferMeta: true)
        }
        .onDisappear { dlog("nav", "title page disappear \(file.lastPathComponent)") }
        .confirmationDialog("Delete this file from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { local.delete(file); dismiss() }
        }
    }

    // MARK: Pieces

    private func backdrop(width: CGFloat, wide: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(height: wide ? 360 : width * 9 / 16 + 40)
                .overlay {
                    if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
                    else { GeneratedArt(seed: title) }
                }
                .clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.25), .clear, Theme.background.opacity(0.9), Theme.background],
                                        startPoint: .top, endPoint: .bottom))
            HStack(alignment: .bottom, spacing: 14) {
                if let poster = meta?.poster, let u = URL(string: poster) {
                    CachedImage(url: u, maxPixel: 400) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(width: 96, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                }
                titleBlock.padding(.bottom, 6)
            }
            .padding(.leading, wide ? 28 : 20)
            .padding(.trailing, 20)
            .offset(y: 40)
        }
        .padding(.bottom, 44)
    }

    private var isAnime: Bool { meta?.genres?.contains { $0.localizedCaseInsensitiveContains("anim") } ?? false }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            DecipherText(text: title, font: .system(size: 28, weight: .bold, design: .rounded)).lineLimit(2)
            // Anime: the show's own (romaji) title; otherwise the episode name.
            if isAnime, let o = meta?.originalName, !o.isEmpty {
                Text(o).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            } else if let ep = meta?.episodeTitle ?? episodeLabel {
                Text(ep).font(.headline).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 8) {
                if showRatings, let r = meta?.rating { chip("★ \(r)", strong: true) }
                if let y = meta?.year ?? parsed.year.map(String.init) { chip(y) }
                if let res = parsed.resolution { chip(res) }
                chip(file.pathExtension.uppercased())
                if let e = entry, e.isFinished { chip("Watched") }
            }
        }
    }

    private var episodeLabel: String? {
        guard let e = parsed.episode else { return nil }
        return "Season \(parsed.season ?? 1) · Episode \(e)"
    }

    private func chip(_ s: String, strong: Bool = false) -> some View {
        Text(s).font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(strong ? Theme.accent.opacity(0.85) : Color.white.opacity(0.12), in: Capsule())
    }

    private var fileFacts: some View {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        return HStack(spacing: 14) {
            Label(ByteCountFormatter.string(fromByteCount: size, countStyle: .file), systemImage: "internaldrive")
            Label(file.lastPathComponent, systemImage: "doc").lineLimit(1).truncationMode(.middle)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes").font(.title3.weight(.bold))
                Text("\(siblings.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                ViewModeMenu(mode: $viewMode)
            }
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { s in
                            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { season = s } } label: {
                                Text(s == 0 ? "Specials" : "Season \(s)").font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background((season ?? seasons[0]) == s ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                .onAppear { if season == nil { season = parsed.season ?? seasons[0] } }
            }
            LibraryList(files: shownEpisodes, mode: LibraryViewMode(rawValue: viewMode) ?? .details, current: file, group: group) { play($0) }
        }
        .padding(.top, 10)
    }

    private var moreButton: some View {
        Menu {
            Button { play(file) } label: { Label("Play", systemImage: "play") }
            if let e = entry { Button { history.markWatched(e) } label: { Label("Mark as watched", systemImage: "checkmark.circle") } }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete file", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    // MARK: Actions

    private func play(_ f: URL) {
        let list = siblings.count > 1 ? siblings : LibraryOrganizer.sorted(local.files)
        let queue = list.map { u -> MediaItem in
            var m = MediaItem(url: u.path, title: TitleParser.clean(u.lastPathComponent), source: .local)
            m.historyKey = u.path
            let p = TitleParser.parse(u.lastPathComponent)
            if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
            return m
        }
        PlayerPresenter.play(queue: queue, index: list.firstIndex(of: f) ?? 0)
    }

    private func restart() {
        if let e = entry { history.remove(e) }
        play(file)
    }
}

// MARK: - 3D play button

/// Glass play button that tilts toward the finger (and, gently, with the
/// device) with a highlight that slides across like light on a bevel.
struct TiltPlayButton: View {
    let title: String
    var subtitle: String? = nil
    let action: () -> Void
    @State private var tilt = CGSize.zero          // -1…1
    @State private var pressed = false
    @State private var size = CGSize(width: 160, height: 56)
    @StateObject private var motion = MotionTilt()

    var body: some View {
        let tx = tilt.width + motion.tilt.width * 0.35
        let ty = tilt.height + motion.tilt.height * 0.35
        HStack(spacing: 12) {
            Image(systemName: "play.fill").font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26).frame(height: 56)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.gradient)
                // moving highlight = the parallax layer
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.45), .clear, .white.opacity(0.08)],
                                         startPoint: UnitPoint(x: 0.5 - tx * 0.5, y: 0.5 - ty * 0.6),
                                         endPoint: UnitPoint(x: 0.5 + tx * 0.5 + 0.4, y: 0.5 + ty * 0.6 + 0.6)))
                RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
        }
        .shadow(color: Theme.accent.opacity(0.45), radius: pressed ? 8 : 18, x: -tx * 10, y: 8 - ty * 10)
        .scaleEffect(pressed ? 0.96 : 1)
        .rotation3DEffect(.degrees(-ty * 12), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(tx * 12), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.7), value: tilt)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
        .animation(.easeOut(duration: 0.15), value: motion.tilt)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .background(GeometryReader { g in Color.clear.onAppear { size = g.size } })
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    pressed = true
                    tilt = CGSize(width: min(1, max(-1, (v.location.x / max(size.width, 1) - 0.5) * 2)),
                                  height: min(1, max(-1, (v.location.y / max(size.height, 1) - 0.5) * 2)))
                }
                .onEnded { v in
                    pressed = false
                    tilt = .zero
                    if hypot(v.translation.width, v.translation.height) < 12 {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        action()
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("heroPlay")
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }
}

/// Device attitude → small tilt offset, for the parallax on the play button.
@MainActor
final class MotionTilt: ObservableObject {
    @Published var tilt = CGSize.zero
    private let manager = CMMotionManager()
    private var base: (roll: Double, pitch: Double)?
    private var wanted = false
    private var observers: [NSObjectProtocol] = []

    init() {
        // Motion updates re-render the button 30× a second: pause them while a
        // video plays (the page is still alive under the player) or the app
        // is in the background.
        let nc = NotificationCenter.default
        for (name, on) in [(Notification.Name.playerWillShow, false), (.playerDidHide, true),
                           (UIApplication.didEnterBackgroundNotification, false), (UIApplication.willEnterForegroundNotification, true)] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if on, self.wanted, PlayerPresenter.current == nil { self.begin() } else if !on { self.pause() }
                }
            })
        }
    }

    func start() {
        wanted = true
        guard PlayerPresenter.current == nil else { return }
        begin()
    }

    private func pause() { manager.stopDeviceMotionUpdates(); base = nil }

    private func begin() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            if base == nil { base = (m.attitude.roll, m.attitude.pitch) }
            let dr = m.attitude.roll - (base?.roll ?? 0), dp = m.attitude.pitch - (base?.pitch ?? 0)
            let t = CGSize(width: min(1, max(-1, dr * 1.6)), height: min(1, max(-1, dp * 1.6)))
            // Only re-render for a visible change.
            if abs(t.width - tilt.width) > 0.02 || abs(t.height - tilt.height) > 0.02 { tilt = t }
        }
    }
    func stop() { wanted = false; pause(); tilt = .zero }
}

// MARK: - View modes shared by Home and the hero page

enum LibraryViewMode: String, CaseIterable {
    case grid, list, details
    var title: String { self == .grid ? "Thumbnails" : self == .list ? "List" : "Details" }
    var icon: String { self == .grid ? "square.grid.2x2" : self == .list ? "list.bullet" : "rectangle.grid.1x2" }
}

struct SortMenu: View {
    @Binding var sort: String
    @Binding var ascending: Bool
    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(LibrarySort.allCases, id: \.rawValue) { Label($0.title, systemImage: $0.icon).tag($0.rawValue) }
            }
            Divider()
            Button { ascending.toggle() } label: {
                Label(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 34).glassCircle()
        }
        .foregroundStyle(.white)
    }
}

struct ViewModeMenu: View {
    @Binding var mode: String
    var body: some View {
        Menu {
            Picker("View", selection: $mode) {
                ForEach(LibraryViewMode.allCases, id: \.rawValue) { Label($0.title, systemImage: $0.icon).tag($0.rawValue) }
            }
        } label: {
            Image(systemName: LibraryViewMode(rawValue: mode)?.icon ?? "square.grid.2x2")
                .font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34).glassCircle()
        }
        .foregroundStyle(.white)
    }
}

/// Files in list or details style (grid is laid out by the caller).
struct LibraryList: View {
    let files: [URL]
    let mode: LibraryViewMode
    var current: URL? = nil
    var group: LibraryGroup? = nil
    let play: (URL) -> Void
    @ObservedObject private var history = HistoryStore.shared
    @AppStorage(SettingsKey.openTitlePage) private var openTitlePage = true

    var body: some View {
        LazyVStack(spacing: mode == .details ? 12 : 4) {
            ForEach(files, id: \.self) { f in
                Group {
                    if openTitlePage && group == nil {
                        NavigationLink(value: LibraryRoute.file(f.path)) { row(f) }
                    } else {
                        Button { play(f) } label: { row(f) }
                    }
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .contextMenu {
                    Button { play(f) } label: { Label("Play", systemImage: "play") }
                    Button(role: .destructive) { LocalMediaStore.shared.delete(f) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    private func row(_ f: URL) -> some View {
        LibraryRow(file: f, mode: mode, highlighted: f == current, progress: history.entry(forURL: f.path)?.progress)
    }
}

struct LibraryRow: View {
    let file: URL
    let mode: LibraryViewMode
    var highlighted = false
    let progress: Double?
    var fixedTitle: String? = nil
    var fixedSubtitle: String? = nil
    @StateObject private var thumb = ThumbLoader()
    @AppStorage(SettingsKey.hideSpoilers) private var hideSpoilers = false

    /// Unwatched episode with spoilers hidden: no synopsis, blurred frame.
    private var spoilerHidden: Bool {
        hideSpoilers && parsed.episode != nil && HistoryStore.shared.entry(forURL: file.path)?.isFinished != true
    }
    private var parsed: TitleParser.Parsed { TitleParser.parse(file.lastPathComponent) }
    private var episodeTag: String? {
        guard let e = parsed.episode else { return nil }
        return "S\(parsed.season ?? 1) · E\(e)"
    }

    private var detail: Bool { mode == .details }
    private var thumbW: CGFloat { detail ? 150 : 78 }
    private var thumbH: CGFloat { detail ? 84 : 44 }
    private var headline: String { fixedTitle ?? thumb.meta?.episodeTitle ?? thumb.meta?.name ?? TitleParser.clean(file.lastPathComponent) }
    private var secondary: String {
        if let fixedSubtitle {
            if detail, let s = thumb.meta?.description, !s.isEmpty { return fixedSubtitle + " — " + s }
            return fixedSubtitle
        }
        if detail {
            if spoilerHidden { return thumb.meta?.name ?? file.lastPathComponent }
            if let s = thumb.meta?.synopsis, !s.isEmpty { return s }
            return file.lastPathComponent
        }
        if let n = thumb.meta?.name, n != thumb.meta?.episodeTitle { return n }
        return file.pathExtension.uppercased()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if fixedTitle == nil, let tag = episodeTag { Text(tag).font(.caption2.weight(.bold)).foregroundStyle(Theme.accent) }
                    Text(headline).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(detail ? 3 : 1)
            }
            Spacer(minLength: 0)
            if highlighted { Image(systemName: "play.fill").font(.caption).foregroundStyle(Theme.accent).padding(.top, 4) }
        }
        .padding(detail ? 8 : 6)
        .background(rowBackground)
        .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent) }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: detail ? 16 : 12, style: .continuous)
            .fill(highlighted ? Theme.accent.opacity(0.14) : Color.white.opacity(0.05))
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(width: thumbW, height: thumbH)
                .overlay {
                    if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill().blur(radius: spoilerHidden ? 12 : 0) }
                    else { GeneratedArt(seed: file.lastPathComponent) }
                }
                .clipped()
            if let progress, progress > 0.01 {
                Rectangle().fill(Theme.accent).frame(width: thumbW * progress, height: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: detail ? 12 : 8, style: .continuous))
    }
}

/// Logs the navigation controller's back swipe (enabled? did it start?) so a
/// report shows whether a swipe reached it.
struct BackSwipeProbe: UIViewRepresentable {
    final class Probe: UIView {
        private weak var watched: UIGestureRecognizer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, watched == nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var r: UIResponder? = self
                while let n = r, !(n is UINavigationController) { r = n.next }
                guard let nav = r as? UINavigationController else { dlog("nav", "back swipe probe: no navigation controller"); return }
                let g = nav.interactivePopGestureRecognizer
                var content = "n/a"
                #if compiler(>=6.2)
                if #available(iOS 26.0, *) { content = nav.interactiveContentPopGestureRecognizer.map { "\($0.isEnabled)" } ?? "nil" }
                #endif
                dlog("nav", "back swipe: edge enabled=\(g?.isEnabled ?? false) content=\(content) pages=\(nav.viewControllers.count) barHidden=\(nav.isNavigationBarHidden)")
                g?.addTarget(self, action: #selector(self.changed(_:)))
                self.watched = g
            }
        }
        @objc func changed(_ g: UIGestureRecognizer) {
            if g.state == .began || g.state == .ended || g.state == .cancelled || g.state == .failed {
                dlog("nav", "back swipe state \(g.state.rawValue)")
            }
        }
    }
    func makeUIView(context: Context) -> Probe { let p = Probe(); p.isUserInteractionEnabled = false; return p }
    func updateUIView(_ uiView: Probe, context: Context) {}
}
