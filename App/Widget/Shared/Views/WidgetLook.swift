import CoreImage
import SwiftUI
import UIKit
import WidgetKit

// The widgets' look. Built into the widget extension and, for the lab's
// gallery (-labWidgets), into the app.
//
// 1.24.1 (the user, 7 Nov: the paper-and-ink widgets looked out of place in
// light mode; use the Clear look in light mode and the Tinted look in dark):
//   - Light: glass. iOS lets a widget be see-through only in its own Clear
//     and Tinted appearances (the accented rendering mode); in full colour a
//     clear container shows no wallpaper (Apple, "Displaying the right widget
//     background"; developer forums thread 845586, unanswered). So the glass
//     is drawn: the widget's own artwork, softened, under a smoky veil and a
//     light rim, with white text, as the Clear look has over a wallpaper.
//   - Dark: tinted. A deep blue glass with text in a light tint.
//   - Clear and Tinted (iOS): the accented rendering mode. iOS removes the
//     background and colours everything by its alpha, except images marked
//     full colour, which Apple reserves for media artwork. Artwork is full
//     colour there (1.24.0 made it grey and faint), and so are the dark
//     gradients that keep text readable over a picture (drawn as images, or
//     iOS would turn them into white haze). Text and bars stay near solid.

enum WidgetLookKind { case glass, tinted, accented }

/// The colours of the look the widget is drawn in.
struct WidgetPalette {
    var kind: WidgetLookKind
    var ink: Color
    var sub: Color
    var track: Color
    var chip: Color
    var line: Color
    var accent: Color
    /// Today's highlight (a chip, a day in the week strip) and its text.
    var today: Color
    var todayInk: Color
    /// A primary button on a card, and its text.
    var pill: Color
    var pillInk: Color

    var accented: Bool { kind == .accented }

    /// The Tinted look's colour (the mockup's blue) and its light shade for text.
    static let tint = Color(hex: 0x7FB3E6)
    static let tintLight = Color(hex: 0xB2D1F0)
    static let tintInk = Color(hex: 0x122030)

    init(scheme: ColorScheme, mode: WidgetRenderingMode) {
        if mode == .accented || mode == .vibrant {
            kind = .accented
            ink = .white
            sub = .white.opacity(0.85)
            track = .white.opacity(0.35)
            chip = .white.opacity(0.24)
            line = .white.opacity(0.35)
            accent = .white
            today = .white
            todayInk = .black
            pill = .white
            pillInk = .black
        } else if scheme == .dark {
            kind = .tinted
            ink = Self.tintLight
            sub = Self.tintLight.opacity(0.78)
            track = Self.tintLight.opacity(0.25)
            chip = Self.tint.opacity(0.25)
            line = Self.tint.opacity(0.35)
            accent = Self.tintLight
            today = Self.tintLight
            todayInk = Self.tintInk
            pill = Self.tintLight
            pillInk = Self.tintInk
        } else {
            kind = .glass
            ink = .white
            sub = .white.opacity(0.82)
            track = .white.opacity(0.3)
            chip = .white.opacity(0.22)
            line = .white.opacity(0.3)
            accent = .white
            today = .white.opacity(0.94)
            todayInk = Color(hex: 0x141312)
            pill = .white.opacity(0.94)
            pillInk = Color(hex: 0x141312)
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

/// The lab's gallery draws widgets in the app, where a container background
/// isn't drawn: there the backdrop goes behind the content itself.
private struct WidgetLabKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var widgetLab: Bool {
        get { self[WidgetLabKey.self] }
        set { self[WidgetLabKey.self] = newValue }
    }
}

extension View {
    /// The widget's card: the look's backdrop (iOS puts its own glass or
    /// tint there in Clear and Tinted). `art`: the picture the glass is
    /// made of, usually the widget's first title.
    func widgetCard(_ t: WidgetPalette, art: UIImage? = nil, seed: String = "") -> some View {
        modifier(WidgetCard(t: t, art: art, seed: seed))
    }
}

private struct WidgetCard: ViewModifier {
    let t: WidgetPalette
    let art: UIImage?
    let seed: String
    @Environment(\.widgetLab) private var lab

    func body(content: Content) -> some View {
        if lab {
            content.background { WidgetBackdrop(t: t, art: art, seed: seed) }
        } else {
            content.containerBackground(for: .widget) { WidgetBackdrop(t: t, art: art, seed: seed) }
        }
    }
}

/// Glass in light mode, tinted glass in dark mode; nothing in Clear and
/// Tinted, where iOS draws its own.
struct WidgetBackdrop: View {
    let t: WidgetPalette
    var art: UIImage? = nil
    var seed: String = ""

    var body: some View {
        switch t.kind {
        case .accented:
            Color.clear
        case .tinted:
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1B2836), Color(hex: 0x0E151D)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let soft = art.flatMap(WidgetImages.softened) {
                    Image(uiImage: soft).resizable().interpolation(.high).scaledToFill().opacity(0.3)
                }
                WidgetPalette.tint.opacity(0.14)
                ContainerRelativeShape().strokeBorder(WidgetPalette.tint.opacity(0.35), lineWidth: 1)
            }
        case .glass:
            ZStack {
                Image(uiImage: art.flatMap(WidgetImages.softened) ?? WidgetImages.wallpaper(seed))
                    .resizable().interpolation(.high).scaledToFill()
                // Smoky enough for white text over the brightest picture.
                Color.black.opacity(0.34)
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)
                ContainerRelativeShape().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
        }
    }
}

// MARK: - Pictures

/// Pictures made for the widgets: softened artwork for the glass, the
/// gradients under text, the stand-in art. Made once per process.
enum WidgetImages {
    private static let lock = NSLock()

