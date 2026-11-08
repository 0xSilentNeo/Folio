import SwiftUI

/// Discover's Watchlist button (1.26.2), at the top right: the list opens
/// in a sheet of its own (it was a row at the top of Discover). The bookmark
/// fills once something is saved.
struct WatchlistSheetButton: View {
    @ObservedObject private var store = WatchlistStore.shared
    @ObservedObject private var kids = KidsProfile.shared
    @State private var showing = false

    var body: some View {
        let count = kids.activeLimits.map { l in store.items.filter { KidsRules.allows($0.meta, limits: l) }.count } ?? store.items.count
        Button { showing = true } label: {
            Image(systemName: count > 0 ? "bookmark.fill" : "bookmark")
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .glassCircle()
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel("Watchlist")
        .accessibilityValue(count == 1 ? "1 title" : "\(count) titles")
        .accessibilityIdentifier("watchlistButton")
        .sheet(isPresented: $showing) { WatchlistSheet() }
    }
}

/// The watchlist in a sheet with its own navigation: a title opens inside it,
/// and plays from there (the player has its own window).
struct WatchlistSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WatchlistView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("watchlistDone")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
