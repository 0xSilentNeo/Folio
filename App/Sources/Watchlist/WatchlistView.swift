import SwiftUI

/// The whole watchlist (1.26.0; in its own sheet since 1.26.2): every saved
/// title, filtered by kind and sorted by when it was added or by name. A long
/// press removes one. Another filter or sort starts the list from its top.
struct WatchlistView: View {
    @ObservedObject private var store = WatchlistStore.shared
    @ObservedObject private var kids = KidsProfile.shared
    @Namespace private var zoomNS
    @State private var filter: Filter = .all
    @State private var sort: Sort = .added
    /// The title opened (1.30.4): by a value, not a link in the grid, so
    /// removing it from the watchlist on its own page doesn't close the
    /// page (its link left the grid, and the page with it).
    @State private var opened: MetaItem?

    enum Filter: String, CaseIterable, Identifiable {
        case all, series, movies
        var id: String { rawValue }
        var title: String { self == .all ? "All" : self == .series ? "Series" : "Movies" }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case added, name
        var id: String { rawValue }
        var title: String { self == .added ? "Recently Added" : "Name" }
    }

    private static let top = "watchlistTop"

    /// Saved titles the kids profile allows (all of them when it's off).
    private var allowed: [WatchlistItem] {
        kids.activeLimits.map { l in store.items.filter { KidsRules.allows($0.meta, limits: l) } } ?? store.items
    }

    private func shown(_ all: [WatchlistItem]) -> [WatchlistItem] {
        var items = all
        switch filter {
        case .all: break
        case .series: items = items.filter(\.isSeries)
        case .movies: items = items.filter { !$0.isSeries }
        }
        if sort == .name { items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        return items
    }

    var body: some View {
        let all = allowed
        let items = shown(all)
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Discover's control and order: All, Movies, Series (1.27.0).
                    SegmentPicker(options: [(Filter.all, "All"), (Filter.movies, "Movies"), (Filter.series, "Series")], selection: $filter)
                        .frame(height: 36)
                        .accessibilityLabel("Show")
                        .id(Self.top)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
                        ForEach(items) { item in
                            let m = item.meta
                            Button { opened = m } label: {
                                PosterCard(meta: m, width: nil, zoom: ZoomSource(m.id, zoomNS))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { WatchlistMenuButton(meta: m) }
                        }
                    }
                    if items.isEmpty {
                        empty(nothingSaved: all.isEmpty)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .onChange(of: filter) { scroller.scrollTo(Self.top, anchor: .top) }
            .onChange(of: sort) { withAnimation(.snappy) { scroller.scrollTo(Self.top, anchor: .top) } }
        }
        .background(HomeBackdrop().ignoresSafeArea())
        .navigationDestination(item: $opened) { m in
            MetaDetailView(preview: m, sourceAddon: nil).zoomDestination(m.id, in: zoomNS)
        }
        .navigationTitle("Watchlist")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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

    @ViewBuilder
    private func empty(nothingSaved: Bool) -> some View {
        if nothingSaved {
            ContentUnavailableView("Nothing Saved", systemImage: "bookmark",
                                   description: Text("Tap the bookmark on a title's page, or press and hold a poster, to save it for later."))
        } else {
            ContentUnavailableView(filter == .series ? "No Series Saved" : "No Movies Saved", systemImage: "bookmark",
                                   description: Text("Saved \(filter == .series ? "films" : "series") are under All."))
        }
    }
}
