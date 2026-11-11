import SwiftUI

/// Settings' search field (1.26.1), a row at the top of the root: the root
/// draws its own bar on iOS 18 and later, so `.searchable` has no bar to sit in.
struct SettingsSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Settings", text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("settingsSearch")
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    text = ""
                    focused = false
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(.rect)
            }
        }
    }
}

/// Settings' search as the system's own field (1.28.8, iOS 26): in the
/// bottom bar, where iOS 26 puts search, with its Cancel, its keyboard
/// handling and its glass. The root hides the navigation bar (it draws its
/// own for the zoom), so before iOS 26, where the system's field lives in
/// that bar, the row above stays.
struct SettingsSearchBar: ViewModifier {
    @Binding var text: String

    static var isSystem: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .searchable(text: $text, prompt: "Search Settings")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .toolbar { DefaultToolbarItem(kind: .search, placement: .bottomBar) }
                // The tab bar would sit on the field: Settings' root has the bottom to itself.
                .toolbar(.hidden, for: .tabBar)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