    /// The picture made small and blurred: frosted glass. A Gaussian blur on
    /// a 64-pixel copy (a bare upscale of a tiny copy showed blocks: lab, 7 Nov).
    /// Not kept, as each timeline reads its pictures again; it's two small drawings.
    static func softened(_ image: UIImage) -> UIImage? {
        let side: CGFloat = 64
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { _ in
            // Filled like the widget fills it: the middle of the picture.
            let s = image.size, k = max(side / max(s.width, 1), side / max(s.height, 1))
            let w = s.width * k, h = s.height * k
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        guard let cg = small.cgImage else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let blurred = CIImage(cgImage: cg).clampedToExtent().applyingGaussianBlur(sigma: 7).cropped(to: rect)
        guard let out = ciContext.createCGImage(blurred, from: rect) else { return nil }
        return UIImage(cgImage: out)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    /// Dark at the bottom (or the left), clear at the other end.
    static let scrimBottom = gradient(vertical: true, stops: [(0.3, 0), (1, 0.82)])
    static let scrimLeading = gradient(vertical: false, stops: [(0, 0.82), (0.6, 0.35), (1, 0)])

    private static func gradient(vertical: Bool, stops: [(CGFloat, CGFloat)]) -> UIImage {
        let size = vertical ? CGSize(width: 4, height: 256) : CGSize(width: 256, height: 4)
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let colors = stops.map { UIColor.black.withAlphaComponent($0.1).cgColor } as CFArray
            let locations = stops.map(\.0)
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else { return }
            let end = vertical ? CGPoint(x: 0, y: size.height) : CGPoint(x: size.width, y: 0)
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: end, options: [.drawsAfterEndLocation])
        }
    }

    private static let pairs: [(UInt32, UInt32)] = [
        (0x2E4A57, 0xD9B98A), (0xC7643C, 0xF2C46D), (0x3B2F4A, 0xE2876A), (0x4E6B3A, 0xC9D29B),
        (0x55535A, 0xA7B5C2), (0x8A6E4B, 0xE8D3A6), (0x33414F, 0x9FB4C7), (0x5A3A3A, 0xD89A86),
    ]
    private static var artCache: [String: UIImage] = [:]

    /// Two colours and two discs, picked by the title: the picture a title
    /// without artwork gets (an image, so it keeps its colours in Clear and Tinted).
    static func generated(_ seed: String) -> UIImage {
        lock.lock(); defer { lock.unlock() }
        if let a = artCache[seed] { return a }
        let h = seed.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let pair = pairs[Int(h % UInt32(pairs.count))]
        let size = CGSize(width: 120, height: 120)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(rgb: pair.0).setFill(); c.fill(CGRect(origin: .zero, size: size))
            UIColor(rgb: pair.1).withAlphaComponent(0.55).setFill()
            c.fillEllipse(in: CGRect(x: -27, y: -45, width: 114, height: 114))
            c.setFillColor(UIColor(rgb: pair.0).darker.cgColor)
            c.fillEllipse(in: CGRect(x: 72, y: 30, width: 72, height: 72))
        }
        artCache[seed] = img
        return img
    }

    /// A wallpaper-like ground for glass with no picture to make it from.
    static func wallpaper(_ seed: String) -> UIImage {
        let art = generated(seed.isEmpty ? "folio" : seed)
        return softened(art) ?? art
    }
}

/// A picture that fills its frame, in full colour in every look (Apple keeps
/// full colour for media artwork in Clear and Tinted). Without a picture: the
/// title's generated art.
struct WidgetArt: View {
    let image: UIImage?
    var seed: String = ""

    var body: some View {
        Color.clear.overlay {
            fullColor(Image(uiImage: image ?? WidgetImages.generated(seed)).resizable()).scaledToFill()
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// An image kept in its own colours when iOS tints the widget.
@ViewBuilder
func fullColor(_ image: Image) -> some View {
    if #available(iOS 18.0, *) {
        image.widgetAccentedRenderingMode(.fullColor)
    } else {
        image
    }
}

/// The dark gradient under text on a picture: from the bottom, or from the
/// left for the wide widgets. An image, so it stays dark in Clear and Tinted.
struct WidgetScrim: View {
    var leading = false

    var body: some View {
        fullColor(Image(uiImage: leading ? WidgetImages.scrimLeading : WidgetImages.scrimBottom).resizable())
            .accessibilityHidden(true)
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

/// A pill on a picture. Primary: solid with dark text (the tint and its ink
/// in dark mode). Secondary: frosted with white text. In Clear and Tinted,
/// which colour by alpha alone, the primary's text is cut out of it.
struct WidgetPill: View {
    let text: String
    var icon: String? = nil
    var primary = true
    var height: CGFloat = 32
    var font: Font = .system(size: 12, weight: .bold)

    var body: some View {
        Looked { t in
            let label = HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .black)) }
                if !text.isEmpty { Text(text).lineLimit(1) }
            }
            .font(font)
            .padding(.horizontal, text.isEmpty ? 0 : 13)
            .frame(minWidth: height, minHeight: height, maxHeight: height)

            if primary && t.accented {
                label.foregroundStyle(.black).blendMode(.destinationOut)
                    .background(Capsule().fill(.white))
                    .compositingGroup()
                    .fixedSize(horizontal: true, vertical: false)
            } else if primary {
                label.foregroundStyle(t.kind == .tinted ? t.pillInk : Color(hex: 0x141312))
                    .background(Capsule().fill(t.kind == .tinted ? t.pill : .white))
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                label.foregroundStyle(.white).background(Capsule().fill(.white.opacity(0.22)))
                    .fixedSize(horizontal: true, vertical: false)
            }
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
        WidgetArt(image: image, seed: seed)
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
            .widgetCard(t, seed: title)
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

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    var darker: UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s, brightness: b * 0.75, alpha: a)
    }
}
