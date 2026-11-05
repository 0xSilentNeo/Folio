import SwiftUI
import QuartzCore

/// Discover title page: backdrop, poster beside a deciphering title, the
/// synopsis, one big Find-streams button, episodes, cast, links.
struct MetaDetailView: View {
    let preview: MetaItem
    let sourceAddon: InstalledAddon?
    @State private var meta: MetaItem?
    @State private var season: Int = 1
    @State private var seasons: [Int] = []
    @State private var episodes: [MetaVideo] = []
    @State private var loadingEpisodes = false
    @State private var go: StreamsTarget?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomsFromTile) private var zooms
    /// The streams page zooms out of what was tapped (1.15.0, #2), like Add files.
    @Namespace private var streamsNS
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var kids = KidsProfile.shared
    @ObservedObject private var tracking = TrackingStore.shared
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
        allVideos.filter { allSeasons.isEmpty || $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    /// Where the big button goes; episodes also have their own rows.
    struct StreamsTarget: Hashable, Identifiable {
        var video: MetaVideo?
        var queue: [MetaVideo]
        /// The view the page zooms out of: "find" (the big button) or "ep|<id>" (an episode row).
        var source = "find"
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
            let wide = geo.size.width > 700
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
                            if canTrack { TrackButton(show: trackedShow) }
                        }
                        if canTrack { TrackStatusLine(show: trackedShow).padding(.top, -8) }
                        if castPosition == "top", let c = m.credits, !c.isEmpty { CastStrip(credits: c).padding(.horizontal, -16) }
                        if isSeries && (!allVideos.isEmpty || !allSeasons.isEmpty) {
                            episodeList
                        } else if !untiledEpisodes.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Coming up").font(.title3.weight(.bold))
                                ForEach(untiledEpisodes, id: \.self) { UpcomingEpisodeCard(episode: $0) }
                            }
                        }
                        if loadingEpisodes && allVideos.isEmpty { LoadingQuips().padding(.vertical, 8) }
                        if castPosition != "top", let c = m.credits, !c.isEmpty { CastStrip(credits: c).padding(.horizontal, -16) }
                        if let d = m.director, !d.isEmpty {
                            Text((isSeries ? "Created by " : "Directed by ") + d.prefix(3).joined(separator: ", "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        TitleLinks(name: m.name, year: m.releaseInfo.map { String($0.prefix(4)) }, type: m.type, imdbID: usesIMDb ? resolvedID : nil)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .topScrollScrim()
        }
        .background(Theme.background.ignoresSafeArea())
        .pageButtons(zooms: zooms, back: { dismiss() }) { EmptyView() }
        .landscapeTopGap()
        // Landscape phone: the floating tab bar sat on Track and the episodes,
        // as it did on the library's title page (1.22.1).
        .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        .navigationDestination(item: $go) { t in
            // Zooms only from a page that draws its own bar (see pageButtons).
            StreamsView(meta: m, video: t.video, seasonVideos: t.queue)
                .zoomDestination(t.source, in: streamsNS, zoom: zooms)
        }
        .task { LibTrace.title.event("appeared", "addon title page appeared"); await load(); loaded = true }
        .task(id: season) {
            guard usesIMDb, isSeries, !seasons.isEmpty else { return }
            loadingEpisodes = true
            let eps = await IMDbSource.episodes(id: resolvedID, season: season)
            if !Task.isCancelled { episodes = eps; loadingEpisodes = false }
        }
    }

    // MARK: Header

    private func backdrop(_ size: CGSize) -> some View {
        HeroHeader(height: HeroMetrics.height(size)) {
            if let art = m.background.flatMap({ IMDbSource.sized($0, width: HeroMetrics.pixels) }) ?? m.poster, let u = URL(string: art) {
                CachedImage(url: u, maxPixel: CGFloat(HeroMetrics.pixels)) { $0.resizable().scaledToFill() } placeholder: { Theme.card }
            } else { Theme.card }
        } content: {
                HStack(alignment: .bottom, spacing: 14) {
                    if let poster = m.poster, let u = URL(string: poster) {
                        CachedImage(url: u, maxPixel: 400) { $0.resizable().scaledToFill() } placeholder: { Theme.card }
                            .frame(width: 122, height: 191)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Theme.shadow, radius: 12, y: 6)
                    }
                    titleBlock.padding(.bottom, 6)
                }
                .padding(.leading, size.width > 700 ? 28 : 16)
                .padding(.trailing, 16)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            DecipherText(text: m.name, font: .system(size: 28, weight: .bold, design: .rounded)).lineLimit(2)
            if m.isAnime, let o = m.originalName, !o.isEmpty {
                Text(o).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(2)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if showRatings, let r = m.imdbRating { chip("★ \(r)", strong: true) }
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
            // Whole season, from the first episode not finished yet.
            let startAt = eps.firstIndex { history.entry(for: "addon:\($0.id)")?.isFinished != true } ?? 0
            let ep = eps[startAt]
            TiltPlayButton(title: startAt == 0 ? (season == 0 ? "Play all specials" : "Play Season \(season)") : "Continue Season \(season)",
                           subtitle: startAt == 0 ? "\(eps.count) episodes" : "from episode \(ep.episode ?? startAt + 1)",
                           icon: "play.square.stack.fill") {
                go = StreamsTarget(video: ep, queue: Array(eps[startAt...]))
            }
        } else if isSeries, eps.count == 1, let ep = eps.first {
            TiltPlayButton(title: "Find streams", subtitle: ep.title) { go = StreamsTarget(video: ep, queue: []) }
        } else if !isSeries || (!loadingEpisodes && allSeasons.isEmpty) {
            let resume = resumeLabel(for: m.id)
            TiltPlayButton(title: resume == nil ? "Find streams" : "Resume", subtitle: resume) { go = StreamsTarget(video: nil, queue: []) }
        } else {
            // Episodes still loading: keep the button's place so the page doesn't jump.
            TiltPlayButton(title: "Find streams", subtitle: "loading episodes…", shimmer: false) {}
                .opacity(0.55).allowsHitTesting(false)
        }
    }

    private func resumeLabel(for videoId: String) -> String? {
        guard let e = history.entry(for: "addon:\(videoId)"), e.canResume else { return nil }
        return "from \(PlayerModel.format(e.position))"
    }

    // MARK: Episodes

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Episodes").font(.title3.weight(.bold))
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
                    let notOut = v.airsLater()
                    Button { go = StreamsTarget(video: v, queue: [], source: "ep|" + v.id) } label: {
                        // A tracked episode's time is the badge's, in your time zone: the
                        // row's own date is the network's (IMDb's US date), so it's left out.
                        EpisodeRow(video: mark == nil ? v : { var u = v; u.released = nil; return u }(), entry: history.entry(for: "addon:\(v.id)"))
                            .overlay(alignment: .topLeading) {
                                if let mark { AiringBadge(mark: mark, maxWidth: 116).padding(14) }
                            }
                            .zoomSource(ZoomSource("ep|" + v.id, streamsNS), cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(notOut)
                    .opacity(notOut ? 0.6 : 1)
                    .accessibilityHint(notOut ? "Not out yet." : "")
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
                if full.poster == nil { full.poster = preview.poster }
                if full.background == nil { full.background = preview.background }
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
                if full.poster == nil { full.poster = preview.poster }
                meta = full
            }
            if let first = meta?.seasons.first { season = first }
        }
    }
}
