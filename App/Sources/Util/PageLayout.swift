import SwiftUI
import UIKit

/// A page's margins, columns and card sizes from the width it really has
/// (1.30.0). Until then every page asked one question, "wider than 700 pt?",
/// and an iPad got the phone's tiles, only more of them: nine small posters
/// across in landscape.
///
/// By width, not by device or size class alone: an iPad window in Slide Over
/// or a narrow Split View, or the page beside an open sidebar, is as narrow
/// as a phone and gets the phone's layout; drag the window wider and the
/// page follows. An iPhone always gets what it had before 1.30.0, at every
/// width (its landscape included): `regular` is only ever true on an iPad.
struct PageLayout: Equatable {
    /// The page's width (its GeometryReader's, not the screen's).
    let width: CGFloat
    /// An iPad window wide enough for the iPad layout.
    let regular: Bool

    /// The width a page is "wide" from, as before 1.30.0.
    static let wideWidth: CGFloat = 700
    /// The widest a column of text gets on an iPad (title pages, search
    /// results, the downloads list): about 90 characters of body text.
    static let readableWidth: CGFloat = 760

    @MainActor static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    init(width: CGFloat, pad: Bool) {
        self.width = width
        regular = pad && width > Self.wideWidth
    }

    @MainActor init(width: CGFloat) { self.init(width: width, pad: Self.isPad) }

    /// Wider than 700 pt, on any device (the one check pages made before 1.30.0).
    var wide: Bool { width > Self.wideWidth }

    /// The page's side margin; it grows with an iPad's window.
    var margin: CGFloat {
        guard regular else { return wide ? 28 : 20 }
        return width > 1100 ? 44 : width > 900 ? 36 : 28
    }

    /// How many tiles fit: each at least `pitch - spacing` wide, and never
    /// more than one column's share wider than that, so none is stretched.
    private func columns(pitch: CGFloat, spacing: CGFloat, atLeast: Int) -> Int {
        max(atLeast, Int((width - margin * 2 + spacing) / pitch))
    }

    /// Home's poster tiles (14 pt apart). iPad: at least 134 pt wide, so 5
    /// across an 11-inch iPad upright and 7 on its side; the phone's 110 pt
    /// made 6 and 9.
    var posterColumns: Int { columns(pitch: regular ? 148 : 124, spacing: 14, atLeast: 3) }

    /// Home's and a folder's 16:9 tiles (14 pt apart). iPad: at least 226 pt.
    var thumbColumns: Int { columns(pitch: regular ? 240 : 184, spacing: 14, atLeast: 2) }

    /// Discover's poster grid (12 pt apart). iPad: at least 134 pt.
    var discoverColumns: Int { columns(pitch: regular ? 146 : 122, spacing: 12, atLeast: 3) }

    /// A Continue Watching card. iPad: two and a bit to a row, so the next
    /// one shows there is more, between 340 and 420 pt.
    var continueCardWidth: CGFloat {
        guard regular else { return wide ? 320 : min(340, width - margin * 2 - 44) }
        return min(420, max(340, ((width - margin * 2 - 40) / 2.6).rounded(.down)))
    }

    /// The side margin of a column of text: `base` on a phone or in a narrow
    /// window; on an iPad, what centres a column `readableWidth` wide.
    func readableSide(_ base: CGFloat) -> CGFloat {
        guard regular else { return base }
        return max(base, ((width - Self.readableWidth) / 2).rounded(.down))
    }

    /// The same for a List or Form (`contentMargins`): nil where the list
    /// keeps its own margins.
    var readableListInset: CGFloat? {
        guard regular, width > Self.readableWidth + 40 else { return nil }
        return ((width - Self.readableWidth) / 2).rounded(.down)
    }
}

/// Where the tab bar is (1.30.0), for what sits around it.
enum TabChrome {
    /// At the bottom on an iPhone, on an iPad before iOS 18, and in an iPad
    /// window of compact width (Slide Over, a narrow Split View). A wider
    /// iPad window on iOS 18 and later has it at the top, or as the sidebar.
    static func atBottom(regularWidth: Bool, pad: Bool, iOS18: Bool) -> Bool {
        !(pad && iOS18 && regularWidth)
    }

    @MainActor static func atBottom(regularWidth: Bool) -> Bool {
        var iOS18 = false
        if #available(iOS 18.0, *) { iOS18 = true }
        return atBottom(regularWidth: regularWidth, pad: PageLayout.isPad, iOS18: iOS18)
    }
}

extension View {
    /// A list's rows in a centred column on a wide iPad window (1.30.0), as
    /// Settings' pages have had since 1.26.1: search results and downloads
    /// ran the whole 1,200 pt of an iPad on its side. Nothing on an iPhone.
    func readableListWidth() -> some View { modifier(ReadableListWidth()) }

    /// The pointer's highlight on a tile, card, pill or button (1.30.0), on
    /// an iPad: with a trackpad or mouse nothing said what could be clicked.
    /// Not added at all on an iPhone, which has no pointer.
    /// `cornerRadius`: the highlight's shape, where it isn't the view's box
    /// (a poster's rounded corners).
    func pointerHover(cornerRadius: CGFloat? = nil) -> some View { modifier(PointerHover(cornerRadius: cornerRadius)) }
}

private struct PointerHover: ViewModifier {
    let cornerRadius: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if !PageLayout.isPad {
            content
        } else if let cornerRadius {
            content.contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)).hoverEffect(.highlight)
        } else {
            content.hoverEffect(.highlight)
        }
    }
}

private struct ReadableListWidth: ViewModifier {
    @State private var inset: CGFloat?

    func body(content: Content) -> some View {
        content
            // nil keeps the list's own margins (a margin of 0 would run the rows edge to edge).
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let next = PageLayout(width: width).readableListInset
                if next != inset { inset = next }
            }
    }
}
