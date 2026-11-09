import SwiftUI

/// One setting laid out as iOS Settings does (1.26.3): the control in a group
/// of its own (with any rows that depend on it), and what it does under the
/// group, so the text starts below the whole row, switch included.
/// `header`: the section title, on the first group of a section.
///
/// 1.27.0: the text is a row of its own just under the group (no card, a
/// footer's grey and insets), and opening it swaps the two-line row for the
/// whole text. A List animates rows coming and going, sliding everything
/// below; it doesn't animate a footer's or a row's size: as a footer (1.26.3)
/// or a growing row, the groups below jumped to their new place at once and
/// the text slid open under them (screen recordings, 9 Nov).
struct SettingGroup<Content: View>: View {
    let header: String?
    let footer: String
    @ViewBuilder var content: Content
    @State private var expanded = false

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
        }
        // Both sections the same small gap (how a List combines two different
        // ones isn't predictable); the room before the next group is the
        // text's own bottom inset.
        .listSectionSpacing(.custom(settingGroupGap))
        Section {
            Group {
                if expanded {
                    SettingDescription(footer, expanded: true) { toggle() }
                } else {
                    SettingDescription(footer, expanded: false) { toggle() }
                }
            }
            // The page's own colour (not clear): mid-swap the row coming in
            // covers the one going, whose "more" showed through.
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 22, trailing: 16))
        }
        .listSectionSpacing(.custom(settingGroupGap))
    }

    private func toggle() {
        withAnimation(.smooth(duration: 0.35)) { expanded.toggle() }
    }
}

/// The gap between a setting's group and its text, and between sections.
private let settingGroupGap: CGFloat = 7
