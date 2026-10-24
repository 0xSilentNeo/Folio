import SwiftUI

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
    @AppStorage(SettingsKey.castPosition) private var castPosition = "bottom"

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
                        if let s = spoilerSafe(meta), !s.isEmpty {
                            ExpandableText(text: s, lines: 3)
                        }
                        if let g = meta?.genres, !g.isEmpty {
                            Text(g.prefix(5).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                        }
                        // Play sits under the description, centred (as on Discover).
                        HStack(spacing: 14) {
                            Spacer(minLength: 0)
                            TiltPlayButton(title: entry?.canResume == true ? "Resume" : "Play",
                                           subtitle: entry?.canResume == true ? "from \(PlayerModel.format(entry!.position))" : nil) { play(file) }
                            if entry?.canResume == true {
                                Button { restart() } label: {
                                    Label("Start over", systemImage: "arrow.counterclockwise").font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 16).frame(height: 44).glass(cornerRadius: 22, interactive: true)
                                }
                                .buttonStyle(PressStyle())
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        if castPosition == "top", let c = meta?.credits, !c.isEmpty { CastStrip(credits: c).padding(.horizontal, wide ? -28 : -20) }
                        if siblings.count > 1 { episodes }
                        if castPosition != "top", let c = meta?.credits, !c.isEmpty { CastStrip(credits: c).padding(.horizontal, wide ? -28 : -20) }
                        if let m = meta, m.id.hasPrefix("tt") {
                            TitleLinks(name: m.name, year: m.year.map { String($0.prefix(4)) }, type: m.type, imdbID: m.id)
                        }
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
        HeroHeader(height: wide ? 360 : width * 9 / 16 + 40) {
            if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
            else { GeneratedArt(seed: title) }
        } content: {
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
        }
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
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if showRatings, let r = meta?.rating { chip("★ \(r)", strong: true) }
                if let y = meta?.year ?? parsed.year.map(String.init) { chip(y) }
                if let c = meta?.contentRating { chip(c) }
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
        Text(s).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(strong ? Theme.accent.opacity(0.85) : Color.white.opacity(0.12), in: Capsule())
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
            ToolbarGlyph("ellipsis")
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
        if mode == .grid {
            // Thumbnails: a grid of episode stills (until 1.13.1 this mode drew
            // the same rows as List).
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                ForEach(files, id: \.self) { f in item(f) { tile(f) } }
            }
        } else {
            LazyVStack(spacing: mode == .details ? 12 : 4) {
                ForEach(files, id: \.self) { f in item(f) { row(f) } }
            }
        }
    }

    @ViewBuilder
    private func item<L: View>(_ f: URL, @ViewBuilder label: () -> L) -> some View {
        Group {
            if openTitlePage && group == nil {
                NavigationLink(value: LibraryRoute.file(f.path)) { label() }
            } else {
                Button { play(f) } label: { label() }
            }
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .contextMenu {
            Button { play(f) } label: { Label("Play", systemImage: "play") }
            Button(role: .destructive) { LocalMediaStore.shared.delete(f) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func tile(_ f: URL) -> some View {
        let p = TitleParser.parse(f.lastPathComponent)
        let tag = p.episode.map { "S\(p.season ?? 1) · E\($0)" } ?? TitleParser.clean(f.lastPathComponent)
        return MediaTile(title: tag, subtitle: f.pathExtension.uppercased(), key: f.path, fileURL: f, lookupName: f.lastPathComponent,
                         progress: history.entry(forURL: f.path)?.progress, fixedTitle: tag)
            .overlay(alignment: .topTrailing) {
                if f == current {
                    Image(systemName: "play.fill").font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(6).background(Theme.accent, in: Circle()).padding(6)
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
    /// Home library rows: the show's portrait poster instead of the episode still.
    var poster = false
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
    private var thumbW: CGFloat { poster ? (detail ? 64 : 32) : (detail ? 150 : 78) }
    private var thumbH: CGFloat { poster ? (detail ? 96 : 48) : (detail ? 84 : 44) }
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
        .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, art: poster ? .poster : .wide) }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: detail ? 16 : 12, style: .continuous)
            .fill(highlighted ? Theme.accent.opacity(0.14) : Color.white.opacity(0.05))
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(width: thumbW, height: thumbH)
                .overlay {
                    if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill().blur(radius: spoilerHidden && !poster ? 12 : 0) }
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
