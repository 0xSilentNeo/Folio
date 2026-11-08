import SwiftUI

/// Discover's Watchlist row (1.26.0): what you saved, newest first, with
/// the whole list a tap away. Shown once something is saved.
struct WatchlistRow: View {
    let margin: CGFloat
    let zoomNS: Namespace.ID
    @ObservedObject private var store = WatchlistStore.shared
    @ObservedObject private var kids = KidsProfile.shared

    var body: some View {
        let items = kids.activeLimits.map { l in store.items.filter { KidsRules.allows($0.meta, limits: l) } } ?? store.items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink {
                    WatchlistView()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Watchlist").font(.title3.weight(.bold))
                        Text("\(items.count)").font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text("See all").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, margin)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items.prefix(20)) { item in
                            let m = item.meta
                            NavigationLink {
                                MetaDetailView(preview: m, sourceAddon: nil).zoomDestination("wl|" + m.id, in: zoomNS)
                            } label: {
                                PosterCard(meta: m, width: 118, zoom: ZoomSource("wl|" + m.id, zoomNS))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { WatchlistMenuButton(meta: m) }
                        }
                    }
                    .padding(.horizontal, margin)
                }
                .scrollIndicators(.hidden)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("watchlistRow")
        }
    }
}
