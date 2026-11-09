import SwiftUI

/// One setting laid out as iOS Settings does (1.26.3): the control in a group
/// of its own (with any rows that depend on it), and what it does in the
/// footer under the group, so the text starts below the whole row, switch
/// included. Until then the text sat inside the row, 2 pt under the switch.
/// `header`: the section title, on the first group of a section.
struct SettingGroup<Content: View>: View {
    let header: String?
    let footer: String
    @ViewBuilder var content: Content

    init(_ header: String? = nil, footer: String, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            if let header { Text(header) }
        } footer: {
            SettingDescription(footer)
        }
    }
}
