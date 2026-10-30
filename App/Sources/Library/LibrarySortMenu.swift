import SwiftUI

/// The sort button of every library list (Home's library and its folders,
/// the WebDAV browser): one menu with Recently Added, Name and Size.
///
/// As the Files app on iOS 26.2 does it (simulator lab run, its More menu):
/// the current sort is checked with its order under it ("Name / Ascending",
/// "Date / Newest to Oldest"); picking the current sort again turns the order
/// round; picking another starts it its own way (newest first, A to Z,
/// largest first). 1.18.1's separate arrow button for the order is gone
/// (30 Oct: it read as a download button).
struct LibrarySortMenu: View {
    @Binding var sort: LibrarySort
    @Binding var ascending: Bool
    /// In a navigation bar the system draws the button's glass; on Home the
    /// button is its own glass circle.
    var inToolbar = false

    /// Decreasing lines: the system's glyph for ordering a list — no arrows,
    /// so it can't be taken for download or upload.
    static let glyph = "line.3.horizontal.decrease"

    var body: some View {
        Menu {
            ForEach(LibrarySort.allCases, id: \.self) { s in
                // A toggle shows the system's checkmark in a menu; tapping the
                // checked one asks to turn it off, which here turns the order round.
                Toggle(isOn: Binding(get: { sort == s }, set: { _ in pick(s) })) {
                    Text(s.title)
                    if sort == s { Text(s.direction(ascending: ascending)) }
                }
            }
            // The app-wide switch style leaves toggles disabled in menus (1.18.1).
            .toggleStyle(.automatic)
        } label: {
            if inToolbar {
                ToolbarGlyph(Self.glyph)
            } else {
                Image(systemName: Self.glyph).font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34).glassCircle()
            }
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Sort by, \(sort.title), \(sort.direction(ascending: ascending))")
        .accessibilityIdentifier("librarySortMenu")
    }

    private func pick(_ s: LibrarySort) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if s == sort {
                ascending.toggle()
            } else {
                sort = s
                ascending = s.startsAscending
            }
        }
    }
}
