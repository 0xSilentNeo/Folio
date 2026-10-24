import SwiftUI

/// Streaming-service catalogs (what's on Netflix, Prime Video, Max, Disney+…)
/// from the public "Streaming Catalogs" Stremio addon. Items carry IMDb ids,
/// so details come from IMDb and streams from your stream addons.
struct StreamingPlatform: Identifiable, Hashable {
    let id: String
    let name: String
    let short: String
    let color: Color
    let color2: Color

    static let all: [StreamingPlatform] = [
        .init(id: "nfx", name: "Netflix", short: "N", color: Color(red: 0.90, green: 0.04, blue: 0.08), color2: Color(red: 0.45, green: 0.0, blue: 0.02)),
        .init(id: "amp", name: "Prime Video", short: "prime", color: Color(red: 0.0, green: 0.66, blue: 0.88), color2: Color(red: 0.0, green: 0.25, blue: 0.45)),
        .init(id: "hbm", name: "HBO Max", short: "max", color: Color(red: 0.0, green: 0.17, blue: 0.91), color2: Color(red: 0.35, green: 0.13, blue: 0.70)),
        .init(id: "dnp", name: "Disney+", short: "D+", color: Color(red: 0.07, green: 0.24, blue: 0.81), color2: Color(red: 0.02, green: 0.08, blue: 0.30)),
        .init(id: "atp", name: "Apple TV+", short: "tv+", color: Color(white: 0.55), color2: Color(white: 0.12)),
        .init(id: "pmp", name: "Paramount+", short: "P+", color: Color(red: 0.0, green: 0.39, blue: 1.0), color2: Color(red: 0.0, green: 0.12, blue: 0.40)),
        .init(id: "hlu", name: "Hulu", short: "hulu", color: Color(red: 0.11, green: 0.91, blue: 0.51), color2: Color(red: 0.02, green: 0.35, blue: 0.20)),
        .init(id: "pcp", name: "Peacock", short: "P", color: Color(red: 0.98, green: 0.73, blue: 0.0), color2: Color(red: 0.40, green: 0.10, blue: 0.55)),
        .init(id: "cru", name: "Crunchyroll", short: "CR", color: Color(red: 0.96, green: 0.46, blue: 0.13), color2: Color(red: 0.45, green: 0.15, blue: 0.0)),
    ]

    static func byID(_ id: String) -> StreamingPlatform? { all.first { $0.id == id } }

    /// Platforms shown on Discover, in order.
    static var enabled: [StreamingPlatform] {
        get {
            let ids = UserDefaults.standard.stringArray(forKey: "discoverPlatforms") ?? all.map(\.id)
            return ids.compactMap(byID)
        }
        set { UserDefaults.standard.set(newValue.map(\.id), forKey: "discoverPlatforms") }
    }
}

enum PlatformCatalogs {
    private static let host = "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club"
    private static var cache: [String: (Date, [MetaItem])] = [:]
    private static let lock = NSLock()

    static var region: String {
        UserDefaults.standard.string(forKey: "discoverRegion") ?? Locale.current.region?.identifier ?? "US"
    }

    private static var base: String {
        let ids = StreamingPlatform.all.map(\.id).joined(separator: ",")
        let config = "\(ids)::\(region):1700000000000:1:0:"
        return host + "/" + Data(config.utf8).base64EncodedString()
    }

    /// type: "movie" | "series"; id: platform id or "netflix-top10-global".
    static func catalog(type: String, id: String) async -> [MetaItem] {
        let key = "\(region)|\(type)|\(id)"
        lock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.0) < 1800 { lock.unlock(); return hit.1 }
        lock.unlock()
        let metas = (try? await AddonAPI.get(AddonAPI.CatalogResponse.self, "\(base)/catalog/\(type)/\(id).json").metas) ?? []
        lock.lock(); cache[key] = (Date(), metas); lock.unlock()
        return metas
    }

    /// Series and movies interleaved (series first), de-duplicated.
    static func mixed(_ id: String, limit: Int = 30) async -> [MetaItem] {
        // Two plain tasks rather than `async let` (see MetaDetailView.load).
        let s = Task { await catalog(type: "series", id: id) }
        let m = Task { await catalog(type: "movie", id: id) }
        let series = await s.value, movies = await m.value
        var out: [MetaItem] = []
        var seen = Set<String>()
        for i in 0..<max(series.count, movies.count) {
            for list in [series, movies] where i < list.count {
                if seen.insert(list[i].id).inserted { out.append(list[i]) }
            }
        }
        return Array(out.prefix(limit))
    }
}

// MARK: - Discover

