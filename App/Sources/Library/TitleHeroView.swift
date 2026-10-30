import SwiftUI

/// Landing page for a library file: backdrop, poster, synopsis, rating, a
/// 3D play button, and the other files of the same title (episodes) in the
/// chosen view style.
struct TitleHeroView: View {
    let group: LibraryGroup
    /// The file the page was opened on (a file page), or nil for a series
    /// page, which follows the episode watched last.
    private let focus: URL?
    /// Live: a series page's highlight, header and Resume move to the episode
    /// you just watched when you come back from the player (1.14.1 fixed it
    /// at the moment the page was built).
    private var file: URL { focus ?? LibraryGroup.nextUp(in: group.files) }
    @ObservedObject private var local = LocalMediaStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @StateObject private var thumb = ThumbLoader()
    @AppStorage("heroView") private var viewMode = LibraryViewMode.grid.rawValue
    @AppStorage(SettingsKey.showRatings) private var showRatings = true
    @AppStorage(SettingsKey.hideSpoilers) private var hideSpoilers = false
    @AppStorage(SettingsKey.castPosition) private var castPosition = "bottom"
    @AppStorage(SettingsKey.titlePageStyle) private var titlePageStyle = "full"
    /// Settings → Library → Title pages → Files only (1.17.0): the title and its files.
    private var filesOnly: Bool { titlePageStyle == "files" }

