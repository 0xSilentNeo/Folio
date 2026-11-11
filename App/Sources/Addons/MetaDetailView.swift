import SwiftUI
import QuartzCore

/// Discover title page: backdrop, poster beside a deciphering title, the
/// synopsis, one big Find-streams button, episodes, cast, links.
struct MetaDetailView: View {
    let preview: MetaItem
    let sourceAddon: InstalledAddon?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var meta: MetaItem?
    @State private var season: Int = 1
    @State private var seasons: [Int] = []
    @State private var episodes: [MetaVideo] = []
    @State private var loadingEpisodes = false
    /// TVmaze's date for each episode, "season:number" → "2026-11-13" (1.22.6).
    @State private var tvDates: [String: String] = [:]
    @State private var go: StreamsTarget?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomsFromTile) private var zooms
    /// The streams page zooms out of what was tapped (1.15.0, #2), like Add files.
    @Namespace private var streamsNS
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var kids = KidsProfile.shared
    @ObservedObject private var tracking = TrackingStore.shared
    /// The library and what it knows of its titles: the page's own files of
    /// this title follow them (1.30.0).
    @ObservedObject private var local = LocalMediaStore.shared
    @ObservedObject private var libraryMeta = LibraryMetaIndex.shared
    /// The library's files of this title, by identity ("tt…:1:5"): built
    /// when the page loads and when the library changes, never per row.
    @State private var libraryFiles: [String: [URL]] = [:]
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The title's details have been asked for (the kids profile decides on them, not on the list's tile).
    @State private var loaded = false
    @AppStorage(SettingsKey.castPosition) private var castPosition = "bottom"
    @AppStorage(SettingsKey.showRatings) private var showRatings = true

    private var m: MetaItem { meta ?? preview }
    private var resolvedID: String { meta?.id ?? preview.id }
    private var usesIMDb: Bool { resolvedID.hasPrefix("tt") }
    private var allSeasons: [Int] { usesIMDb ? seasons : m.seasons }
    private var allVideos: [MetaVideo] { usesIMDb ? episodes : (m.videos ?? []) }
    private var isSeries: Bool { m.type != "movie" }
    private var seasonEpisodes: [MetaVideo] {
        let now = Date()
        // Once, not per episode: `m.seasons` builds a set and sorts it each
        // time (quadratic for an addon anime with a thousand episodes).
        let anySeason = allSeasons.isEmpty
        return allVideos.filter { anySeason || $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
            .map { checkedDate($0, now: now) }
    }

    /// An episode's date, checked against TVmaze when it's out lately or
    /// still to come (1.22.6). IMDb's dates for coming episodes are often
    /// placeholders and can lag a change: on 5 Nov it had Tulsa King S4E5
    /// on Nov 14, TVmaze (weekly, Fridays) on Nov 13.
    private func checkedDate(_ v: MetaVideo, now: Date) -> MetaVideo {
        guard let s = v.season, let n = v.episode, let tv = tvDates["\(s):\(n)"],
              let pick = EpisodeDateCheck.pick(imdb: v.released, tvmaze: tv, now: now), pick != v.released else { return v }
        var u = v
        u.released = pick
        return u
    }

    /// Where the big button goes; episodes also have their own rows.
    struct StreamsTarget: Hashable, Identifiable {
        var video: MetaVideo?
        var queue: [MetaVideo]
        /// The view the page zooms out of: "find" (the big button) or "ep|<id>" (an episode row).
        var source = "find"
        /// Start over (1.30.0): the stream picked starts at 0.
        var fromStart = false
        /// The place kept by the episode's library file, when the stream has none of its own (1.30.0).
        var startAt: Double? = nil
        var id: String { video?.id ?? "title" }
    }

    /// The kids profile's answer when it isn't "allowed"; nil otherwise.
    /// Decided on the full details (their content rating), the list's tile
    /// only when they couldn't be loaded.
    private var kidsVerdict: KidsRules.Verdict? {
        guard let limits = kids.activeLimits else { return nil }
        let v = KidsRules.verdict(m, limits: limits)
        return v == .allowed ? nil : v
    }

    var body: some View {
        if kids.isOn && !loaded {
            LoadingQuips()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
                .pageButtons(zooms: zooms, back: { dismiss() }) { EmptyView() }
                .landscapeTopGap()
                .task { await load(); loaded = true }
        } else if let v = kidsVerdict {
            KidsBlockedView(verdict: v)
                .pageButtons(zooms: zooms, back: { dismiss() }) { EmptyView() }
                .landscapeTopGap()
        } else {
            // Handoff (1.22.0): the other device opens the same title. The
            // addon by its manifest id: its address can hold a key.
            page.handoffTitle(HandoffActivity.Payload(target: .discover(id: resolvedID, type: m.type, name: m.name, poster: m.poster,
                                                                        addon: sourceAddon?.manifest.id)))
        }
    }

    private var page: some View {
        GeometryReader { geo in
            // The text in a readable column, centred, on a wide iPad window
            // (1.30.0); the picture keeps the whole width.
            let side = PageLayout(width: geo.size.width).readableSide(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    backdrop(geo.size)
                    VStack(alignment: .leading, spacing: 18) {
                        // Genres above the description (from the title-page mockup).
                        if let g = m.genres, !g.isEmpty {
                            Text(g.prefix(5).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let d = m.description, !d.isEmpty {
                            ExpandableText(text: d, lines: 2)
                        }
                        // Track (1.21.0): series only, once the page knows which show it is.
                        TitleButtonRow {
                            findButton.zoomSource(ZoomSource("find", streamsNS), cornerRadius: 28)
                            // As on the library's page (1.30.0): from the beginning, beside Resume.
                            if let again = startOverTarget {
                                Button { go = again } label: {
                                    Label("Start over", systemImage: "arrow.counterclockwise").font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 16).frame(height: 44).glass(cornerRadius: 22, interactive: true)
                                }
                                .buttonStyle(PressStyle())
                            }
                            if canTrack { TrackButton(show: trackedShow) }
                        }
                        if canTrack { TrackStatusLine(show: trackedShow).padding(.top, -8) }
                        if castPosition == "top", let c = m.credits, !c.isEmpty { CastStrip(credits: c, inset: side).padding(.horizontal, -side) }
                        if isSeries && (!allVideos.isEmpty || !allSeasons.isEmpty) {
                            episodeList
                        } else if !untiledEpisodes.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Coming up").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                                ForEach(untiledEpisodes, id: \.self) { UpcomingEpisodeCard(episode: $0) }
                            }
                        }
                        if loadingEpisodes && allVideos.isEmpty { LoadingQuips().padding(.vertical, 8) }
                        if castPosition != "top", let c = m.credits, !c.isEmpty { CastStrip(credits: c, inset: side).padding(.horizontal, -side) }
                        if let d = m.director, !d.isEmpty {
                            Text((isSeries ? "Created by " : "Directed by ") + d.prefix(3).joined(separator: ", "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        TitleLinks(name: m.name, year: m.releaseInfo.map { String($0.prefix(4)) }, type: m.type, imdbID: usesIMDb ? resolvedID : nil)
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
        .background(Theme.background.ignoresSafeArea())
        .pageButtons(zooms: zooms, back: { dismiss() }) {
            // Watchlist, then ⋯, as on the library's page (1.30.0).
            HStack(spacing: 8) {
                WatchlistButton(meta: m)
                moreButton
            }
        }
        .landscapeTopGap()
        // Landscape phone: the floating tab bar sat on Track and the episodes,
        // as it did on the library's title page (1.22.1).
        .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        .navigationDestination(item: $go) { t in
            // Zooms only from a page that draws its own bar (see pageButtons).
            StreamsView(meta: m, video: t.video, seasonVideos: t.queue, fromStart: t.fromStart, startAt: t.startAt)
                .zoomDestination(t.source, in: streamsNS, zoom: zooms)
        }
        .task { LibTrace.title.event("appeared", "addon title page appeared"); await load(); loaded = true }
        // The library's files of this title (1.30.0), once it's known which
        // title it is, and again when the library or its metadata changes.
        .task(id: LibraryKey(imdb: usesIMDb ? resolvedID : "", files: local.files.count, metas: libraryMeta.metas.count)) {
            let found = usesIMDb ? await WatchedState.libraryFiles(imdb: resolvedID) : [:]
            if !Task.isCancelled, found != libraryFiles { libraryFiles = found }
        }
        .task(id: season) {
            guard usesIMDb, isSeries, !seasons.isEmpty else { return }
            loadingEpisodes = true
            let eps = await IMDbSource.episodes(id: resolvedID, season: season)
            if !Task.isCancelled { episodes = eps; loadingEpisodes = false; logDateChecks() }
        }
        // A running series' dates, from TVmaze (1.22.6). Not anime: TVmaze
        // and IMDb often number their seasons differently.
        .task(id: loaded) {
            guard loaded, usesIMDb, isSeries, !m.hasEnded, trackedShow.anime != true,
                  let tv = await AiringService.shared.pageSchedule(imdb: resolvedID, episodes: true), !Task.isCancelled else { return }
            tvDates = tv.dates
            logDateChecks()
        }
    }

    /// The season's dates that TVmaze changed, in the log.
    private func logDateChecks() {
        guard !tvDates.isEmpty else { return }
        let now = Date()
        let changed = allVideos.filter { allSeasons.isEmpty || $0.season == season }.compactMap { v -> String? in
            let c = checkedDate(v, now: now)
            return c.released == v.released ? nil : "S\(v.season ?? 0)E\(v.episode ?? 0) \(v.released ?? "none") → \(c.released ?? "none")"
        }
        if !changed.isEmpty { dlog("airdates", "\(m.name): TVmaze's dates instead of IMDb's: " + changed.joined(separator: ", ")) }
    }

    // MARK: Header

    /// The backdrop picture's address for a title: its wide art, else its poster.
    private func backdropURL(_ meta: MetaItem) -> URL? {
        (meta.background.flatMap { IMDbSource.sized($0, width: HeroMetrics.pixels) } ?? meta.poster).flatMap(URL.init(string:))
    }

    private func backdrop(_ size: CGSize) -> some View {
        HeroHeader(height: HeroMetrics.height(size)) {
            if let u = backdropURL(m) {
                // While a better backdrop loads, the one the page opened with
                // stays (1.26.0): until then the page went blank between the two.
                CachedImage(url: u, maxPixel: CGFloat(HeroMetrics.pixels)) { $0.resizable().scaledToFill() } placeholder: {
                    if let first = backdropURL(preview), first != u {
                        CachedImage(url: first, maxPixel: CGFloat(HeroMetrics.pixels)) { $0.resizable().scaledToFill() } placeholder: { Theme.card }
                    } else { Theme.card }
                }
            } else { Theme.card }
        } content: {
                // Accessibility text sizes: the title under the poster, as on the
                // library's title page (1.27.0; a narrow column beside it).
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    : AnyLayout(HStackLayout(alignment: .bottom, spacing: 14))
                layout {
                    if let poster = m.poster, let u = URL(string: poster) {
                        // The tile's own picture shows while its sharper copy loads.
                        CachedImage(url: u, maxPixel: 400) { $0.resizable().scaledToFill() } placeholder: {
                            if let first = preview.poster.flatMap(URL.init(string:)), first != u {
                                CachedImage(url: first, maxPixel: 400) { $0.resizable().scaledToFill() } placeholder: { Theme.card }
                            } else { Theme.card }
                        }
                            .accessibilityHidden(true)
                            .frame(width: 122, height: 191)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Theme.shadow, radius: 12, y: 6)
                    }
                    titleBlock.padding(.bottom, 6)
                }
                .padding(.leading, PageLayout(width: size.width).readableSide(size.width > 700 ? 28 : 16))
                .padding(.trailing, PageLayout(width: size.width).readableSide(16))
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The text size's title style (1.27.0: a fixed 28 pt, two lines).
            DecipherText(text: m.name, font: .system(.title, design: .rounded, weight: .bold)).lineLimit(5)
            if m.isAnime, let o = m.originalName, !o.isEmpty {
                Text(o).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(2)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if showRatings, let r = m.imdbRating { chip("★ \(r)", strong: true).accessibilityLabel("IMDb rating \(r)") }
                if let y = m.releaseInfo { chip(y) }
                if let c = m.contentRating { chip(c) }
                if let r = m.runtime { chip(r) }
                if isSeries, allSeasons.count > 1 { chip("\(allSeasons.filter { $0 > 0 }.count) seasons") }
            }
        }
    }

    private func chip(_ s: String, strong: Bool = false) -> some View {
        Text(s).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(strong ? Theme.onAccent : .primary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(strong ? Theme.accent : Theme.fill, in: Capsule())
    }

    // MARK: Tracking

    /// A series the page knows (a TMDB tile's IMDb id isn't known yet).
    private var canTrack: Bool { isSeries && !resolvedID.hasPrefix("tmdb:") }
    private var trackedShow: TrackedShow { TrackedShow(meta: m, imdbID: usesIMDb ? resolvedID : nil) }

    /// The tracked show's schedule for the episode tiles (1.22.1); nil when
    /// it isn't tracked. No request of its own: the tracker's schedule.
    private var airing: EpisodeAiring? {
        guard canTrack, let s = tracking.tracked(like: trackedShow) else { return nil }
        return EpisodeAiring(show: s, now: Date(), newestSeason: allSeasons.filter { $0 > 0 }.max())
    }

    /// Episodes not out yet that the list has no row for (IMDb often lists
    /// only the next one), under the season shown.
    private var untiledEpisodes: [AiringEpisode] {
        guard let airing else { return [] }
        return airing.untiled(shown: allSeasons.isEmpty ? nil : season, seasons: allSeasons, episodes: seasonEpisodes.compactMap(\.episode))
    }

    // MARK: Find streams

    @ViewBuilder
    private var findButton: some View {
        let eps = seasonEpisodes
        if isSeries, eps.count > 1 {
            // Whole season, from the first episode not finished yet, in the
            // library or from a stream (1.30.0: only streams counted, so a
            // season watched from your own files began at episode 1 again).
            let startAt = WatchedState.firstUnwatched(eps.map { state($0.id)?.isFinished == true })
            let ep = eps[startAt]
            TiltPlayButton(title: startAt == 0 ? (season == 0 ? "Play all specials" : "Play Season \(season)") : "Continue Season \(season)",
                           subtitle: startAt == 0 ? "\(eps.count) episodes" : "from episode \(ep.episode ?? startAt + 1)",
                           icon: "play.square.stack.fill") {
                go = StreamsTarget(video: ep, queue: Array(eps[startAt...]), startAt: carried(ep.id))
            }
        } else if isSeries, eps.count == 1, let ep = eps.first {
            TiltPlayButton(title: "Find streams", subtitle: ep.title) { go = StreamsTarget(video: ep, queue: [], startAt: carried(ep.id)) }
        } else if !isSeries || (!loadingEpisodes && allSeasons.isEmpty) {
            let resume = resumeLabel(for: m.id)
            TiltPlayButton(title: resume == nil ? "Find streams" : "Resume", subtitle: resume) { go = StreamsTarget(video: nil, queue: [], startAt: carried(m.id)) }
        } else {
            // Episodes still loading: keep the button's place so the page doesn't jump.
            TiltPlayButton(title: "Find streams", subtitle: "loading episodes…", shimmer: false) {}
                .opacity(0.55).allowsHitTesting(false)
        }
    }

    private func resumeLabel(for videoId: String) -> String? {
        // The stream's own place first, as the player takes it (carried):
        // the button said the library file's newer one and started at the stream's.
        let own = history.entry(for: "addon:\(videoId)")
        guard let e = own?.canResume == true ? own : state(videoId), e.canResume else { return nil }
        return "from \(PlayerModel.format(e.position))"
    }

    /// The episode the big button and ⋯ → Play start with: the first of the
    /// season shown that isn't watched on either side.
    private func nextIndex(_ eps: [MetaVideo]) -> Int {
        WatchedState.firstUnwatched(eps.map { state($0.id)?.isFinished == true })
    }

    /// What the big button would play, from the beginning: only when that
    /// has a place to resume from (the library's "Start over", 1.30.0).
    private var startOverTarget: StreamsTarget? {
        let eps = seasonEpisodes
        if isSeries {
            guard !eps.isEmpty else { return nil }
            let i = nextIndex(eps)
            guard state(eps[i].id)?.canResume == true else { return nil }
            return StreamsTarget(video: eps[i], queue: eps.count > 1 ? Array(eps[i...]) : [], fromStart: true)
        }
        guard state(m.id)?.canResume == true else { return nil }
        return StreamsTarget(video: nil, queue: [], fromStart: true)
    }

    // MARK: One watched state (1.30.0, WatchedState)

    /// The task that finds the library's files of this title runs again when any of these changes.
    private struct LibraryKey: Hashable { var imdb: String; var files: Int; var metas: Int }

    /// The library's files of an episode (a film: of the title).
    private func files(for videoID: String) -> [URL] {
        guard !libraryFiles.isEmpty, let id = WatchedState.identity(videoID: videoID) else { return [] }
        return libraryFiles[id] ?? []
    }

    /// An episode's state on either side: its addon entry or a library file's.
    private func state(_ videoID: String) -> HistoryEntry? {
        let own = history.entry(for: "addon:\(videoID)")
        let files = files(for: videoID)
        return files.isEmpty ? own : WatchedState.combined([own] + files.map { history.entry(forURL: $0.path) })
    }

    /// The place a stream starts at when only the library file has one.
    private func carried(_ videoID: String) -> Double? {
        let files = files(for: videoID)
        guard !files.isEmpty else { return nil }
        return WatchedState.carriedPosition(own: history.entry(for: "addon:\(videoID)"), others: files.map { history.entry(forURL: $0.path) })
    }

    /// What's marked with an episode: its addon entry and its library files.
    private func unit(_ videoID: String) -> [String] {
        ["addon:\(videoID)"] + files(for: videoID).map(\.path)
    }

    /// The history item for a key that has no entry yet.
    private func historyItem(_ key: String) -> MediaItem {
        guard key.hasPrefix("addon:") else { return HistoryStore.libraryItem(key) }
        let label = allVideos.first { "addon:\($0.id)" == key }?.label
        return WatchedState.addonItem(key: key, name: m.name, poster: m.poster, type: m.type, metaID: m.id, label: label)
    }

    // MARK: More

    /// The library page's ⋯ (1.30.0): Play, the watched marks, Share.
    private var moreButton: some View {
        Menu {
            let eps = seasonEpisodes
            let airing = self.airing
            let out = eps.filter { v in
                // As the rows have it: the tracker's "airs" mark counts too.
                if v.airsLater() { return false }
                if case .airs? = airing?.mark(season: v.season, episode: v.episode) { return false }
                return true
            }
            if isSeries {
                if !eps.isEmpty {
                    let i = nextIndex(eps)
                    Button { go = StreamsTarget(video: eps[i], queue: eps.count > 1 ? Array(eps[i...]) : [], startAt: carried(eps[i].id)) } label: { Label("Play", systemImage: "play") }
                }
                if !out.isEmpty {
                    WatchedMenuItems(units: out.map { unit($0.id) }, scope: allSeasons.count > 1 ? .season : .all, item: historyItem)
                }
            } else {
                Button { go = StreamsTarget(video: nil, queue: [], startAt: carried(m.id)) } label: { Label("Play", systemImage: "play") }
                WatchedMenuItems(units: [unit(m.id)], item: historyItem)
            }
            if usesIMDb, let link = URL(string: "https://www.imdb.com/title/\(resolvedID)/") {
                ShareLink(item: link) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        } label: {
            PageButtonLabel(systemName: "ellipsis", width: 56)
        }
        .accessibilityLabel("More")
    }

    // MARK: Episodes

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Episodes").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                let n = seasonEpisodes.count
                if n > 0 { Text("\(n)").font(.subheadline).foregroundStyle(.secondary) }
            }
            if allSeasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(allSeasons, id: \.self) { s in
                            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { season = s } } label: {
                                Text(s == 0 ? "Specials" : "Season \(s)").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(season == s ? Theme.onAccent : .primary)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background(season == s ? Theme.accent : Theme.fill, in: Capsule())
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
            }
            let airing = self.airing
            LazyVStack(spacing: 10) {
                ForEach(seasonEpisodes) { v in
                    let mark = airing?.mark(season: v.season, episode: v.episode)
                    // Not out yet: no streams page with nothing on it (1.22.2).
                    // Also while its badge says it airs later today: IMDb's
                    // date-only release counts from midnight (review, 5 Nov).
                    let notOut = v.airsLater() || { if case .airs = mark { return true }; return false }()
                    let entry = state(v.id)
                    Button { go = StreamsTarget(video: v, queue: [], source: "ep|" + v.id, startAt: carried(v.id)) } label: {
                        // A tracked episode's time is the badge's, in your time zone: the
                        // row's own date is the network's (IMDb's US date), so it's left out.
                        // Only under "Airs…": the "New" badge has no date (1.22.6; until
                        // then Tulsa King's newest episode showed none).
                        EpisodeRow(video: { if case .airs = mark { var u = v; u.released = nil; return u }; return v }(), entry: entry)
                            .overlay(alignment: .topLeading) {
                                if let mark { AiringBadge(mark: mark, maxWidth: 116).padding(14) }
                            }
                            .zoomSource(ZoomSource("ep|" + v.id, streamsNS), cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(notOut)
                    .opacity(notOut ? 0.6 : 1)
                    .accessibilityHint(notOut ? "Not out yet." : "")
                    .accessibilityValue(WatchedState.spoken(entry))
                    // As the library's episode rows have (1.30.0).
                    .contextMenu {
                        if !notOut {
                            Button { go = StreamsTarget(video: v, queue: [], startAt: carried(v.id)) } label: { Label("Play", systemImage: "play") }
                            WatchedMenuItems(units: [unit(v.id)], item: historyItem)
                        }
                    }
                }
                ForEach(untiledEpisodes, id: \.self) { UpcomingEpisodeCard(episode: $0) }
            }
        }
        .padding(.top, 6)
    }

    // MARK: Loading

    private func load() async {
        guard meta == nil else { return }
        var id = preview.id
        if id.hasPrefix("tmdb:") {
            guard let imdb = await TMDB.imdbID(for: preview) else { return }
            id = imdb
        }
        // Discover's Airing now anime (1.26.0): its IMDb title, by name.
        if id.hasPrefix("anilist:") {
            guard let imdb = await AnimeLink.imdbID(for: preview) else { return }
            id = imdb
        }
        if id.hasPrefix("tt") {
            let t0 = CACurrentMediaTime()
            let signpost = LibTrace.title.begin("title page data")
            defer { LibTrace.title.end("title page data", signpost) }
            // Details and the season list don't depend on each other: fetch both at once.
            // Not `async let`: 1.12.0 left the season `async let` un-awaited on the
            // film path, and the Swift runtime aborted the app on every title
            // (swift_task_dealloc in asyncLet_finish — same stack on device and in CI).
            loadingEpisodes = preview.type != "movie"
            // Lab: a slow page, to see its loading lines (LoadingQuipsUITests).
            if CommandLine.arguments.contains("-labSlowTitle") { try? await Task.sleep(nanoseconds: 6_000_000_000) }
            let seasonsTask: Task<[Int], Never>? = preview.type == "movie" ? nil : Task { await IMDbSource.seasons(id: id) }
            defer { seasonsTask?.cancel() }
            if var full = await IMDbSource.details(id: id, type: preview.type) {
                // The poster you tapped stays the page's poster, only sharper
                // (1.26.0). IMDb's title page often has other artwork than its
                // lists or TMDB's, and the page swapped to it a moment after
                // opening (8 Nov recording: 9-1-1, The Lowdown).
                full.poster = TileArt.sharper(poster: preview.poster) ?? full.poster
                // A list's wide picture is kept too; a list that only has the
                // poster (IMDb's) gets the title page's real backdrop.
                if let b = preview.background, !TileArt.sameImage(b, preview.poster) {
                    full.background = TileArt.sharper(backdrop: b)
                } else if full.background == nil {
                    full.background = preview.background
                }
                if full.type == "movie" && preview.type == "series" { full.type = "series" }
                meta = full
            } else {
                // Left before the details came (Find streams tapped early): the
                // load was cancelled, not empty. Keep `meta` unset so coming back
                // loads it again; until 1.20.3 the bare preview stayed for good,
                // with no cast, plot or runtime (review, 2 Nov).
                guard !Task.isCancelled else { return }
                var p = preview; p.id = id; meta = p
            }
            if m.type != "movie" {
                seasons = await (seasonsTask ?? Task { await IMDbSource.seasons(id: id) }).value
                // The season picker's task loads a season's episodes; here only
                // the first season, when the picker already shows it. Until
                // 1.20.3 this always loaded the first season, and when it came
                // after a season you'd tapped meanwhile, it replaced that
                // season's episodes: the list went empty and the button stuck
                // on "loading episodes…" (review, 2 Nov).
                if let first = seasons.first, season != first {
                    season = first
                } else if let first = seasons.first {
                    let eps = await IMDbSource.episodes(id: id, season: first)
                    if season == first { episodes = eps; loadingEpisodes = false }
                } else {
                    loadingEpisodes = false
                }
            }
            dlog("perf", String(format: "title page %@ ready in %.0f ms", id, (CACurrentMediaTime() - t0) * 1000))
        } else {
            guard let addon = AddonStore.shared.metaAddon(type: preview.type, id: id, preferred: sourceAddon) else { return }
            if var full = try? await AddonAPI.meta(addon, type: preview.type, id: id) {
                full.poster = preview.poster ?? full.poster
                meta = full
            }
            if let first = meta?.seasons.first { season = first }
        }
    }
}
