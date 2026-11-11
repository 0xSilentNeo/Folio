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
    @ObservedObject private var kids = KidsProfile.shared
    @ObservedObject private var tracking = TrackingStore.shared
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
    @State private var fixingMatch = false
    @State private var confirmDeleteAll = false
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
    /// The episode the page shows, as its Delete names it: "S1 · E3", else the file name.
    private var deleteLabel: String { TitleParser.tag(parsed) ?? file.lastPathComponent }
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
        guard seasons.count > 1, let season = shownSeason else { return siblings }
        return siblings.filter { TitleParser.parse($0.lastPathComponent).season == season }
    }
    /// The season the episode list shows: the one picked, else this file's,
    /// else the first (1.24.1). Until a chip's onAppear set it, the page
    /// built every season's rows, then swapped to this file's mid-zoom (6 Nov
    /// report: S01 rows made and loading, 19 ms later the S03 ones).
    private var shownSeason: Int? {
        if let season { return season }
        if let s = parsed.season, seasons.contains(s) { return s }
        return seasons.first
    }

    /// The kids profile's answer for this title when it isn't "allowed"
    /// (the page was opened by a link or from another device); nil otherwise.
    private var kidsVerdict: KidsRules.Verdict? {
        guard let limits = kids.activeLimits else { return nil }
        let v = KidsRules.verdict(meta ?? LibraryMetaIndex.shared.meta(for: file), limits: limits)
        return v == .allowed ? nil : v
    }

    var body: some View {
        if let v = kidsVerdict {
            KidsBlockedView(verdict: v)
                .pageButtons(zooms: zoomsFromTile, back: goBack) { EmptyView() }
                .landscapeTopGap()
                .onAppear { thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, preferMeta: true, hero: HeroMetrics.pixels) }
        } else {
            // Handoff (1.22.0): the other device opens this file's page when it has the file.
            page.handoffTitle(HandoffActivity.Payload(target: .library(file: file.lastPathComponent, title: title)))
        }
    }

    private var page: some View {
        GeometryReader { geo in
            // The text in a readable column, centred, on a wide iPad window
            // (1.30.0); the picture keeps the whole width.
            let base: CGFloat = geo.size.width > 700 ? 28 : 20
            let side = PageLayout(width: geo.size.width).readableSide(base)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if filesOnly {
                        Text(title).font(.largeTitle.weight(.bold)).lineLimit(2)
                            .padding(.top, geo.safeAreaInsets.top + 52)
                            .padding(.horizontal, side)
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
                        // Track (1.21.0) after it for a series, on its own line when there's no room.
                        TitleButtonRow {
                            TiltPlayButton(title: entry?.canResume == true ? "Resume" : "Play",
                                           subtitle: entry?.canResume == true ? "from \(PlayerModel.format(entry!.position))" : nil) { tapped(file, "Play") }
                            if entry?.canResume == true {
                                Button { if pageLife?.cantAct == nil { restart() } } label: {
                                    Label("Start over", systemImage: "arrow.counterclockwise").font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 16).frame(height: 44).glass(cornerRadius: 22, interactive: true)
                                }
                                .buttonStyle(PressStyle())
                            }
                            if isShow { TrackButton(show: trackedShow) }
                        }
                        .padding(.vertical, 4)
                        if isShow { TrackStatusLine(show: trackedShow).padding(.top, -8) }
                        if castPosition == "top", let c = meta?.credits, !c.isEmpty { CastStrip(credits: c, inset: side > base ? side : 16).padding(.horizontal, -side) }
                        if siblings.count > 1 { episodes } else if !untiledEpisodes.isEmpty { comingUp.padding(.top, 10) }
                        if castPosition != "top", let c = meta?.credits, !c.isEmpty { CastStrip(credits: c, inset: side > base ? side : 16).padding(.horizontal, -side) }
                        if let m = meta, m.id.hasPrefix("tt") {
                            TitleLinks(name: m.name, year: m.year.map { String($0.prefix(4)) }, type: m.type, imdbID: m.id)
                        }
                      }
                    }
                    .padding(.horizontal, side)
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
        .landscapeTopGap()
        // Landscape phone: the floating tab bar sat on the title and its details.
        .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        .onAppear {
            dlog("nav", "title page appear \(file.lastPathComponent)")
            LibTrace.title.event("appeared", "library title page appeared")
            thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, preferMeta: true, hero: HeroMetrics.pixels)
        }
        .onChange(of: file) { _, f in
            // Came back from the player on a later episode: show that one,
            // and its season (1.20.3: after a season finale the chips stayed
            // on the old season, hiding the highlighted episode).
            thumb.load(key: f.path, fileURL: f, artwork: nil, lookupName: f.lastPathComponent, preferMeta: true, hero: HeroMetrics.pixels)
            if let s = TitleParser.parse(f.lastPathComponent).season, seasons.contains(s) { season = s }
        }
        .onDisappear { dlog("nav", "title page disappear \(file.lastPathComponent)") }
        // Each question names what goes. Until 1.20.3 a series page's "Delete
        // file" deleted the next-up episode without saying which (review, 2 Nov).
        .confirmationDialog("Delete \(deleteLabel) (\(LibraryOrganizer.info(file).size.byteString))?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { local.delete(file); dismiss() }
        }
        .confirmationDialog("Delete all \(siblings.count) episodes of \(title) (\(siblings.reduce(Int64(0)) { $0 + LibraryOrganizer.info($1).size }.byteString))?",
                            isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { local.delete(siblings); dismiss() }
        }
    }

    // MARK: Pieces

    private func backdrop(_ size: CGSize) -> some View {
        HeroHeader(height: HeroMetrics.height(size)) {
            // The picture from memory in the first frame (1.24.1): Home starts
            // loading it when your finger goes down (ThumbLoader.prefetchHero).
            Group {
                if let img = thumb.image ?? ThumbLoader.cached(key: file.path, points: 0, hero: HeroMetrics.pixels) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else { GeneratedArt(seed: title) }
            }
            .accessibilityHidden(true)      // pictures only: the title is read from the text
        } content: {
                // Accessibility text sizes: the title block goes under the
                // poster, with the whole width, instead of a narrow column.
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    : AnyLayout(HStackLayout(alignment: .bottom, spacing: 14))
                layout {
                    if let poster = meta?.poster, let u = URL(string: poster) {
                        CachedImage(url: u, maxPixel: 400) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                            .accessibilityHidden(true)
                            .frame(width: 122, height: 191)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Theme.shadow, radius: 12, y: 6)
                    }
                    titleBlock.padding(.bottom, 6)
                }
                .padding(.leading, PageLayout(width: size.width).readableSide(size.width > 700 ? 28 : 20))
                .padding(.trailing, PageLayout(width: size.width).readableSide(20))
        }
    }

    private var isAnime: Bool { meta?.genres?.contains { $0.localizedCaseInsensitiveContains("anim") } ?? false }

    /// A show the Track button is for (1.22.1): the library grouped its
    /// episodes, or the file has an episode number, or the metadata says
    /// it's a series. Until 1.22.1 only the first, so an episode opened from
    /// a folder of several titles (its group is the folder), or a show whose
    /// file names don't parse as episodes, had no Track button and no sign
    /// it was tracked.
    private var isShow: Bool { group.isSeries || parsed.episode != nil || meta?.type == "series" }

    /// The series as the Track button tracks it: by its IMDb id when Folio
    /// found one, with the newest season in the library (anime seasons are
    /// separate AniList entries). Its library name goes with it, so
    /// Discover finds it tracked by that too (TrackedShow.otherNames).
    private var trackedShow: TrackedShow {
        TrackedShow(libraryTitle: group.isSeries ? group.title : parsed.title, meta: meta, hint: entry?.item.anime, season: seasons.last)
    }

    /// The tracked show's schedule for the episode tiles (1.22.1); nil when
    /// it isn't tracked.
    private var airing: EpisodeAiring? {
        guard isShow, let s = tracking.tracked(like: trackedShow) else { return nil }
        return EpisodeAiring(show: s, now: Date(), newestSeason: seasons.last)
    }

    /// The episodes not out yet that have no file here, for the season shown.
    private var untiledEpisodes: [AiringEpisode] {
        guard let airing else { return [] }
        let numbers = shownEpisodes.compactMap { TitleParser.parse($0.lastPathComponent).episode }
        return airing.untiled(shown: shownSeason, seasons: seasons, episodes: numbers)
    }

    /// A file's mark: "New" on the episode just out (until you've watched it), when it airs on one not out yet.
    private func airingMark(_ f: URL, _ airing: EpisodeAiring) -> AiringMark? {
        let p = TitleParser.parse(f.lastPathComponent)
        guard let mark = airing.mark(season: p.season, episode: p.episode) else { return nil }
        return mark == .new && history.isWatched(f) ? nil : mark
    }

    /// Episodes not out yet with no file (1.22.1): when each airs, in your time zone.
    private var comingUp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coming up").font(.headline)
            ForEach(untiledEpisodes, id: \.self) { UpcomingEpisodeCard(episode: $0) }
        }
    }

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
                if showRatings, let r = meta?.rating { chip("★ \(r)", strong: true).accessibilityLabel("Rating \(r)") }
                if let y = meta?.year ?? parsed.year.map(String.init) { chip(y) }
                if let c = meta?.contentRating { chip(c) }
                // The release's own details, read by the one release-name parser.
                ForEach(releaseChips, id: \.self) { chip($0) }
                chip(file.pathExtension.uppercased())
                if let e = entry, e.isFinished { chip("Watched") }
            }
        }
    }

    /// Resolution, source, HDR and Dolby Vision from the file's name.
    private var releaseChips: [String] {
        let kinds: [ReleaseName.Kind] = [.resolution, .source, .hdr, .dolbyVision]
        return ReleaseName.file(file.lastPathComponent)?.attributes.filter { kinds.contains($0.kind) }.map(\.text) ?? parsed.resolution.map { [$0] } ?? []
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
        let airing = self.airing
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.isSeries || parsed.episode != nil ? "Episodes" : "Files").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text("\(siblings.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                ViewModeMenu(mode: $viewMode)
            }
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { s in
                            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { season = s } } label: {
                                let on = shownSeason == s
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
                        airing: airing.map { a in { airingMark($0, a) } },
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
            ForEach(untiledEpisodes, id: \.self) { UpcomingEpisodeCard(episode: $0) }
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
            // The wrong title, poster or episode names (1.29.0).
            Button { fixingMatch = true } label: { Label("Fix Match…", systemImage: "wand.and.stars") }
            if siblings.count > 1 {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete \(deleteLabel)", systemImage: "trash") }
                Button(role: .destructive) { confirmDeleteAll = true } label: { Label("Delete All \(siblings.count) Episodes", systemImage: "trash") }
            } else {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete File", systemImage: "trash") }
            }
        } label: {
            PageButtonLabel(systemName: "ellipsis", width: 56)
        }
        .accessibilityLabel("More")
        // Matched: back to Home, where the title comes up under its new name and poster.
        .sheet(isPresented: $fixingMatch) { FixMatchSheet(file: file) { dismiss() } }
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

    private func play(_ f: URL, fromStart: Bool = false) {
        // The title's own files; a single one on its own (1.27.0: it got the
        // whole library as its playlist, and Up Next offered another show).
        let list = LibraryMetaIndex.shared.kidsQueue(siblings.count > 1 ? siblings : [f], keeping: f)
        let queue = list.map { u -> MediaItem in
            var m = MediaItem(url: u.path, title: TitleParser.clean(u.lastPathComponent), source: .local)
            m.historyKey = u.path
            let p = TitleParser.parse(u.lastPathComponent)
            if p.episode != nil { m.anime = AnimeHint(title: p.title, episode: p.episode) }
            return m
        }
        PlayerPresenter.play(queue: queue, index: list.firstIndex(of: f) ?? 0, fromStart: fromStart)
    }

    private func restart() {
        play(file, fromStart: true)
    }
}

