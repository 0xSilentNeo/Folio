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
    /// The streams page zooms out of what was tapped (1.15.0, #2), like Add files.
    @Namespace private var streamsNS
    @ObservedObject private var history = HistoryStore.shared
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

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    backdrop(width: geo.size.width, wide: wide)
                    VStack(alignment: .leading, spacing: 18) {
                        // Genres above the description (from the title-page mockup).
                        if let g = m.genres, !g.isEmpty {
                            Text(g.prefix(5).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let d = m.description, !d.isEmpty {
                            ExpandableText(text: d, lines: 2)
                        }
                        HStack(spacing: 0) { findButton.zoomSource(ZoomSource("find", streamsNS), cornerRadius: 28); Spacer(minLength: 0) }
                        if castPosition == "top", let c = m.credits, !c.isEmpty { CastStrip(credits: c).padding(.horizontal, -16) }
                        if isSeries && (!allVideos.isEmpty || !allSeasons.isEmpty) { episodeList }
                        if loadingEpisodes && allVideos.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $go) { t in
            StreamsView(meta: m, video: t.video, seasonVideos: t.queue)
                .zoomDestination(t.source, in: streamsNS)
        }
        .task { await load() }
        .task(id: season) {
            guard usesIMDb, isSeries, !seasons.isEmpty else { return }
            loadingEpisodes = true
            let eps = await IMDbSource.episodes(id: resolvedID, season: season)
            if !Task.isCancelled { episodes = eps; loadingEpisodes = false }
        }
    }

    // MARK: Header

    private func backdrop(width: CGFloat, wide: Bool) -> some View {
        HeroHeader(height: wide ? 360 : width * 9 / 16 + 40) {
            if let art = m.background ?? m.poster, let u = URL(string: art) {
                CachedImage(url: u, maxPixel: 1280) { $0.resizable().scaledToFill() } placeholder: { Theme.card }
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
                .padding(.leading, wide ? 28 : 16)
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
            LazyVStack(spacing: 10) {
                ForEach(seasonEpisodes) { v in
                    Button { go = StreamsTarget(video: v, queue: [], source: "ep|" + v.id) } label: {
                        EpisodeRow(video: v, entry: history.entry(for: "addon:\(v.id)"))
                            .zoomSource(ZoomSource("ep|" + v.id, streamsNS), cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
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
            // Details and the season list don't depend on each other: fetch both at once.
            // Not `async let`: 1.12.0 left the season `async let` un-awaited on the
            // film path, and the Swift runtime aborted the app on every title
            // (swift_task_dealloc in asyncLet_finish — same stack on device and in CI).
            loadingEpisodes = preview.type != "movie"
            let seasonsTask: Task<[Int], Never>? = preview.type == "movie" ? nil : Task { await IMDbSource.seasons(id: id) }
            defer { seasonsTask?.cancel() }
            if var full = await IMDbSource.details(id: id, type: preview.type) {
                if full.poster == nil { full.poster = preview.poster }
                if full.background == nil { full.background = preview.background }
                if full.type == "movie" && preview.type == "series" { full.type = "series" }
                meta = full
            } else {
                var p = preview; p.id = id; meta = p
            }
            if m.type != "movie" {
                seasons = await (seasonsTask ?? Task { await IMDbSource.seasons(id: id) }).value
                if let first = seasons.first {
                    season = first
                    episodes = await IMDbSource.episodes(id: id, season: first)
                }
                loadingEpisodes = false
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