/// Browse filters for the main grid. Data comes from IMDb (built in) or,
/// when a key is set, TMDB.
@MainActor
final class BrowseModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case trending, topRated, new
        var id: String { rawValue }
        var title: String { self == .trending ? "Trending" : self == .topRated ? "Top Rated" : "New" }
        var footnote: String? {
            if TMDB.enabled { return self == .topRated ? "TMDB top rated" : self == .trending ? "TMDB trending this week" : nil }
            switch self {
            case .trending: return "IMDb Most Popular (MOVIEmeter)"
            case .topRated: return "IMDb Top 250, as rated by IMDb users"
            case .new: return nil
            }
        }
        var imdb: IMDbSource.Sort { self == .trending ? .trending : self == .topRated ? .topRated : .new }
    }
    static var genres: [String] { IMDbSource.genres }
    static let years: [String] = (0..<30).map { String(Calendar.current.component(.year, from: Date()) - $0) }

    @Published var sort: Sort = .trending { didSet { reload() } }
    @Published var type = "movie" { didSet { reload() } }
    @Published var genre: String? { didSet { reload() } }
    @Published var year: String = BrowseModel.years[0] { didSet { if sort == .new { reload() } } }
    @Published var metas: [MetaItem] = []
    @Published var loading = false
    @Published var failed = false
    private var exhausted = false
    private var generation = 0
    private var task: Task<Void, Never>?

    func reload() {
        task?.cancel()
        generation += 1          // anything still in flight is stale now
        metas = []; exhausted = false; failed = false
        loading = true           // keep the spinner up through the gap, no empty-state flash
        task = Task { await load(initial: true) }
    }

    func loadMore() async { await load(initial: false) }

    private func load(initial: Bool) async {
        if !initial { guard !loading, !exhausted else { return } }
        generation += 1
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        if TMDB.enabled {
            let page = await TMDB.browse(sort: sort, type: type, genre: genre, year: year, page: metas.count / 20 + 1)
            guard gen == generation else { return }
            if page.isEmpty { exhausted = true; failed = metas.isEmpty && page.isEmpty && !Task.isCancelled && TMDB.lastError }
            let known = Set(metas.map(\.id))
            metas += page.filter { !known.contains($0.id) }
            return
        }
        // IMDb lists come whole (100–250 items); nothing to page.
        guard initial || metas.isEmpty else { exhausted = true; return }
        // Last list first (any age), fresh one when it arrives.
        let stale = await IMDbSource.browse(sort: sort.imdb, type: type, genre: genre, year: year, staleOnly: true)
        if gen == generation, !stale.isEmpty, metas.isEmpty { metas = stale }
        let list = await IMDbSource.browse(sort: sort.imdb, type: type, genre: genre, year: year)
        guard gen == generation else { return }
        if !list.isEmpty || metas.isEmpty { metas = list }
        exhausted = true
        failed = metas.isEmpty
    }
}

