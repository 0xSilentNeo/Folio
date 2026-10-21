import SwiftUI

/// Streaming-service catalogs (what's on Netflix, Prime Video, Max, Disney+…)
/// from the public "Streaming Catalogs" Stremio addon. Items carry IMDb ids,
/// so details and streams come from Cinemeta and your stream addons.
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
        async let s = catalog(type: "series", id: id)
        async let m = catalog(type: "movie", id: id)
        let (series, movies) = await (s, m)
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

@MainActor
final class DiscoverModel: ObservableObject {
    @Published var trending: [(meta: MetaItem, platform: StreamingPlatform)] = []
    @Published var top10Shows: [MetaItem] = []
    @Published var top10Movies: [MetaItem] = []
    @Published var rows: [String: [MetaItem]] = [:]
    @Published var loaded = false

    func load(force: Bool = false) async {
        if loaded && !force { return }
        let platforms = StreamingPlatform.enabled
        async let shows = PlatformCatalogs.catalog(type: "series", id: "netflix-top10-global")
        async let movies = PlatformCatalogs.catalog(type: "movie", id: "netflix-top10-global")
        var newRows: [String: [MetaItem]] = [:]
        await withTaskGroup(of: (String, [MetaItem]).self) { g in
            for p in platforms { g.addTask { (p.id, await PlatformCatalogs.mixed(p.id)) } }
            for await (id, metas) in g {
                newRows[id] = metas
                rows[id] = metas
            }
        }
        let sh = await shows
        let mv = await movies
        top10Shows = Array(sh.prefix(10))
        top10Movies = Array(mv.prefix(10))
        // Trending everywhere: the top picks of each platform, round-robin.
        var t: [(MetaItem, StreamingPlatform)] = []
        var seen = Set<String>()
        for i in 0..<3 {
            for p in platforms {
                if let list = newRows[p.id], i < list.count, list[i].background != nil, seen.insert(list[i].id).inserted {
                    t.append((list[i], p))
                }
            }
        }
        trending = Array(t.prefix(12)).map { (meta: $0.0, platform: $0.1) }
        loaded = true
    }
}

struct DiscoverView: View {
    @ObservedObject private var store = AddonStore.shared
    @StateObject private var model = DiscoverModel()
    @State private var showPlatformSettings = false
    @State private var heroIndex = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    header
                    platformStrip
                    if !model.trending.isEmpty { hero } else if !model.loaded { heroPlaceholder }
                    if !model.top10Shows.isEmpty { RankedRow(title: "Top 10 Shows on Netflix", metas: model.top10Shows) }
                    if !model.top10Movies.isEmpty { RankedRow(title: "Top 10 Movies on Netflix", metas: model.top10Movies) }
                    ForEach(StreamingPlatform.enabled) { p in
                        PlatformSection(platform: p, metas: model.rows[p.id] ?? [], loaded: model.loaded || model.rows[p.id] != nil)
                    }
                    if !addonRows.isEmpty {
                        Text("From your addons").font(.title3.weight(.bold)).padding(.horizontal, 20).padding(.top, 8)
                        ForEach(addonRows, id: \.key) { row in
                            CatalogRow(addon: row.addon, catalog: row.catalog)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.load(force: true) }
            .task { await model.load() }
            .sheet(isPresented: $showPlatformSettings, onDismiss: { Task { await model.load(force: true) } }) {
                PlatformSettingsView()
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Discover").font(.system(size: 30, weight: .bold, design: .rounded))
            Spacer()
            NavigationLink { AddonSearchView() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .bold)).frame(width: 42, height: 42).glassCircle()
            }
            .buttonStyle(.plain)
            Menu {
                Button { showPlatformSettings = true } label: { Label("Choose services", systemImage: "square.grid.2x2") }
                NavigationLink { AddonsManagerView() } label: { Label("Addons", systemImage: "puzzlepiece.extension") }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .bold)).frame(width: 42, height: 42).glassCircle()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var platformStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(StreamingPlatform.enabled) { p in
                    NavigationLink { PlatformDetailView(platform: p) } label: {
                        VStack(spacing: 6) {
                            PlatformBadge(platform: p, size: 58)
                            Text(p.name).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 70)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trending Everywhere").font(.title3.weight(.bold)).padding(.horizontal, 20)
            TabView(selection: $heroIndex) {
                ForEach(Array(model.trending.enumerated()), id: \.offset) { i, t in
                    NavigationLink { MetaDetailView(preview: t.meta, sourceAddon: nil) } label: {
                        TrendingCard(meta: t.meta, platform: t.platform)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 250)
        }
    }

    private var heroPlaceholder: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.card)
            .frame(height: 220)
            .overlay(ProgressView())
            .padding(.horizontal, 20)
    }

    private struct Row { let key: String; let addon: InstalledAddon; let catalog: AddonManifest.Catalog }

    private var addonRows: [Row] {
        store.addons.flatMap { a in
            a.manifest.catalogs.filter(\.isBrowsable).prefix(8).map { c in
                Row(key: a.id + c.type + c.id, addon: a, catalog: c)
            }
        }
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

struct TrendingCard: View {
    let meta: MetaItem
    let platform: StreamingPlatform

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PosterImage(url: meta.background ?? meta.poster, aspect: 16.0 / 9.0, cornerRadius: 0)
                .frame(maxWidth: .infinity)
            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PlatformBadge(platform: platform, size: 22)
                    Text(platform.name).font(.caption.weight(.bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .glass(cornerRadius: 14)
                if let logo = meta.logo, let u = URL(string: logo) {
                    AsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: {
                        Text(meta.name).font(.title2.weight(.heavy))
                    }
                    .frame(maxWidth: 200, maxHeight: 56, alignment: .leading)
                } else {
                    Text(meta.name).font(.title2.weight(.heavy)).lineLimit(2)
                }
                Text([meta.type == "series" ? "Series" : "Movie", meta.releaseInfo, meta.genres?.first].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

struct RankedRow: View {
    let title: String
    let metas: [MetaItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(Array(metas.enumerated()), id: \.element.id) { i, m in
                        NavigationLink { MetaDetailView(preview: m, sourceAddon: nil) } label: {
                            HStack(alignment: .bottom, spacing: -14) {
                                Text("\(i + 1)")
                                    .font(.system(size: 96, weight: .black, design: .rounded))
                                    .foregroundStyle(.clear)
                                    .overlay(
                                        Text("\(i + 1)").font(.system(size: 96, weight: .black, design: .rounded))
                                            .foregroundStyle(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                                    )
                                    .offset(y: 14)
                                PosterImage(url: m.poster).frame(width: 112)
                                    .shadow(color: .black.opacity(0.5), radius: 8, x: -4)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct PlatformSection: View {
    let platform: StreamingPlatform
    let metas: [MetaItem]
    let loaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PlatformBadge(platform: platform, size: 30)
                Text(platform.name).font(.title3.weight(.bold))
                Spacer()
                NavigationLink { PlatformDetailView(platform: platform) } label: {
                    Text("See all").font(.subheadline.weight(.semibold)).foregroundStyle(platform.color == Color(white: 0.55) ? Theme.accent : platform.color)
                }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    if metas.isEmpty {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12).fill(Theme.card).frame(width: 118, height: 177)
                                .overlay { if loaded { EmptyView() } else { ProgressView() } }
                        }
                    }
                    ForEach(metas) { m in
                        NavigationLink { MetaDetailView(preview: m, sourceAddon: nil) } label: {
                            PosterCard(meta: m, width: 118)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
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
