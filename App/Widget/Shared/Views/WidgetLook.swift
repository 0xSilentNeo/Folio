import SwiftUI
import UIKit
import WidgetKit

// The widgets' look (1.24.0). Built into the widget extension and, for the
// lab's gallery (-labWidgets), into the app.
//
// One look per widget, which follows the Home Screen's appearance:
//   - Light and Dark: Folio's paper and ink, chosen by the system's
//     light/dark setting (Automatic switches with it).
//   - Clear and Tinted: iOS draws the widget in the accented rendering mode
//     (Apple, "Optimizing your widget for accented rendering mode and Liquid
//     Glass"): it removes the background, puts its own glass or tint there,
//     and colours everything by its alpha alone. So in that mode the colours
//     below are white at different strengths, the artwork is desaturated
//     (its brightness becomes how much of the tint shows) and faint, and
//     the dark gradients that keep text readable over a picture go, since
//     iOS would turn them into white haze.

/// The colours of the look the widget is drawn in.
struct WidgetPalette {
    var card: Color
    var ink: Color
    var sub: Color
    var track: Color
    var chip: Color
    var line: Color
    var accent: Color
    /// Today's highlight (a chip, a day in the week strip) and its text.
    var today: Color
    var todayInk: Color
    /// iOS colours the widget itself (Clear, Tinted, the Lock Screen).
    var accented: Bool

    init(scheme: ColorScheme, mode: WidgetRenderingMode) {
        if mode == .accented || mode == .vibrant {
            accented = true
            card = .clear
            ink = .white
            sub = .white.opacity(0.72)
            track = .white.opacity(0.28)
            chip = .white.opacity(0.2)
            line = .white.opacity(0.3)
            accent = .white
            today = .white
            todayInk = .black
        } else if scheme == .dark {
            accented = false
            card = Color(hex: 0x1C1A18)
            ink = Color(hex: 0xF3EEE6)
            sub = Color(hex: 0xA8A197)
            track = Color(hex: 0x3A3632)
            chip = Color(hex: 0x2B2825)
            line = Color(hex: 0x34302B)
            accent = Color(hex: 0xE2876A)
            today = Color(hex: 0xF3EEE6)
            todayInk = Color(hex: 0x141312)
        } else {
            accented = false
            card = Color(hex: 0xFBF9F5)
            ink = Color(hex: 0x1B1A18)
            sub = Color(hex: 0x5E5850)
            track = Color(hex: 0xE3DDD3)
            chip = Color(hex: 0xECE6DC)
            line = Color(hex: 0xDDD6CB)
            accent = Color(hex: 0xB0452A)
            today = Color(hex: 0x1B1A18)
            todayInk = Color(hex: 0xFBF9F5)
        }
    }
}

/// Reads the look from the environment for its content.
struct Looked<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    @ViewBuilder let content: (WidgetPalette) -> Content

    var body: some View { content(WidgetPalette(scheme: scheme, mode: mode)) }
}

extension View {
    /// The widget's card: the look's paper (iOS replaces it in Clear and Tinted).
    func widgetCard(_ t: WidgetPalette) -> some View {
        containerBackground(for: .widget) { t.accented ? Color.clear : t.card }
    }
}

// MARK: - Pictures

/// A picture that fills its frame: in full colour, or desaturated and faint
/// when iOS tints the widget, so text over it stays readable. Without a
/// picture: a gradient picked by the title, as Home's generated art does.
struct WidgetArt: View {
    let image: UIImage?
    var seed: String = ""
    /// How strong the picture is in Clear and Tinted.
    var accentedOpacity: Double = 0.38
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let accented = mode == .accented || mode == .vibrant
        Group {
            if let image {
                Color.clear.overlay {
                    if #available(iOS 18.0, *) {
                        Image(uiImage: image).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
                    } else {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipped()
            } else {
                GeneratedWidgetArt(seed: seed)
            }
        }
        .opacity(accented ? accentedOpacity : 1)
        .accessibilityHidden(true)
    }
}

/// Two warm colours and a soft disc, picked by the title: the picture a
/// title without artwork gets.
struct GeneratedWidgetArt: View {
    let seed: String
    @Environment(\.widgetRenderingMode) private var mode

    private static let pairs: [(UInt32, UInt32)] = [
        (0x2E4A57, 0xD9B98A), (0xC7643C, 0xF2C46D), (0x3B2F4A, 0xE2876A), (0x4E6B3A, 0xC9D29B),
        (0x55535A, 0xA7B5C2), (0x8A6E4B, 0xE8D3A6), (0x33414F, 0x9FB4C7), (0x5A3A3A, 0xD89A86),
    ]

    var body: some View {
        if mode == .accented || mode == .vibrant {
            // Tinted by alpha alone, the discs would be one flat block: a
            // faint pane with a film mark instead.
            ZStack {
                Color.white.opacity(0.14)
                Image(systemName: "film").font(.system(size: 16, weight: .light)).foregroundStyle(.white.opacity(0.5))
            }
        } else {
            discs
        }
    }

