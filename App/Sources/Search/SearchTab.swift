import SwiftUI

/// The search tab (1.22.4): one field for your library, the files on your
/// WebDAV and Real-Debrid servers, and titles on IMDb and your addons
/// (AddonSearchView with the tab's text).
struct SearchTabView: View {
    @Binding var query: String

    var body: some View {
        NavigationStack {
            AddonSearchView(tabQuery: $query)
        }
        .modifier(PageSearchField(text: $query))
    }
}

/// The field's prompt, wherever it is drawn.
private let searchPrompt = "Library, servers, titles"

/// iOS 26: the field belongs to the tab view, so the search tab's button
/// beside the tab bar opens into it. Before iOS 26 the page has it.
/// Choosing the search tab puts the keyboard up, as Discover's search page
/// did: you came to type.
struct TabBarSearchField: ViewModifier {
    @Binding var text: String
    /// The search tab is the one showing.
    let selected: Bool
    @FocusState private var focused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.searchable(text: $text, prompt: searchPrompt)
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

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
        } else {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
        }
        #else
        content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
        #endif
    }
}

extension Notification.Name {
    /// The search tab's Search key, with the text (TabBarSearchField → AddonSearchView).
    static let searchTabSubmitted = Notification.Name("folio.searchTabSubmitted")
}
