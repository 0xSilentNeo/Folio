import SwiftUI

/// The title page's Watchlist button (1.26.0), at the top right across
/// from Back: a bookmark that fills once the title is saved. (In the row
/// with Play and Track, three buttons didn't fit a phone's width.)
struct WatchlistButton: View {
    let meta: MetaItem
    @ObservedObject private var store = WatchlistStore.shared

    var body: some View {
        let on = store.contains(meta.id)
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.toggle(meta) }
        } label: {
            PageButtonLabel(systemName: on ? "bookmark.fill" : "bookmark")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .accessibilityLabel(on ? "Remove from Watchlist" : "Add to Watchlist")
        .sensoryFeedback(.selection, trigger: on)
    }
}

/// The same, for a tile's long-press menu.
struct WatchlistMenuButton: View {
    let meta: MetaItem
    @ObservedObject private var store = WatchlistStore.shared

    var body: some View {
        if store.contains(meta.id) {
            Button("Remove from Watchlist", systemImage: "bookmark.slash", role: .destructive) { store.remove(meta.id) }
        } else {
            Button("Add to Watchlist", systemImage: "bookmark") { store.add(meta) }
        }
    }
}