    private var discs: some View {
        let h = seed.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let pair = Self.pairs[Int(h % UInt32(Self.pairs.count))]
        return GeometryReader { g in
            ZStack {
                Color(hex: pair.0)
                Circle().fill(Color(hex: pair.1)).opacity(0.55)
                    .frame(width: g.size.width * 0.95, height: g.size.width * 0.95)
                    .position(x: g.size.width * 0.25, y: g.size.height * 0.1)
                Circle().fill(Color(hex: pair.0)).brightness(-0.12)
                    .frame(width: g.size.width * 0.6, height: g.size.width * 0.6)
                    .position(x: g.size.width * 0.9, y: g.size.height * 0.55)
            }
        }
        .clipped()
    }
}

/// The dark gradient under text on a picture: from the bottom, or from the
/// left for the wide widgets. None when iOS tints the widget.
struct WidgetScrim: View {
    var leading = false
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        if mode == .accented || mode == .vibrant {
            Color.clear
        } else if leading {
            LinearGradient(stops: [.init(color: .black.opacity(0.82), location: 0), .init(color: .black.opacity(0.35), location: 0.6),
                                   .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
        } else {
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.82), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - Pieces

/// Folio's leaf.
struct WidgetLeaf: Shape {
    func path(in r: CGRect) -> Path {
        // M3 13 C3 7 7 3 13 3 c0 6 -4 10 -10 10 z, in a 16-point box.
        let s = min(r.width, r.height) / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        path.move(to: p(3, 13))
        path.addCurve(to: p(13, 3), control1: p(3, 7), control2: p(7, 3))
        path.addCurve(to: p(3, 13), control1: p(13, 9), control2: p(9, 13))
        path.closeSubpath()
        return path
    }
}

struct WidgetBar: View {
    let progress: Double
    var track: Color
    var fill: Color
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(height, g.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct WidgetRing: View {
    let progress: Double
    var track: Color
    var fill: Color
    var width: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: width)
            Circle().trim(from: 0, to: min(1, max(0.02, progress)))
                .stroke(fill, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
        .accessibilityHidden(true)
    }
}

/// A pill on a picture. Full colour: white with dark text (primary) or
/// frosted with white text. Tinted and Clear colour by alpha alone, where
/// dark text on white would vanish: the text is cut out of the pill.
struct WidgetPill: View {
    let text: String
    var icon: String? = nil
    var primary = true
    var height: CGFloat = 32
    var font: Font = .system(size: 12, weight: .bold)
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let accented = mode == .accented || mode == .vibrant
        let label = HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .black)) }
            if !text.isEmpty { Text(text).lineLimit(1) }
        }
        .font(font)
        .padding(.horizontal, text.isEmpty ? 0 : 13)
        .frame(minWidth: height, minHeight: height, maxHeight: height)

        if primary && accented {
            label.foregroundStyle(.black).blendMode(.destinationOut)
                .background(Capsule().fill(.white))
                .compositingGroup()
                .fixedSize(horizontal: true, vertical: false)
        } else if primary {
            label.foregroundStyle(Color(hex: 0x141312)).background(Capsule().fill(.white)).fixedSize(horizontal: true, vertical: false)
        } else {
            label.foregroundStyle(.white).background(Capsule().fill(.white.opacity(0.22))).fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Text on a solid chip, cut out of it when iOS tints the widget.
struct WidgetBadge<Label: View>: View {
    var fill: Color
    var ink: Color
    var radius: CGFloat = 8
    @ViewBuilder let label: () -> Label
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        if mode == .accented || mode == .vibrant {
            label().foregroundStyle(.black).blendMode(.destinationOut)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white))
                .compositingGroup()
        } else {
            label().foregroundStyle(ink)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
        }
    }
}

/// A small picture in a list (a thumbnail, a poster).
struct WidgetThumb: View {
    let image: UIImage?
    var seed: String
    var radius: CGFloat = 6

    var body: some View {
        WidgetArt(image: image, seed: seed, accentedOpacity: 0.55)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// "Nothing to continue", "Open Folio once", "Can't reach Folio": a widget
/// with nothing to show says why, and where a tap takes you.
struct WidgetMessage: View {
    let icon: String
    let title: String
    let detail: String
    var action: String? = nil
    var url: URL? = nil

    var body: some View {
        Looked { t in
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(t.ink).widgetAccentable()
                Spacer(minLength: 0)
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(t.ink).lineLimit(2)
                Text(detail).font(.system(size: 11)).foregroundStyle(t.sub).lineLimit(3)
                if let action {
                    Text(action).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.accent).padding(.top, 2).widgetAccentable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(14)
            .widgetCard(t)
            .widgetURL(url)
        }
    }
}

// MARK: - Colours

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}
