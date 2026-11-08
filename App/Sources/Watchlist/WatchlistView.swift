import SwiftUI

/// The whole watchlist (1.26.0): every saved title, filtered by kind and
/// sorted by when it was added or by name. A long press removes one.
struct WatchlistView: View {
    @ObservedObject private var store = WatchlistStore.shared
    @ObservedObject private var kids = KidsProfile.shared
    @Namespace private var zoomNS
    @State private var filter: Filter = .all
    @State private var sort: Sort = .added

    enum Filter: String, CaseIterable, Identifiable {
        case all, series, movies
        var id: String { rawValue }
        var title: String { self == .all ? "All" : self == .series ? "Series" : "Movies" }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case added, name
        var id: String { rawValue }
        var title: String { self == .added ? "Recently added" : "Name" }
    }

    private var shown: [WatchlistItem] {
        var items = kids.activeLimits.map { l in store.items.filter { KidsRules.allows($0.meta, limits: l) } } ?? store.items
        switch filter {
        case .all: break
        case .series: items = items.filter(\.isSeries)
        case .movies: items = items.filter { !$0.isSeries }
        }
        if sort == .name { items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        return items
    }

    var body: some View {
        let items = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
                    ForEach(items) { item in
                        let m = item.meta
                        NavigationLink {
                            MetaDetailView(preview: m, sourceAddon: nil).zoomDestination(m.id, in: zoomNS)
                        } label: {
                            PosterCard(meta: m, width: nil, zoom: ZoomSource(m.id, zoomNS))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { WatchlistMenuButton(meta: m) }
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView("Nothing saved", systemImage: "bookmark",
                                           description: Text("Tap Watchlist on a title's page, or press and hold a poster, to save it for later."))
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(HomeBackdrop().ignoresSafeArea())
        .navigationTitle("Watchlist")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }
}
