import SwiftUI

/// A row on Settings' root: the page's tile and name, an optional value on
/// the right, and the page pushed by value onto Home's stack.
struct SettingsRow<Value: View>: View {
    let page: SettingsPage
    let value: Value

    init(_ page: SettingsPage, @ViewBuilder value: () -> Value) {
        self.page = page
        self.value = value()
    }

    var body: some View {
        NavigationLink(value: LibraryRoute.settingsPage(page)) {
            LabeledContent {
                value
            } label: {
                Label {
                    Text(page.title)
                } icon: {
                    SettingsIcon(page)
                }
            }
        }
        .accessibilityIdentifier("settings." + page.rawValue)
    }
}

extension SettingsRow where Value == EmptyView {
    init(_ page: SettingsPage) { self.init(page) { EmptyView() } }
}
