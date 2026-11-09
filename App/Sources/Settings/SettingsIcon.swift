import SwiftUI

/// A Settings row's tile (1.26.3): the shape iOS Settings uses, in Folio's own
/// colours. Until then the tiles were iOS's rainbow with stock glyphs, which
/// read as generic and fought the cream-and-ink palette. Each tile has a soft
/// top light and a hairline edge (so the deep tones keep their shape on dark
/// cards); About is the Folio leaf. Grows with Dynamic Type.
struct SettingsIcon: View {
    let page: SettingsPage
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 29

    init(_ page: SettingsPage) { self.page = page }

    private var radius: CGFloat { side * 0.225 }

    var body: some View {
        Group {
            if page == .about {
                FolioLeaf()
                    .padding(side * 0.17)
                    .frame(width: side, height: side)
                    .background(Theme.card, in: .rect(cornerRadius: radius, style: .continuous))
            } else {
                Image(systemName: page.symbol)
                    .symbolVariant(.fill)
                    .font(.system(size: side * 0.5, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: side, height: side)
                    .background {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(page.tint.gradient)
                            .overlay {
                                // Light from above, as on the app's glass.
                                LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center)
                                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
                            }
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
