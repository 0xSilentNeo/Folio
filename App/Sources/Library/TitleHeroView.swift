import SwiftUI
import CoreMotion

/// Landing page for a library file: backdrop, poster, synopsis, rating, a
/// 3D play button, and the other files of the same title (episodes) in the
/// chosen view style.
struct TitleHeroView: View {
    let file: URL
    @ObservedObject private var local = LocalMediaStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @StateObject private var thumb = ThumbLoader()
    @AppStorage("heroView") private var viewMode = LibraryViewMode.details.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var parsed: TitleParser.Parsed { TitleParser.parse(file.lastPathComponent) }
    private var meta: MediaMeta? { thumb.meta }
    private var title: String { meta?.name ?? TitleParser.clean(file.lastPathComponent) }
    private var entry: HistoryEntry? { history.entry(forURL: file.path) }

    /// Other library files that parse to the same title (a series' episodes).
    private var siblings: [URL] {
        let me = parsed.title.lowercased()
        return local.files.filter { TitleParser.parse($0.lastPathComponent).title.lowercased() == me }
            .sorted { a, b in
                let pa = TitleParser.parse(a.lastPathComponent), pb = TitleParser.parse(b.lastPathComponent)
                return (pa.season ?? 0, pa.episode ?? 0, a.lastPathComponent) < (pb.season ?? 0, pb.episode ?? 0, b.lastPathComponent)
            }
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    backdrop(width: geo.size.width, wide: wide)
                    VStack(alignment: .leading, spacing: 18) {
                        titleBlock
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
                        if let s = meta?.synopsis, !s.isEmpty {
                            Text(s).font(.callout).foregroundStyle(.white.opacity(0.85)).lineSpacing(2)
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
        }
        .background(HomeBackdrop().ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { backButton }
        .overlay(alignment: .topTrailing) { moreButton }
        .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, preferMeta: true) }
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
            if let poster = meta?.poster, let u = URL(string: poster) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    .frame(width: 84, height: 126)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                    .padding(.leading, wide ? 28 : 20)
                    .offset(y: 40)
            }
        }
        .padding(.bottom, meta?.poster != nil ? 30 : 0)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).lineLimit(2)
            if let ep = meta?.episodeTitle ?? episodeLabel {
                Text(ep).font(.headline).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 8) {
                if let r = meta?.rating { chip("★ \(r)", strong: true) }
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
                Text("In your library").font(.title3.weight(.bold))
                Text("\(siblings.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                ViewModeMenu(mode: $viewMode)
            }
            LibraryList(files: siblings, mode: LibraryViewMode(rawValue: viewMode) ?? .details, current: file) { play($0) }
        }
        .padding(.top, 10)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40).glassCircle()
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.white)
        .padding(.leading, 16).padding(.top, 8)
    }

    private var moreButton: some View {
        Menu {
            Button { play(file) } label: { Label("Play", systemImage: "play") }
            if let e = entry { Button { history.markWatched(e) } label: { Label("Mark as watched", systemImage: "checkmark.circle") } }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete file", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40).glassCircle()
        }
        .foregroundStyle(.white)
        .padding(.trailing, 16).padding(.top, 8)
    }

    // MARK: Actions

    private func play(_ f: URL) {
        let list = siblings.count > 1 ? siblings : local.files
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

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            if base == nil { base = (m.attitude.roll, m.attitude.pitch) }
            let dr = m.attitude.roll - (base?.roll ?? 0), dp = m.attitude.pitch - (base?.pitch ?? 0)
            tilt = CGSize(width: min(1, max(-1, dr * 1.6)), height: min(1, max(-1, dp * 1.6)))
        }
    }
    func stop() { manager.stopDeviceMotionUpdates(); base = nil; tilt = .zero }
}

// MARK: - View modes shared by Home and the hero page

enum LibraryViewMode: String, CaseIterable {
    case grid, list, details
    var title: String { self == .grid ? "Thumbnails" : self == .list ? "List" : "Details" }
    var icon: String { self == .grid ? "square.grid.2x2" : self == .list ? "list.bullet" : "rectangle.grid.1x2" }
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
    let play: (URL) -> Void
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        LazyVStack(spacing: mode == .details ? 12 : 4) {
            ForEach(files, id: \.self) { f in
                NavigationLink { TitleHeroView(file: f) } label: {
                    LibraryRow(file: f, mode: mode, highlighted: f == current, progress: history.entry(forURL: f.path)?.progress)
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .contextMenu {
                    Button { play(f) } label: { Label("Play", systemImage: "play") }
                    Button(role: .destructive) { LocalMediaStore.shared.delete(f) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }
}

struct LibraryRow: View {
    let file: URL
    let mode: LibraryViewMode
    var highlighted = false
    let progress: Double?
    @StateObject private var thumb = ThumbLoader()

    private var parsed: TitleParser.Parsed { TitleParser.parse(file.lastPathComponent) }
    private var episodeTag: String? {
        guard let e = parsed.episode else { return nil }
        return "S\(parsed.season ?? 1) · E\(e)"
    }

    var body: some View {
        let detail = mode == .details
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.frame(width: detail ? 150 : 78, height: detail ? 84 : 44)
                    .overlay {
                        if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
                        else { GeneratedArt(seed: file.lastPathComponent) }
                    }
                    .clipped()
                if let progress, progress > 0.01 {
                    Rectangle().fill(Theme.accent).frame(width: (detail ? 150 : 78) * progress, height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: detail ? 12 : 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let tag = episodeTag { Text(tag).font(.caption2.weight(.bold)).foregroundStyle(Theme.accent) }
                    Text(thumb.meta?.episodeTitle ?? thumb.meta?.name ?? TitleParser.clean(file.lastPathComponent))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if detail {
                    if let s = thumb.meta?.synopsis, !s.isEmpty {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    } else {
                        Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else {
                    Text(thumb.meta?.name.map { $0 == (thumb.meta?.episodeTitle ?? "") ? file.pathExtension.uppercased() : $0 } ?? file.pathExtension.uppercased())
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if highlighted { Image(systemName: "play.fill").font(.caption).foregroundStyle(Theme.accent).padding(.top, 4) }
        }
        .padding(detail ? 8 : 6)
        .background(highlighted ? Theme.accent.opacity(0.14) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: detail ? 16 : 12, style: .continuous))
        .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent) }
    }
}
