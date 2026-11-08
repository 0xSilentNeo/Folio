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
