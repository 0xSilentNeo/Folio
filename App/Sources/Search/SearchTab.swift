import SwiftUI

/// The search tab: iOS 26 draws it as the round button beside the tab bar
/// that opens into the field where it is. One page whatever tab it was
/// opened from (1.28.11): your library and servers, then movies and shows.
/// From 1.22.5 it searched only the page it was opened from.
struct SearchTabView: View {
    @Binding var query: String

    var body: some View {
        NavigationStack {
            AddonSearchView(query: $query)
        }
        .modifier(PageSearchField(text: $query, prompt: "Library, servers, movies and shows"))
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
