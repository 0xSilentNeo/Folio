import SwiftUI

/// What the tab bar's search button searches: the page it was opened from
/// (1.22.5). From Home or Network your library and servers
/// (LibrarySearchPage); from Discover titles on IMDb and the addons
/// (AddonSearchView). In 1.22.4 it was one page for everything, which
/// looked like Discover's search wherever it was opened.
enum SearchScope: Equatable {
    case library, discover

    /// The tab the button was tapped on: 1 is Discover.
    init(fromTab tab: Int) { self = tab == 1 ? .discover : .library }

    var prompt: String { self == .discover ? "Movies, shows, anime" : "Your library and servers" }
}

/// The search tab: iOS 26 draws it as the round button beside the tab bar
/// that opens into the field where it is.
struct SearchTabView: View {
    @Binding var query: String
    let scope: SearchScope

    var body: some View {
        NavigationStack {
            switch scope {
            case .library: LibrarySearchPage(query: $query)
            case .discover: AddonSearchView(tabQuery: $query)
            }
        }
        .modifier(PageSearchField(text: $query, prompt: scope.prompt))
    }
}

/// iOS 26: the field belongs to the tab view, so the search tab's button
/// beside the tab bar opens into it. Before iOS 26 the page has it.
/// Choosing the search tab puts the keyboard up, as Discover's search page
/// did: you came to type.
struct TabBarSearchField: ViewModifier {
    @Binding var text: String
    let prompt: String
    /// The search tab is the one showing.
    let selected: Bool
    @FocusState private var focused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.searchable(text: $text, prompt: prompt)
                // Choosing the tab opens its field, and Cancel goes back to the
                // tab you were on (UISearchTab.automaticallyActivatesSearch).
                // iOS 27 also sets only such a search tab apart from the bar,
                // as the round button beside it (UITabBarController
                // .prominentTabIdentifier's notes); without it, iOS 27 drew
                // Search as a fourth tab inside the bar (your 5 Nov screenshots).
                .tabViewSearchActivation(.searchTabSelection)
                .searchFocused($focused)
                // The Search key reaches the view that has the field, not the
                // page inside the tab: it's passed on (simulator: "labx\n"
                // never got to the page's onSubmit, so it wasn't kept).
                .onSubmit(of: .search) { NotificationCenter.default.post(name: .searchTabSubmitted, object: text) }
                .onChange(of: selected) { _, on in
                    // After the button has opened into the field.
                    if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct PageSearchField: ViewModifier {
    @Binding var text: String
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
        } else {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        }
        #else
        content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #endif
    }
}

extension Notification.Name {
    /// The search tab's Search key, with the text (TabBarSearchField → AddonSearchView).
    static let searchTabSubmitted = Notification.Name("folio.searchTabSubmitted")
}