// MARK: - Landscape

extension View {
    /// The title pages' top buttons on a phone on its side (1.22.1). There's
    /// no status bar there, so the top of the safe area is the screen's top
    /// edge, and ‹ and ⋯ (pageButtons: a 44 pt bar at the top of the safe
    /// area) sat against it, their tops cut by the screen's rounded corner
    /// (simulator screenshots, iPhone 17 Pro Max on its side, library and
    /// Discover pages). They get a gap there, as the system bar's buttons
    /// have. Apply after pageButtons; the page's picture still reaches the top.
    func landscapeTopGap() -> some View { modifier(LandscapeTopGap()) }
}

private struct LandscapeTopGap: ViewModifier {
    @Environment(\.verticalSizeClass) private var vertical
    func body(content: Content) -> some View {
        content.safeAreaPadding(.top, vertical == .compact ? 12 : 0)
    }
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
                .font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40).menuLabelCircle()
        }
        .glassMenuCircle()
        .foregroundStyle(.primary)
        .accessibilityLabel("View, \((LibraryViewMode(rawValue: mode) ?? .grid).title)")
        .accessibilityIdentifier("viewModeMenu")
    }
}

/// Files in list or details style (grid is laid out by the caller).
struct LibraryList: View {
    /// How big an episode's picture is in each style (points, longest side):
    /// rows and tiles decode at it, and Home's prefetch uses the same size.
    static func picturePoints(_ mode: LibraryViewMode) -> CGFloat {
        switch mode {
        case .grid: return MediaTile.points(poster: false)
        case .details: return 150
        case .list: return 78
        }
    }

