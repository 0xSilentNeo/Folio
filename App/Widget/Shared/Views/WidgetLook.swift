import CoreImage
import SwiftUI
import UIKit
import WidgetKit

// The widgets' look. Built into the widget extension and, for the lab's
// gallery (-labWidgets), into the app.
//
// 1.28.2 (the user, 10 Nov: one clear Liquid Glass look, no light and dark
// styles): the same clear glass in light and dark mode. 1.24.1 had glass in
// light mode and a deep blue tint in dark.
//   - Full colour: clear glass, drawn. iOS lets a widget be see-through only
//     in its own Clear and Tinted appearances (the accented rendering mode);
//     in full colour a clear container shows no wallpaper (Apple,
//     "Displaying the right widget background"; developer forums thread
//     845586, unanswered). So the glass is drawn: the widget's own picture,
//     blurred and toned down (1.28.4; 1.28.2 used it at full colour), with
//     light through it from the top and a Liquid Glass rim.
//   - Clear and Tinted (iOS): the accented rendering mode. iOS removes the
//     background and colours everything by its alpha, except images marked
//     full colour, which Apple reserves for media artwork. Artwork is full
//     colour there (1.24.0 made it grey and faint), and so are the dark
//     gradients that keep text readable over a picture (drawn as images, or
//     iOS would turn them into white haze). Text and bars stay near solid.

enum WidgetLookKind { case glass, accented }

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

    /// iOS's Tinted look's colour, roughly (the lab's gallery draws it).
    static let tint = Color(hex: 0x7FB3E6)

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
        } else {
            // Clear glass in light and dark mode alike (1.28.2).
            kind = .glass
            ink = .white
            sub = .white.opacity(0.86)
            track = .white.opacity(0.3)
            chip = .white.opacity(0.2)
            line = .white.opacity(0.28)
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

/// The glass in full colour, light or dark mode; nothing in Clear and
/// Tinted, where iOS draws its own.
///
/// 1.28.4, the user's choice (10 Nov): the widget's own picture, heavily
/// blurred, with most of its colour taken out and darkened, as frosted
/// glass, the way Apple's Music widgets do it, with nothing to set up.
/// 1.28.2 used the picture at full colour, and a pink poster tinted the
/// whole widget pink. No picture: neutral glass. On top, always: light from
/// the top, a darker edge and a bright rim.
struct WidgetBackdrop: View {
    let t: WidgetPalette
    var art: UIImage? = nil
    var seed: String = ""

    var body: some View {
        switch t.kind {
        case .accented:
            Color.clear
        case .glass:
            ZStack {
                if let frosted = art.flatMap(WidgetImages.softened) {
                    // The widget's picture as frosted glass: blurred, its
                    // colour mostly gone, dimmed for white text.
                    Image(uiImage: frosted).resizable().interpolation(.high).scaledToFill()
                        .saturation(0.4)
                    Color.black.opacity(WidgetImages.veil(for: frosted))
                } else {
                    // No picture: neutral glass.
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.15)], startPoint: .top, endPoint: .bottom)
                }
                // Light through the glass, from the top.
                LinearGradient(stops: [.init(color: .white.opacity(0.12), location: 0),
                                       .init(color: .white.opacity(0.03), location: 0.4),
                                       .init(color: .white.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                // The glass's thickness: its edge a little darker.
                ContainerRelativeShape()
                    .strokeBorder(.black.opacity(0.16), lineWidth: 6).blur(radius: 5)
                // A soft sheen inside the edge, as the glass bends the light.
                ContainerRelativeShape().inset(by: 1.5)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 4).blur(radius: 3)
                // The rim: bright where the light catches it, faint across.
                ContainerRelativeShape().strokeBorder(
                    LinearGradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                           .init(color: .white.opacity(0.14), location: 0.35),
                                           .init(color: .white.opacity(0.06), location: 0.65),
                                           .init(color: .white.opacity(0.28), location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
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
    /// Kept for the picture it was made of (1.30.2): every entry of a
    /// timeline draws the same picture, and each drew its glass again.
    static func softened(_ image: UIImage) -> UIImage? {
        let key = NSNumber(value: Int(bitPattern: ObjectIdentifier(image)))
        if let hit = softCache.object(forKey: key), hit.source === image { return hit.image }
        guard let made = soften(image) else { return nil }
        softCache.setObject(Softened(source: image, image: made), forKey: key)
        return made
    }

    /// A softened picture and the one it was made of (weak: an address used again isn't mistaken for it).
    private final class Softened {
        weak var source: UIImage?
        let image: UIImage
        init(source: UIImage, image: UIImage) { self.source = source; self.image = image }
    }

    private static let softCache: NSCache<NSNumber, Softened> = {
        let c = NSCache<NSNumber, Softened>()
        c.countLimit = 12
        return c
    }()

    private static func soften(_ image: UIImage) -> UIImage? {
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

    /// How dark the veil over a frosted picture is: 0.25 over a dark one to
    /// 0.55 over a white one, so white text reads and the glass stays light.
    static func veil(for frosted: UIImage) -> Double {
        0.25 + 0.3 * Double(luminance(frosted))
    }

    /// The picture's average brightness, 0…1 (drawn into one pixel).
    static func luminance(_ image: UIImage) -> CGFloat {
        var px = [UInt8](repeating: 0, count: 4)
        guard let cg = image.cgImage,
              let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * CGFloat(px[0]) + 0.7152 * CGFloat(px[1]) + 0.0722 * CGFloat(px[2])) / 255
    }


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
    /// Which part of the picture shows when it's cropped (a poster in a
    /// square: its top, the faces, not its title under the widget's own).
    var alignment: Alignment = .center

    var body: some View {
        Color.clear.overlay(alignment: alignment) {
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

/// A pill on a picture. Primary: solid with dark text. Secondary: frosted
/// with white text. In Clear and Tinted,
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
                    .background(.white, in: .capsule)
                    .compositingGroup()
                    .fixedSize(horizontal: true, vertical: false)
            } else if primary {
                label.foregroundStyle(t.pillInk)
                    .background(t.pill, in: .capsule)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                label.foregroundStyle(.white).background(.white.opacity(0.22), in: .capsule)
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
                .background(.white, in: .rect(cornerRadius: radius, style: .continuous))
                .compositingGroup()
        } else {
            label().foregroundStyle(ink)
                .background(fill, in: .rect(cornerRadius: radius, style: .continuous))
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
