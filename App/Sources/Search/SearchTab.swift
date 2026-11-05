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

/// The tab view's part (iOS 26): choosing the search tab opens its field,
/// and Cancel goes back to the tab you were on
/// (UISearchTab.automaticallyActivatesSearch). iOS 27 also sets only such a
/// search tab apart from the bar, as the round button beside it
/// (UITabBarController.prominentTabIdentifier's notes); without it, iOS 27
/// drew Search as a fourth tab inside the bar (your 5 Nov screenshots).
///
/// The field itself is the search tab's (PageSearchField), not the tab
/// view's: on the tab view (1.22.4 to 1.22.7) every tab's navigation bar
/// got it too, and Network, the one tab with a standard title bar, showed
/// "Your library and servers" under its title (5 Nov).
struct TabBarSearchField: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.tabViewSearchActivation(.searchTabSelection)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The search tab's field. iOS 26 draws it at the bottom, where the round
/// button opened; before iOS 26 it sits under the title.
private struct PageSearchField: ViewModifier {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.searchable(text: $text, prompt: prompt)
                .searchFocused($focused)
                // The Search key reaches the view that has the field, not the
                // page inside the tab: it's passed on (simulator: "labx\n"
                // never got to the page's onSubmit, so it wasn't kept).
                .onSubmit(of: .search) { NotificationCenter.default.post(name: .searchTabSubmitted, object: text) }
                .onChange(of: focused) { _, f in if f { HitchProbe.mark("search", "field focused") } }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in HitchProbe.mark("search", "keyboard up") }
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
