import SwiftUI

/// Folio's own "working on it" mark (1.23.0), in place of the system
/// spinner: the leaf from the icon, with a light running round its outline
/// and the leaf breathing under it. Reduce Motion: the leaf only breathes.
///
/// Sizes follow the spinner's: `.small` sits in a row or a header, `.regular`
/// in a button or a list, `.large` over a page or the video.
struct FolioSpinner: View {
    enum Size {
        case small, regular, large
        var points: CGFloat {
            switch self {
            case .small: return 16
            case .regular: return 22
            case .large: return 40
            }
        }
    }

    var size: Size = .regular
    /// The leaf's colour: the accent on pages, white over the video.
    var tint: Color = Theme.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One lap of the outline, in seconds.
    static let lap: Double = 1.25
    /// How much of the outline the light covers.
    static let trail: CGFloat = 0.34

    var body: some View {
        let side = size.points
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: Self.lap) / Self.lap)
            // 0…1…0 over two laps: the leaf's fill and the light's strength.
            let breath = CGFloat(0.5 - 0.5 * cos(t / (Self.lap * 2) * 2 * .pi))
            ZStack {
                LeafShape().fill(tint.opacity(0.10 + 0.12 * breath))
                LeafShape().stroke(tint.opacity(0.22), style: StrokeStyle(lineWidth: side * 0.07, lineJoin: .round))
                if !reduceMotion {
                    LeafTrace(phase: phase, length: Self.trail)
                        .stroke(tint, style: StrokeStyle(lineWidth: side * 0.11, lineCap: .round, lineJoin: .round))
                }
            }
            .opacity(reduceMotion ? 0.55 + 0.45 * Double(breath) : 1)
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel("Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A piece of the leaf's outline, `length` long, starting at `phase`
/// (both 0…1 of the whole outline), carried over the end back to the start.
struct LeafTrace: Shape {
    var phase: CGFloat
    var length: CGFloat

    func path(in r: CGRect) -> Path {
        let leaf = LeafShape().path(in: r)
        let start = phase - floor(phase)
        let end = start + length
        var p = leaf.trimmedPath(from: start, to: min(1, end))
        if end > 1 { p.addPath(leaf.trimmedPath(from: 0, to: end - 1)) }
        return p
    }
}

/// A line of what's happening with the leaf before it: "Searching Plex and
/// Jellyfin…" in a list or under a header.
struct FolioWorkingRow: View {
    let text: String
    var size: FolioSpinner.Size = .small

    var body: some View {
        HStack(spacing: 10) {
            FolioSpinner(size: size)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