struct DiscoverView: View {
    @ObservedObject private var store = AddonStore.shared
    @StateObject private var browse = BrowseModel()
    @State private var showPlatformSettings = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let margin: CGFloat = geo.size.width > 700 ? 28 : 20
                let cols = max(3, Int((geo.size.width - margin * 2 + 12) / 122))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        header(margin)
                        platformStrip(margin)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(gridTitle).font(.title3.weight(.bold))
                                Spacer()
                                if browse.loading && browse.metas.isEmpty { ProgressView() }
                            }
                            if let f = browse.sort.footnote { Text(f).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, margin)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols), spacing: 18) {
                            ForEach(browse.metas) { m in
                                NavigationLink { MetaDetailView(preview: m, sourceAddon: nil) } label: { PosterCard(meta: m, width: nil) }
                                    .buttonStyle(.plain)
                                    .onAppear { if m.id == browse.metas.last?.id { Task { await browse.loadMore() } } }
                            }
                        }
                        .padding(.horizontal, margin)
                        if browse.loading && !browse.metas.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                        if !browse.loading && browse.metas.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(browse.failed ? "IMDb didn't answer." : "Nothing here.").foregroundStyle(.secondary)
                                if browse.failed {
                                    Text("Check the connection, then pull to retry. The diagnostics log (Settings → Advanced) records the HTTP status.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("Retry") { browse.reload() }.buttonStyle(.bordered).tint(Theme.accent)
                                }
                            }
                            .padding(.horizontal, margin)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.hidden)
            }
            .background(HomeBackdrop().ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { filterBar }
            .task {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "discoverLastUsed")
                if browse.metas.isEmpty { browse.reload() }
            }
            .refreshable { browse.reload() }
            .sheet(isPresented: $showPlatformSettings) { PlatformSettingsView() }
        }
    }

    private var gridTitle: String {
        let t = browse.type == "movie" ? "Movies" : "Series"
        switch browse.sort {
        case .new: return "New \(t) · \(browse.year)"
        case .topRated: return "Top Rated \(t)" + (browse.genre.map { " · \($0)" } ?? "")
        case .trending: return "Trending \(t)" + (browse.genre.map { " · \($0)" } ?? "")
        }
    }

    private func header(_ margin: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text("Discover").font(.system(size: 28, weight: .bold, design: .rounded))
            Spacer()
            NavigationLink { AddonSearchView() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(.plain)
            Menu {
                Button { showPlatformSettings = true } label: { Label("Streaming services", systemImage: "rectangle.grid.2x2") }
                NavigationLink { AddonsManagerView() } label: { Label("Addons", systemImage: "puzzlepiece.extension") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).glassCircle()
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, 8)
    }

    private func platformStrip(_ margin: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(StreamingPlatform.enabled) { p in
                    NavigationLink { PlatformDetailView(platform: p) } label: {
                        VStack(spacing: 6) {
                            PlatformBadge(platform: p, size: 56)
                            Text(p.name).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 68)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, margin)
        }
    }

    /// Floating Liquid Glass filter bar.
    private var filterBar: some View {
        HStack(spacing: 6) {
            SegmentPicker(options: [("movie", "Movies"), ("series", "Series")], selection: $browse.type)
                .frame(width: 160)
            Menu {
                Picker("Sort", selection: $browse.sort) { ForEach(BrowseModel.Sort.allCases) { Text($0.title).tag($0) } }
            } label: { FilterChip(title: browse.sort.title, active: true) }
            if browse.sort == .new {
                Menu {
                    Picker("Year", selection: $browse.year) { ForEach(BrowseModel.years, id: \.self) { Text($0).tag($0) } }
                } label: { FilterChip(title: browse.year, active: true) }
            } else {
                Menu {
                    Button { browse.genre = nil } label: { browse.genre == nil ? Label("All genres", systemImage: "checkmark") : Label("All genres", systemImage: "circle") }
                    Divider()
                    ForEach(BrowseModel.genres, id: \.self) { g in
                        Button { browse.genre = g } label: { if browse.genre == g { Label(g, systemImage: "checkmark") } else { Text(g) } }
                    }
                } label: { FilterChip(title: browse.genre ?? "Genre", active: browse.genre != nil) }
            }
        }
        .padding(6)
        .glass(cornerRadius: 28, interactive: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .tint(Theme.accent)
    }
}

struct FilterChip: View {
    let title: String
    let active: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .foregroundStyle(active ? .white : .white.opacity(0.7))
        .padding(.horizontal, 12).frame(height: 38)
        .background(active ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
        .contentShape(Capsule())          // a clear background isn't tappable: only the text was
    }
}

struct PlatformBadge: View {
    let platform: StreamingPlatform
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [platform.color, platform.color2], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(platform.short)
                .font(.system(size: size * (platform.short.count > 2 ? 0.24 : 0.36), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .padding(4)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.15)))
    }
}

struct PlatformDetailView: View {
    let platform: StreamingPlatform
    @State private var type = "series"
    @State private var metas: [MetaItem] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [platform.color, platform.color2, Theme.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: 170)
                    HStack(spacing: 12) {
                        PlatformBadge(platform: platform, size: 54)
                        Text(platform.name).font(.largeTitle.weight(.heavy))
                    }
                    .padding(20)
                }
                Picker("", selection: $type) {
                    Text("Shows").tag("series")
                    Text("Movies").tag("movie")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
                    ForEach(metas) { m in
                        NavigationLink { MetaDetailView(preview: m, sourceAddon: nil) } label: { PosterCard(meta: m, width: 108) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: type) {
            loading = true
            metas = await PlatformCatalogs.catalog(type: type, id: platform.id)
            loading = false
        }
    }
}

struct PlatformSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: [StreamingPlatform] = StreamingPlatform.enabled
    @AppStorage("discoverRegion") private var region = Locale.current.region?.identifier ?? "US"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(enabled) { p in
                        HStack { PlatformBadge(platform: p, size: 30); Text(p.name) }
                    }
                    .onMove { enabled.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { enabled.remove(atOffsets: $0) }
                } header: { Text("Shown on Discover") } footer: { Text("Drag to reorder, swipe to hide.") }
                let hidden = StreamingPlatform.all.filter { p in !enabled.contains(p) }
                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(hidden) { p in
                            Button { enabled.append(p) } label: {
                                HStack { PlatformBadge(platform: p, size: 30); Text(p.name).foregroundStyle(.primary); Spacer(); Image(systemName: "plus.circle.fill") }
                            }
                        }
                    }
                }
                Section {
                    TextField("Region (e.g. AU, US, GB)", text: $region)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                } header: { Text("Region") }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Streaming Services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { StreamingPlatform.enabled = enabled; dismiss() }
                }
            }
        }
    }
}