    /// Episode synopsis, unless spoilers are hidden and it hasn't been watched
    /// (then the show's own description).
    private func spoilerSafe(_ m: MediaMeta?) -> String? {
        guard let m else { return nil }
        if hideSpoilers, m.episodeOverview != nil, HistoryStore.shared.entry(forURL: file.path)?.isFinished != true { return m.description }
        return m.synopsis
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmDelete = false
    /// An episode whose Delete was swiped: asks first.
    @State private var pendingDelete: URL?
    @State private var season: Int?

    /// A series page (all episodes merged) or a single file.
    init(group: LibraryGroup, focus: URL? = nil) {
        self.group = group
        self.focus = focus
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
    ///
    /// The show's name is worked out once. Until 1.17.4 it was worked out
    /// again for every file in the library, and with it `file` — the episode
    /// the page highlights, which looks through your watch history — so one
    /// build of MobLand's page went through the history thousands of times
    /// (simulator profile, 28 Oct: 1.8 of every 2.1 s spent in history
    /// lookups came from this line).
    ///
    /// Worked out once for the same library and episode, not at each of the
    /// ~8 places one build of the page asks (each sorted the episodes again).
    private var siblings: [URL] {
        let files = local.files, current = file
        if let m = memo.siblings, m.group == group.id, m.files == files, m.file == current { return m.list }
        let live = files.filter { group.files.contains($0) }
        let list: [URL]
        if group.isSeries {
            let show = TitleParser.parse(current.lastPathComponent).title.lowercased()
            let extra = files.filter { f in !group.files.contains(f) && TitleParser.parse(f.lastPathComponent).title.lowercased() == show }
            list = (live + extra).sorted(by: LibraryOrganizer.episodeOrder)
        } else {
            list = live.sorted(by: LibraryOrganizer.episodeOrder)
        }
        memo.siblings = (group.id, files, current, list)
        memo.seasons = Array(Set(list.compactMap { TitleParser.parse($0.lastPathComponent).season })).sorted()
        return list
    }
    private var seasons: [Int] { _ = siblings; return memo.seasons }
    /// Not state: what's remembered here never redraws anything.
    private final class Memo {
        var siblings: (group: String, files: [URL], file: URL, list: [URL])?
        var seasons: [Int] = []
    }
    @State private var memo = Memo()
    private var shownEpisodes: [URL] {
        guard seasons.count > 1, let season else { return siblings }
        return siblings.filter { TitleParser.parse($0.lastPathComponent).season == season }
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if filesOnly {
                        Text(title).font(.largeTitle.weight(.bold)).lineLimit(2)
                            .padding(.top, geo.safeAreaInsets.top + 52)
                            .padding(.horizontal, wide ? 28 : 20)
                    } else {
                        backdrop(geo.size)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                      if filesOnly {
                        episodes
                      } else {
                        // Genres above the description (from the title-page mockup).
                        if let g = meta?.genres, !g.isEmpty {
                            Text(g.prefix(5).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let s = spoilerSafe(meta), !s.isEmpty {
                            ExpandableText(text: s, lines: 2)
                        }
                        // Play sits under the description, left-aligned (from the mockup).
                        HStack(spacing: 14) {
                            TiltPlayButton(title: entry?.canResume == true ? "Resume" : "Play",
                                           subtitle: entry?.canResume == true ? "from \(PlayerModel.format(entry!.position))" : nil) { tapped(file, "Play") }
                            if entry?.canResume == true {
                                Button { if pageLife?.cantAct == nil { restart() } } label: {
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
                    }
                    .padding(.horizontal, wide ? 28 : 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .topScrollScrim()
        }
        .background(HomeBackdrop().ignoresSafeArea())
        .background(BackSwipeProbe().frame(width: 1, height: 1))
        .pageButtons(zooms: zoomsFromTile, back: goBack) { moreButton }
        // Landscape phone: the floating tab bar sat on the title and its details.
        .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        .onAppear {
            dlog("nav", "title page appear \(file.lastPathComponent)")
            thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, preferMeta: true, hero: HeroMetrics.pixels)
        }
        .onChange(of: file) { _, f in
            // Came back from the player on a later episode: show that one.
            thumb.load(key: f.path, fileURL: f, artwork: nil, lookupName: f.lastPathComponent, preferMeta: true, hero: HeroMetrics.pixels)
        }
        .onDisappear { dlog("nav", "title page disappear \(file.lastPathComponent)") }
        .confirmationDialog("Delete this file from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { local.delete(file); dismiss() }
        }
    }

    // MARK: Pieces

    private func backdrop(_ size: CGSize) -> some View {
        HeroHeader(height: HeroMetrics.height(size)) {
            if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill() }
            else { GeneratedArt(seed: title) }
        } content: {
                // Accessibility text sizes: the title block goes under the
                // poster, with the whole width, instead of a narrow column.
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    : AnyLayout(HStackLayout(alignment: .bottom, spacing: 14))
                layout {
                    if let poster = meta?.poster, let u = URL(string: poster) {
                        CachedImage(url: u, maxPixel: 400) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                            .frame(width: 122, height: 191)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Theme.shadow, radius: 12, y: 6)
                    }
                    titleBlock.padding(.bottom, 6)
                }
                .padding(.leading, size.width > 700 ? 28 : 20)
                .padding(.trailing, 20)
        }
    }

    private var isAnime: Bool { meta?.genres?.contains { $0.localizedCaseInsensitiveContains("anim") } ?? false }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The whole title: up to three lines, a little smaller before it's
            // cut, at its full height whatever the lines under it need (the
            // 29 Oct screenshot had it cut to one line), and with the text size.
            DecipherText(text: title, font: .system(.title, design: .rounded, weight: .bold))
                .lineLimit(typeSize.isAccessibilitySize ? 5 : 3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            // Anime: the show's own (romaji) title, or nothing. Never the
            // episode name in its place (1.18.0 showed it whenever the romaji
            // was missing, and IMDb's saved copy had lost it). Other titles:
            // the episode name.
            if isAnime {
                if let o = meta?.originalName, !o.isEmpty {
                    Text(o).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if let ep = meta?.episodeTitle ?? episodeLabel {
                Text(ep).font(.headline).foregroundStyle(.primary.opacity(0.8)).lineLimit(3)
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
            .foregroundStyle(strong ? Theme.onAccent : .primary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(strong ? Theme.accent : Theme.fill, in: Capsule())
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.isSeries || parsed.episode != nil ? "Episodes" : "Files").font(.title3.weight(.bold))
                Text("\(siblings.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                ViewModeMenu(mode: $viewMode)
            }
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { s in
                            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { season = s } } label: {
                                let on = (season ?? seasons[0]) == s
                                Text(s == 0 ? "Specials" : "Season \(s)").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(on ? Theme.onAccent : .primary)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background(on ? Theme.accent : Theme.fill, in: Capsule())
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                .onAppear { if season == nil { season = parsed.season ?? seasons[0] } }
            }
            LibraryList(files: shownEpisodes, mode: LibraryViewMode(rawValue: viewMode) ?? .details, current: file, group: group,
                        swipe: { f in
                            [SwipeAction(title: "Delete", icon: "trash", tint: .red) { pendingDelete = f },
                             history.isWatched(f)
                                ? SwipeAction(title: "Unwatched", icon: "eye.slash", tint: .gray) { history.setWatched([f], false) }
                                : SwipeAction(title: "Watched", icon: "eye", tint: Theme.swipeTint) { history.setWatched([f], true) }]
                        },
                        pendingDelete: $pendingDelete,
                        delete: { f in
                            let last = siblings.count <= 1
                            local.delete(f)
                            if last { dismiss() }
                        }) { tapped($0, "episode row") }
        }
        .padding(.top, 10)
    }

    private var moreButton: some View {
        Menu {
            Button { play(file) } label: { Label("Play", systemImage: "play") }
            if siblings.count > 1 {
                WatchedMenuItems(files: [file], scope: .thisEpisode)
                WatchedMenuItems(files: siblings, scope: .all)
            } else {
                WatchedMenuItems(files: [file])
            }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete file", systemImage: "trash") }
        } label: {
            PageButtonLabel(systemName: "ellipsis", width: 56)
        }
        .accessibilityLabel("More")
    }

    private func goBack() {
        if pageLife?.leaving == true { dlog("nav", "title page: Back ignored (page already going back)"); return }
        dlog("nav", "title page: Back")
        pageLife?.leave()          // no touches or actions from here, before the pop even starts
        dismiss()
    }

    // MARK: Actions

    @Environment(\.pageLife) private var pageLife
    @Environment(\.zoomsFromTile) private var zoomsFromTile

    /// A tap on the page's Play / Resume or an episode: ignored when the
    /// finger moved on the screen (a swipe that started on the control — the
    /// zoom transition's swipe back to Home isn't seen by BackGesture;
    /// TouchTracker). A page going back takes no touches at all (LeavingProbe,
    /// UIKit's isUserInteractionEnabled). 1.17.1 also ignored taps while the
    /// page was still zooming in — taps you meant, on a page you could see
    /// (27 Oct report: "the buttons were not getting registered"); gone.
    private func tapped(_ f: URL, _ control: String) {
        if let why = pageLife?.cantAct {
            dlog("nav", "title page: \(control) ignored (\(why))")
            return
        }
        let moved = TouchTracker.recentTravel
        if moved > TouchTracker.tapSlop {
            dlog("nav", "title page: \(control) ignored (the finger moved \(Int(moved)) pt: a swipe, not a tap)")
            return
        }
        dlog("nav", "title page: \(control) → play \(f.lastPathComponent)")
        play(f)
    }

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
        .foregroundStyle(.primary)
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
        .foregroundStyle(.primary)
        .accessibilityLabel("View, \((LibraryViewMode(rawValue: mode) ?? .grid).title)")
        .accessibilityIdentifier("viewModeMenu")
    }
}

/// Files in list or details style (grid is laid out by the caller).
struct LibraryList: View {
    let files: [URL]
    let mode: LibraryViewMode
    var current: URL? = nil
    var group: LibraryGroup? = nil
    /// Actions revealed by swiping a row to the left (over the tile in Thumbnails).
    var swipe: ((URL) -> [SwipeAction])? = nil
    /// The file whose delete question is up, and what Delete does. The question
    /// is attached to the file's own row, so it points at that row (iOS shows
    /// confirmation dialogs as a popover from the view they're attached to).
    var pendingDelete: Binding<URL?>? = nil
    var delete: ((URL) -> Void)? = nil
    let play: (URL) -> Void
    @ObservedObject private var history = HistoryStore.shared
    @AppStorage(SettingsKey.openTitlePage) private var openTitlePage = true
    @State private var openRow: String?

    var body: some View {
        if mode == .grid {
            // Thumbnails: a grid of episode stills (until 1.13.1 this mode drew
            // the same rows as List).
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                ForEach(files, id: \.self) { f in
                    Group {
                        if let swipe {
                            SwipeTile(id: f.path, openID: $openRow, actions: swipe(f), cornerRadius: 16) { item(f) { tile(f) } }
                        } else {
                            item(f) { tile(f) }
                        }
                    }
                    .modifier(DeleteQuestion(file: f, pending: pendingDelete, delete: delete))
                }
            }
        } else {
            LazyVStack(spacing: mode == .details ? 12 : 4) {
                ForEach(files, id: \.self) { f in
                    Group {
                        if let swipe {
                            SwipeRow(id: f.path, openID: $openRow, actions: swipe(f)) { item(f) { row(f) } }
                        } else {
                            item(f) { row(f) }
                        }
                    }
                    .modifier(DeleteQuestion(file: f, pending: pendingDelete, delete: delete))
                }
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
        .accessibilityIdentifier("ep:" + f.lastPathComponent)
        .contextMenu {
            Button { play(f) } label: { Label("Play", systemImage: "play") }
            WatchedMenuItems(files: [f])
            Button(role: .destructive) {
                if let pendingDelete { pendingDelete.wrappedValue = f } else { LocalMediaStore.shared.delete(f) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func tile(_ f: URL) -> some View {
        let p = TitleParser.parse(f.lastPathComponent)
        let tag = TitleParser.tag(p) ?? TitleParser.clean(f.lastPathComponent)
        return MediaTile(title: tag, subtitle: f.pathExtension.uppercased(), key: f.path, fileURL: f, lookupName: f.lastPathComponent,
                         progress: history.entry(forURL: f.path)?.progress, fixedTitle: tag,
                         trailingNote: LibraryOrganizer.info(f).size.byteString, watched: history.isWatched(f))
            .overlay(alignment: .topTrailing) {
                if f == current {
                    Image(systemName: "play.fill").font(.caption2.weight(.bold)).foregroundStyle(Theme.onAccent)
                        .padding(6).background(Theme.accent, in: Circle()).padding(6)
                }
            }
    }

    private func row(_ f: URL) -> some View {
        LibraryRow(file: f, mode: mode, highlighted: f == current, progress: history.entry(forURL: f.path)?.progress, size: LibraryOrganizer.info(f).size,
                   watched: history.isWatched(f))
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
    /// The title page zooms out of this row's picture.
    var zoom: ZoomSource? = nil
    /// …or out of the whole row (ListTransition.row).
    var zoomWholeRow = false
    /// A size at the bottom right, level with the picture's bottom edge: the
    /// file's (episode rows) or the title's, all its episodes (Home). Read
    /// from the library scan, never worked out while drawing.
    var size: Int64? = nil
    /// Watched (for a show's row on Home: every episode): an eye at the end.
    var watched = false
    @StateObject private var thumb = ThumbLoader()
    @AppStorage(SettingsKey.hideSpoilers) private var hideSpoilers = false

    /// Unwatched episode with spoilers hidden: no synopsis, blurred frame.
    private var spoilerHidden: Bool {
        hideSpoilers && parsed.episode != nil && HistoryStore.shared.entry(forURL: file.path)?.isFinished != true
    }
    private var parsed: TitleParser.Parsed { TitleParser.parse(file.lastPathComponent) }
    private var episodeTag: String? { parsed.episode == nil ? nil : TitleParser.tag(parsed) }

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
            if let size {
                VStack(alignment: .trailing, spacing: 0) {
                    marks.padding(.top, 4)
                    Spacer(minLength: 4)
                    Text(size.byteString)
                        .font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                .frame(height: thumbH)
            } else if highlighted || watched {
                marks.padding(.top, 4)
            }
        }
        .padding(detail ? 8 : 6)
        .background(rowBackground)
        .zoomSource(zoomWholeRow ? zoom : nil, cornerRadius: detail ? 16 : 12)
        .onAppear {
            LibTrace.image.log("row \(fixedTitle ?? file.lastPathComponent) (\(mode.rawValue)) appeared (loader #\(thumb.serial), picture \(thumb.image == nil ? "none yet" : "shown"))")
            thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, art: poster ? .poster : .wide)
        }
        .onDisappear { LibTrace.image.log("row \(fixedTitle ?? file.lastPathComponent) (\(mode.rawValue)) disappeared (loader #\(thumb.serial))") }
    }

    /// Top right: the eye when watched, the play mark on the highlighted row.
    private var marks: some View {
        HStack(spacing: 6) {
            if watched { Image(systemName: "eye.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Watched") }
            if highlighted { Image(systemName: "play.fill").font(.caption).foregroundStyle(Theme.accent) }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: detail ? 16 : 12, style: .continuous)
            .fill(highlighted ? Theme.accentSoft : Theme.card)
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(width: thumbW, height: thumbH)
                .overlay {
                    if let img = thumb.image { Image(uiImage: img).resizable().scaledToFill().blur(radius: spoilerHidden && !poster ? 12 : 0) }
                    else { GeneratedArt(seed: file.lastPathComponent) }
                }
                .clipped()
            if !watched, let progress, progress > 0.01 { ArtProgressBar(progress: progress).frame(width: thumbW, height: thumbH) }
        }
        .clipShape(RoundedRectangle(cornerRadius: detail ? 12 : 8, style: .continuous))
        .zoomSource(zoomWholeRow ? nil : zoom, cornerRadius: detail ? 12 : 8)
    }
}

/// Logs the navigation controller's back swipe (enabled? did it start?) so a
/// report shows whether a swipe reached it.
/// Is a back swipe under way, or did one just start? (1.16.1: a Play tap
/// that coincides with a back swipe is ignored.)
@MainActor
enum BackGesture {
    /// The navigation controller the title pages live in (set by BackSwipeProbe).
    static weak var nav: UINavigationController?
    /// A page is moving in or out: the zoom from its tile (or back into it)
    /// runs ~0.9 s in the simulator, and its page takes touches meanwhile
    /// (lab page probe: a touch at the page's middle reached the page for the
    /// whole zoom-in). 27 Oct log: episode rows played 0.4–1.2 s after the
    /// page appeared, from taps meant for Home.
    static var pageMoving: Bool { moving(page) }
    /// The title page on screen (its controller), set by BackSwipeProbe.
    static weak var page: UIViewController?

    /// Whether `page`'s own navigation move is running: the navigation
    /// controller's transition has it as the page coming or going (a sheet or
    /// alert closing over it doesn't count).
    static func moving(_ page: UIViewController?) -> Bool {
        guard let tc = nav?.transitionCoordinator, let page else { return false }
        let ends = [tc.viewController(forKey: .from), tc.viewController(forKey: .to)].compactMap { $0 }
        var v: UIViewController? = page
        while let c = v {
            if ends.contains(where: { $0 === c }) { return true }
            v = c.parent
        }
        return false
    }
    static var active = false
    static var lastBegan = Date.distantPast
    static var justStarted: Bool { active || Date().timeIntervalSince(lastBegan) < 0.6 }
}

struct BackSwipeProbe: UIViewRepresentable {
    final class Probe: UIView {
        private var watched: [UIGestureRecognizer] = []
        private weak var navRef: UINavigationController?

        /// This page's controller (the first one up the responder chain).
        private var pageController: UIViewController? {
            var r: UIResponder? = self
            while let n = r, !(n is UIViewController) { r = n.next }
            return r as? UIViewController
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let w = window { TouchTracker.install(on: w) }
            // Back on screen after another page or a tab switch: the move log again.
            if window != nil, let nav = navRef, !Self.labProbe {
                BackGesture.page = pageController
                startMoveLog(nav)
            }
            guard window != nil, watched.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var r: UIResponder? = self
                while let n = r, !(n is UINavigationController) { r = n.next }
                guard let nav = r as? UINavigationController else { dlog("nav", "back swipe probe: no navigation controller"); return }
                BackGesture.nav = nav
                BackGesture.page = self.pageController
                self.navRef = nav
                let g = nav.interactivePopGestureRecognizer
                var content: UIGestureRecognizer?
                #if compiler(>=6.2)
                if #available(iOS 26.0, *) { content = nav.interactiveContentPopGestureRecognizer }
                #endif
                dlog("nav", "back swipe: edge enabled=\(g?.isEnabled ?? false) content=\(content.map { "\($0.isEnabled)" } ?? "n/a") pages=\(nav.viewControllers.count) barHidden=\(nav.isNavigationBarHidden)")
                for r in [g, content].compactMap({ $0 }) where !self.watched.contains(r) {
                    r.addTarget(self, action: #selector(self.changed(_:)))
                    self.watched.append(r)
                }
                if Self.labProbe { self.startNavProbe(nav) } else { self.startMoveLog(nav) }
            }
        }

        // MARK: The page's own moves, in the log (each change, 10 times a second)

        private var moveTimer: Timer?
        private var lastMove = "none"

        /// 1.17.1: whether a navigation transition is running for the page, so
        /// a device log shows when taps on it are ignored and why. The 26 Oct
        /// recording has the page's ‹ and ••• still over Home for ~1 s after it
        /// had zoomed back into its tile — its move not finished yet.
        private func startMoveLog(_ nav: UINavigationController) {
            watchPlayer()
            guard moveTimer == nil, PlayerPresenter.current == nil else { return }
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self, weak nav] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let tc = BackGesture.moving(self.pageController) ? nav?.transitionCoordinator : nil
                    let now = tc.map { $0.isInteractive ? "interactive" : "animated" } ?? "none"
                    if now != self.lastMove {
                        self.lastMove = now
                        // When a move ends: the navigation bar's state (a swipe
                        // back let go early left it at alpha 0 in the simulator).
                        let bar = now == "none" ? nav.map { " (navigation bar \($0.isNavigationBarHidden ? "hidden" : "shown"), alpha \(String(format: "%.2f", $0.navigationBar.alpha)), height \(Int($0.navigationBar.frame.height)))" } ?? "" : ""
                        dlog("nav", "title page move: \(now)\(bar)")
                    }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            moveTimer = t
        }

        /// The player covers the app by hiding its windows, so this page stays
        /// in its window and the move log would tick ten times a second for the
        /// whole video. It stops while the player is up.
        private var playerObservers: [NSObjectProtocol] = []
        private func watchPlayer() {
            guard playerObservers.isEmpty else { return }
            let nc = NotificationCenter.default
            playerObservers.append(nc.addObserver(forName: .playerWillShow, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let t = self.moveTimer else { return }
                    t.invalidate(); self.moveTimer = nil
                    dlog("nav", "title page move log paused while the player is up")
                }
            })
            playerObservers.append(nc.addObserver(forName: .playerDidHide, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil, let nav = self.navRef, !Self.labProbe else { return }
                    self.startMoveLog(nav)
                }
            })
        }

        // MARK: Lab (`-navProbe`): the page during its own transitions

        static let labProbe = CommandLine.arguments.contains("-navProbe")
        private var link: CADisplayLink?
        private weak var nav: UINavigationController?
        private var lastLine = ""

        private func startNavProbe(_ nav: UINavigationController) {
            self.nav = nav
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(sample))
            l.add(to: .main, forMode: .common)
            link = l
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                link?.invalidate(); link = nil
                moveTimer?.invalidate(); moveTimer = nil
                playerObservers.forEach { NotificationCenter.default.removeObserver($0) }
                playerObservers = []
                if Self.labProbe { dlog("navprobe", "page left the window") }
            }
        }

        /// Each frame: the navigation transition, where the page is drawn, and
        /// whether a touch at the middle of where it's drawn would reach it.
        @objc private func sample() {
            var r: UIResponder? = self
            while let n = r, !(n is UIViewController) { r = n.next }
            guard let page = (r as? UIViewController)?.view, let w = window else { return }
            let tc = nav?.transitionCoordinator
            let pl = page.layer.presentation() ?? page.layer
            let f = (page.superview ?? page).convert(pl.frame, to: nil).integral
            let mid = CGPoint(x: f.midX, y: f.midY)
            let hit = w.hitTest(mid, with: nil)
            let line = "transition=\(tc.map { "\($0.isInteractive ? "interactive" : "animated")\($0.isCancelled ? " cancelled" : "")" } ?? "none") page \(f) alpha \(String(format: "%.2f", pl.opacity)) touch at its middle → \(hit.map { $0.isDescendant(of: page) ? "the page" : String(describing: type(of: $0)) } ?? "nothing")"
            if line != lastLine { lastLine = line; dlog("navprobe", line) }
        }
        @objc func changed(_ g: UIGestureRecognizer) {
            let kind = g === watched.first ? "edge" : "content"
            switch g.state {
            case .began:
                BackGesture.active = true
                BackGesture.lastBegan = Date()
                dlog("nav", "back swipe (\(kind)) began")
            case .changed:
                BackGesture.active = true
            case .ended, .cancelled, .failed:
                BackGesture.active = false
                dlog("nav", "back swipe (\(kind)) \(g.state == .ended ? "ended" : g.state == .cancelled ? "cancelled" : "failed")")
            default: break
            }
        }
    }
    func makeUIView(context: Context) -> Probe { let p = Probe(); p.isUserInteractionEnabled = false; return p }
    func updateUIView(_ uiView: Probe, context: Context) {}
}

/// The delete question for one library file, attached to its row or tile.
struct DeleteQuestion: ViewModifier {
    let file: URL
    let pending: Binding<URL?>?
    let delete: ((URL) -> Void)?

    func body(content: Content) -> some View {
        if let pending, let delete {
            content.confirmationDialog(
                "Delete \(TitleParser.tag(TitleParser.parse(file.lastPathComponent)) ?? file.lastPathComponent) (\(LibraryOrganizer.info(file).size.byteString))?",
                isPresented: Binding(get: { pending.wrappedValue == file }, set: { if !$0, pending.wrappedValue == file { pending.wrappedValue = nil } }),
                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete(file) }
            }
        } else {
            content
        }
    }
}
