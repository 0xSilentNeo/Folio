import SwiftUI

// MARK: - Discover

struct DiscoverView: View {
    @ObservedObject private var store = AddonStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if store.addons.isEmpty {
                        emptyState
                    }
                    ForEach(rows, id: \.key) { row in
                        CatalogRow(addon: row.addon, catalog: row.catalog)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("Discover")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AddonSearchView() } label: { Image(systemName: "magnifyingglass") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AddonsManagerView() } label: { Image(systemName: "puzzlepiece.extension") }
                }
            }
            .refreshable { await store.refreshAll() }
        }
    }

    private struct Row { let key: String; let addon: InstalledAddon; let catalog: AddonManifest.Catalog }

    private var rows: [Row] {
        store.addons.flatMap { a in
            a.manifest.catalogs.filter(\.isBrowsable).prefix(12).map { c in
                Row(key: a.id + c.type + c.id, addon: a, catalog: c)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("No addons yet").font(.headline)
            Text("Add Stremio-compatible addons (the same ones Nuvio uses) to browse catalogs and find streams.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            NavigationLink("Manage addons") { AddonsManagerView() }.buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

struct CatalogRow: View {
    let addon: InstalledAddon
    let catalog: AddonManifest.Catalog
    @State private var metas: [MetaItem] = []
    @State private var failed = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(catalogTitle).font(.title3.weight(.bold))
                    Text(addon.manifest.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                NavigationLink {
                    CatalogGridView(addon: addon, catalog: catalog, title: catalogTitle)
                } label: {
                    Text("See all").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    if !loaded {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12).fill(Theme.card).frame(width: 118, height: 177)
                        }
                    }
                    ForEach(metas) { m in
                        NavigationLink { MetaDetailView(preview: m, sourceAddon: addon) } label: {
                            PosterCard(meta: m, width: catalogShape == "landscape" ? 210 : 118)
                        }
                        .buttonStyle(.plain)
                    }
                    if failed {
                        Text("Couldn't load").font(.caption).foregroundStyle(.secondary).frame(height: 177)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .task {
            guard !loaded else { return }
            var extra: [String: String] = [:]
            if catalog.requiredExtras.contains("genre"), let g = catalog.genreOptions.first { extra["genre"] = g }
            do { metas = try await AddonAPI.catalog(addon, catalog, extra: extra) } catch { failed = true }
            loaded = true
        }
    }

    private var catalogShape: String? { metas.first?.posterShape }
    private var catalogTitle: String {
        let n = catalog.name ?? catalog.id
        return "\(n) · \(catalog.type.capitalized)"
    }
}

struct PosterCard: View {
    let meta: MetaItem
    var width: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: meta.poster, aspect: meta.posterShape == "landscape" ? 16.0 / 9.0 : (meta.posterShape == "square" ? 1 : 2.0 / 3.0))
                .frame(width: width)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            Text(meta.name).font(.caption.weight(.medium)).lineLimit(1).frame(width: width, alignment: .leading)
            if let r = meta.releaseInfo {
                Text(r).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct CatalogGridView: View {
    let addon: InstalledAddon
    let catalog: AddonManifest.Catalog
    let title: String
    @State private var metas: [MetaItem] = []
    @State private var loading = false
    @State private var exhausted = false
    @State private var genre: String?

    var body: some View {
        ScrollView {
            if !catalog.genreOptions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        if !catalog.requiredExtras.contains("genre") {
                            chip("All", selected: genre == nil) { genre = nil }
                        }
                        ForEach(catalog.genreOptions, id: \.self) { g in chip(g, selected: genre == g) { genre = g } }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
                ForEach(metas) { m in
                    NavigationLink { MetaDetailView(preview: m, sourceAddon: addon) } label: {
                        PosterCard(meta: m, width: 108)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if m.id == metas.last?.id { Task { await loadMore() } } }
                }
            }
            .padding(16)
            if loading { ProgressView().padding() }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if catalog.requiredExtras.contains("genre") { genre = catalog.genreOptions.first }
            if metas.isEmpty { await loadMore() }
        }
        .onChange(of: genre) { _, _ in
            metas = []; exhausted = false
            Task { await loadMore() }
        }
    }

    private func chip(_ t: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        defer { loading = false }
        var extra: [String: String] = [:]
        if let genre { extra["genre"] = genre }
        if !metas.isEmpty { extra["skip"] = String(metas.count) }
        let page = (try? await AddonAPI.catalog(addon, catalog, extra: extra)) ?? []
        let known = Set(metas.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        if fresh.isEmpty { exhausted = true }
        metas += fresh
    }
}

// MARK: - Meta detail

struct MetaDetailView: View {
    let preview: MetaItem
    let sourceAddon: InstalledAddon?
    @State private var meta: MetaItem?
    @State private var season: Int = 1
    @ObservedObject private var history = HistoryStore.shared

    private var m: MetaItem { meta ?? preview }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    Text(m.name).font(.largeTitle.weight(.bold))
                    HStack(spacing: 10) {
                        if let r = m.releaseInfo { tag(r) }
                        if let r = m.runtime { tag(r) }
                        if let r = m.imdbRating { tag("★ \(r)") }
                    }
                    if let g = m.genres, !g.isEmpty {
                        Text(g.prefix(4).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if m.type == "movie" || (m.videos ?? []).isEmpty {
                        NavigationLink {
                            StreamsView(meta: m, video: nil)
                        } label: {
                            Label(resumeLabel(for: m.id) ?? "Find streams", systemImage: "play.fill")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(.white)
                        }
                    }
                    if let d = m.description {
                        Text(d).font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 16)

                if let videos = m.videos, !videos.isEmpty, m.type != "movie" {
                    episodes(videos)
                }
            }
            .padding(.bottom, 30)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard meta == nil, let addon = AddonStore.shared.metaAddon(type: preview.type, id: preview.id, preferred: sourceAddon) else { return }
            meta = try? await AddonAPI.meta(addon, type: preview.type, id: preview.id)
            if let first = meta?.seasons.first { season = first }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            PosterImage(url: m.background ?? m.poster, aspect: 16.0 / 9.0, cornerRadius: 0)
                .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))
            if let logo = m.logo, let u = URL(string: logo) {
                AsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: { EmptyView() }
                    .frame(maxWidth: 220, maxHeight: 80)
                    .padding(16)
            }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.card, in: Capsule())
    }

    private func resumeLabel(for videoId: String) -> String? {
        guard let e = history.entry(for: "addon:\(videoId)"), e.canResume else { return nil }
        return "Resume from \(PlayerModel.format(e.position))"
    }

    @ViewBuilder
    private func episodes(_ videos: [MetaVideo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(m.seasons, id: \.self) { s in
                            Button { season = s } label: {
                                Text(s == 0 ? "Specials" : "Season \(s)").font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(season == s ? Theme.accent : Theme.card, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            LazyVStack(spacing: 10) {
                ForEach(videos.filter { m.seasons.isEmpty || $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }) { v in
                    NavigationLink { StreamsView(meta: m, video: v) } label: { EpisodeRow(video: v, entry: history.entry(for: "addon:\(v.id)")) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct EpisodeRow: View {
    let video: MetaVideo
    let entry: HistoryEntry?

    private var episodeTitle: String {
        if let e = video.episode { return "\(e). " + (video.title ?? "Episode \(e)") }
        return video.title ?? video.id
    }
    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: video.thumbnail, aspect: 16.0 / 9.0, cornerRadius: 10)
                .frame(width: 130)
                .overlay(alignment: .bottom) {
                    if let entry, entry.progress > 0.01 {
                        GeometryReader { g in
                            Rectangle().fill(Theme.accent).frame(width: g.size.width * entry.progress, height: 3)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(episodeTitle)
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                if let o = video.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let entry, entry.isFinished {
                    Label("Watched", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Streams

struct StreamsView: View {
    let meta: MetaItem
    let video: MetaVideo?

    struct StreamGroup: Identifiable { let id: String; let addon: InstalledAddon; var streams: [AddonStream]; var error: String? }
    @State private var groups: [StreamGroup] = []
    @State private var loading = true
    @State private var starting = false

    private var videoId: String { video?.id ?? meta.id }

    var body: some View {
        List {
            if loading && groups.allSatisfy({ $0.streams.isEmpty }) {
                HStack { ProgressView(); Text("Asking addons…").foregroundStyle(.secondary) }
            }
            ForEach(groups) { g in
                Section(g.addon.manifest.name) {
                    if let e = g.error { Text(e).font(.caption).foregroundStyle(.orange) }
                    ForEach(g.streams) { s in
                        Button { play(s, from: g.addon) } label: { StreamRow(stream: s) }
                            .disabled(!s.isPlayable || starting)
                    }
                    if g.streams.isEmpty && g.error == nil && !loading {
                        Text("No streams").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !loading && groups.isEmpty {
                Text("None of your addons provide streams for this title. Add a stream addon in Discover → Addons.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay { if starting { ProgressView().controlSize(.large).padding(20).glass() } }
        .navigationTitle(video?.label ?? meta.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if groups.isEmpty { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        let addons = AddonStore.shared.streamAddons(type: meta.type, id: videoId)
        groups = addons.map { StreamGroup(id: $0.id, addon: $0, streams: []) }
        await withTaskGroup(of: (String, [AddonStream]?, String?).self) { tg in
            for a in addons {
                tg.addTask {
                    do { return (a.id, try await AddonAPI.streams(a, type: meta.type, id: videoId), nil) }
                    catch { return (a.id, nil, error.localizedDescription) }
                }
            }
            for await (id, streams, err) in tg {
                if let i = groups.firstIndex(where: { $0.id == id }) {
                    groups[i].streams = streams ?? []
                    groups[i].error = err
                }
            }
        }
        loading = false
    }

    private func play(_ s: AddonStream, from addon: InstalledAddon) {
        guard let url = s.url else { return }
        starting = true
        Task {
            var item = MediaItem(url: url, title: meta.name, subtitle: video?.label, source: .addon(name: addon.manifest.name))
            item.artwork = meta.poster
            item.historyKey = "addon:\(videoId)"
            item.addonRef = "\(meta.type)|\(meta.id)|\(videoId)"
            item.headers = s.behaviorHints?.proxyHeaders?.request ?? [:]
            var subs = (s.subtitles ?? []).map { ExternalSubtitle(url: $0.url, lang: $0.lang, title: $0.lang) }
            subs += await fetchSubtitles()
            item.subtitles = Array(subs.prefix(40))
            if meta.isAnime {
                var hint = AnimeHint(title: meta.name, episode: video?.episode)
                let parts = videoId.split(separator: ":")
                if parts.first == "kitsu", parts.count >= 2 {
                    hint.kitsuId = Int(parts[1])
                    if parts.count >= 3 { hint.episode = Int(parts[2]) ?? hint.episode }
                } else if parts.first == "mal", parts.count >= 2 {
                    hint.malId = Int(parts[1])
                    if parts.count >= 3 { hint.episode = Int(parts[2]) ?? hint.episode }
                }
                if hint.episode == nil, meta.type == "movie" { hint.episode = 1 }
                item.anime = hint
            }
            starting = false
            PlayerPresenter.play(item)
        }
    }

    private func fetchSubtitles() async -> [ExternalSubtitle] {
        let addons = AddonStore.shared.subtitleAddons(type: meta.type, id: videoId)
        guard !addons.isEmpty else { return [] }
        let prefs = (UserDefaults.standard.string(forKey: SettingsKey.subLangs) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var out: [ExternalSubtitle] = []
        await withTaskGroup(of: [AddonSubtitle].self) { tg in
            for a in addons { tg.addTask { (try? await AddonAPI.subtitles(a, type: meta.type, id: videoId)) ?? [] } }
            for await list in tg {
                out += list.map { ExternalSubtitle(url: $0.url, lang: $0.lang, title: $0.lang) }
            }
        }
        if !prefs.isEmpty {
            out.sort { a, b in
                let ai = prefs.firstIndex(of: (a.lang ?? "").lowercased()) ?? 99
                let bi = prefs.firstIndex(of: (b.lang ?? "").lowercased()) ?? 99
                return ai < bi
            }
        }
        return out
    }
}

struct StreamRow: View {
    let stream: AddonStream
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(stream.displayName)
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(width: 78)
                .padding(.vertical, 8)
                .background(stream.isPlayable ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.displayTitle.isEmpty ? (stream.behaviorHints?.filename ?? "Stream") : stream.displayTitle)
                    .font(.caption).lineLimit(6)
                if !stream.isPlayable {
                    Text(stream.infoHash != nil ? "Torrent stream — use a debrid-enabled addon config" : "Not a direct link")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(stream.isPlayable ? 1 : 0.5)
    }
}

// MARK: - Search

struct AddonSearchView: View {
    @State private var query = ""
    struct SearchResult: Identifiable { let id: String; let title: String; let addon: InstalledAddon; let metas: [MetaItem] }
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if searching { ProgressView().frame(maxWidth: .infinity).padding() }
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(r.title).font(.headline).padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(r.metas) { m in
                                    NavigationLink { MetaDetailView(preview: m, sourceAddon: r.addon) } label: { PosterCard(meta: m) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                if !searching && results.isEmpty && !query.isEmpty {
                    Text("No results").foregroundStyle(.secondary).padding()
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows, anime")
        .onSubmit(of: .search) { run() }
    }

    private func run() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        results = []
        task = Task {
            let targets = AddonStore.shared.addons.flatMap { a in a.manifest.catalogs.filter(\.supportsSearch).map { (a, $0) } }
            await withTaskGroup(of: (String, String, InstalledAddon, [MetaItem]).self) { tg in
                for (a, c) in targets {
                    tg.addTask {
                        let metas = (try? await AddonAPI.catalog(a, c, extra: ["search": q])) ?? []
                        return (a.id + c.type + c.id, "\(c.name ?? c.id) · \(c.type.capitalized) — \(a.manifest.name)", a, metas)
                    }
                }
                for await r in tg where !r.3.isEmpty && !Task.isCancelled {
                    results.append(SearchResult(id: r.0, title: r.1, addon: r.2, metas: r.3))
                }
            }
            searching = false
        }
    }
}

// MARK: - Manager

struct AddonsManagerView: View {
    @ObservedObject private var store = AddonStore.shared
    @State private var url = ""
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("https://…/manifest.json or stremio://", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button {
                        Task {
                            do { try await store.install(url); url = ""; error = nil } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        if store.installing { ProgressView() } else { Text("Install").fontWeight(.semibold) }
                    }
                    .disabled(url.isEmpty || store.installing)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("Paste from clipboard") { url = UIPasteboard.general.string ?? "" }
            } header: { Text("Add addon") } footer: {
                Text("Works with Stremio-protocol addons (Cinemeta, Torrentio/Comet/MediaFusion with your debrid key, OpenSubtitles, Kitsu/anime catalogs…). Configure an addon on its website, then paste the manifest link here. Only direct HTTP(S) streams can play; raw torrents need a debrid-configured addon.")
            }
            Section("Installed") {
                ForEach(store.addons) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let logo = a.manifest.logo, let u = URL(string: logo) {
                                AsyncImage(url: u) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                                    .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text(a.manifest.name).font(.headline)
                            if let v = a.manifest.version { Text("v\(v)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(a.manifest.resources.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(Theme.accent)
                        if let d = a.manifest.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.remove(a) } label: { Label("Remove", systemImage: "trash") }
                        Button {
                            if let u = URL(string: a.baseURL + "/configure") { openURL(u) }
                        } label: { Label("Configure", systemImage: "gear") }
                        .tint(.gray)
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = a.transportURL } label: { Label("Copy manifest URL", systemImage: "doc.on.doc") }
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            if !store.addons.contains(where: { $0.transportURL == AddonStore.cinemeta }) {
                Section {
                    Button("Install Cinemeta (movie & series catalogs)") { Task { try? await store.install(AddonStore.cinemeta) } }
                }
            }
        }
        .navigationTitle("Addons")
        .toolbar { EditButton() }
    }
}