    let files: [URL]
    let mode: LibraryViewMode
    var current: URL? = nil
    var group: LibraryGroup? = nil
    /// A tracked show's marks on its episodes (1.22.1): "New", "Airs Tue 9:00 PM".
    var airing: ((URL) -> AiringMark?)? = nil
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
    /// Without a question from the caller, the list asks its own. Until 1.20.3
    /// Delete then removed the file at once (a folder's List and Details).
    @State private var ownPending: URL?
    private var pending: Binding<URL?> { pendingDelete ?? $ownPending }
    private var deleteFile: (URL) -> Void { delete ?? { LocalMediaStore.shared.delete($0) } }

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
                    .modifier(DeleteQuestion(file: f, pending: pending, delete: deleteFile))
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
                    .modifier(DeleteQuestion(file: f, pending: pending, delete: deleteFile))
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
                pending.wrappedValue = f
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
            .overlay(alignment: .topLeading) {
                if let mark = airing?(f) { AiringBadge(mark: mark).padding(6) }
            }
    }

    private func row(_ f: URL) -> some View {
        LibraryRow(file: f, mode: mode, highlighted: f == current, progress: history.entry(forURL: f.path)?.progress, size: LibraryOrganizer.info(f).size,
                   watched: history.isWatched(f), airing: airing?(f))
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
    /// A tracked show's mark on the episode (1.22.1): "New", "Airs Tue 9:00 PM".
    var airing: AiringMark? = nil
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
            if fixedTitle == nil, let tag = episodeTag {
                episodeText(tag)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.subheadline.weight(.semibold)).lineLimit(1)
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
        }
        .padding(detail ? 8 : 6)
        .background(rowBackground)
        .zoomSource(zoomWholeRow ? zoom : nil, cornerRadius: detail ? 16 : 12)
        .onAppear {
            LibTrace.image.log("row \(fixedTitle ?? file.lastPathComponent) (\(mode.rawValue)) appeared (loader #\(thumb.serial), picture \(thumb.image == nil ? "none yet" : "shown"))")
            thumb.load(key: file.path, fileURL: file, artwork: nil, lookupName: file.lastPathComponent, art: poster ? .poster : .wide, points: max(thumbW, thumbH))
        }
        .onDisappear { LibTrace.image.log("row \(fixedTitle ?? file.lastPathComponent) (\(mode.rawValue)) disappeared (loader #\(thumb.serial))") }
    }

    /// An episode: its number and size on a line of their own, then the title
    /// across the whole row (two lines in Details), then the synopsis
    /// (Details). Until 1.20.0 the title shared its one line with the number
    /// and the row with a size column, and was cut early ("The Crossroa…",
    /// "Beggars Ba…", 30 Oct screenshot).
    private func episodeText(_ tag: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(tag).font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                if let airing { AiringBadge(mark: airing, compact: true) }
                if let size {
                    Text(size.byteString).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                marks
            }
            .lineLimit(1)
            Text(headline).font(.subheadline.weight(.semibold)).lineLimit(detail ? 2 : 1)
            if detail {
                Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    // A row made again (a list redrawn) has its picture from its first frame.
                    if let img = thumb.image ?? ThumbLoader.cached(key: file.path, art: poster ? .poster : .wide, points: max(thumbW, thumbH)) {
                        Image(uiImage: img).resizable().scaledToFill().blur(radius: spoilerHidden && !poster ? 12 : 0)
                    } else { GeneratedArt(seed: file.lastPathComponent) }
                }
                .clipped()
            if !watched, let progress, progress > 0.01 { ArtProgressBar(progress: progress).frame(width: thumbW, height: thumbH) }
        }
        .clipShape(RoundedRectangle(cornerRadius: detail ? 12 : 8, style: .continuous))
        .zoomSource(zoomWholeRow ? nil : zoom, cornerRadius: detail ? 12 : 8)
    }
}

/// The navigation controller the title pages live in, and whether a page's
/// own move in it is running.
@MainActor
enum BackGesture {
    /// The navigation controller the title pages live in (set by BackSwipeProbe).
    static weak var nav: UINavigationController?

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
                startMoveLog(nav)
            }
            guard window != nil, watched.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var r: UIResponder? = self
                while let n = r, !(n is UINavigationController) { r = n.next }
                guard let nav = r as? UINavigationController else { dlog("nav", "back swipe probe: no navigation controller"); return }
                BackGesture.nav = nav
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
            // Only with the library trace on (1.28.2): ten wake-ups a second
            // for as long as a title page is open, for a log line.
            guard moveTimer == nil, PlayerPresenter.current == nil, LibTrace.on else { return }
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
            t.tolerance = 0.05
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
                dlog("nav", "back swipe (\(kind)) began")
            case .ended, .cancelled, .failed:
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
