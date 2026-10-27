import SwiftUI
import UIKit

/// Folio's palette (from the brand mockup: ink, graphite, taupe, cream).
/// Every colour is a light/dark pair, resolved from the trait collection, so
/// one token works in both appearances. The player always runs dark (its
/// window and panels force `.dark`), so there `accent` is the cream.
enum Theme {
    /// Buttons, links, progress, selection. Ink on light, cream on dark.
    static let accent = Color(uiColor: uiAccent)
    /// Text and icons drawn *on* `accent` (a selected chip, the Play button).
    static let onAccent = Color(uiColor: uiOnAccent)
    static let uiAccent = UIColor.dynamic(light: 0x1B1A18, dark: 0xEEE9E1)
    static let uiOnAccent = UIColor.dynamic(light: 0xF7F4EE, dark: 0x161514)
    static let accentSoft = Color(light: 0x1B1A18, dark: 0xEEE9E1, alpha: 0.10)
    static let background = Color(light: 0xF1EDE6, dark: 0x121110)
    static let card = Color(light: 0xFBF9F6, dark: 0x1D1C1A)
    static let cardHighlight = Color(light: 0xE7E2D9, dark: 0x292725)
    /// Unselected chips, capsule buttons, row tints: a faint ink or white wash.
    static let fill = Color(light: 0x1B1A18, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.11)
    static let hairline = Color(light: 0x1B1A18, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.09)
    static let secondaryText = Color.secondary
    static let taupe = Color(light: 0xC4B8AA, dark: 0xC4B8AA)
    static let graphite = Color(light: 0x8B8784, dark: 0x8B8784)
    static let shadow = Color(light: 0x2B2118, dark: 0x000000, lightAlpha: 0.22, darkAlpha: 0.5)
    /// Top of a hero picture, under the status bar: a cream wash on light
    /// (dark status text stays readable), a dark one on dark.
    static let topScrim = Color(light: 0xF1EDE6, dark: 0x000000, lightAlpha: 0.6, darkAlpha: 0.25)
    /// The Play button label's emboss: a shadow under cream text, a light
    /// edge under ink text.
    static let labelEmboss = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.25, darkAlpha: 0.35)
    /// The Play button's face.
    static let gradient = LinearGradient(colors: [Color(light: 0x3A3733, dark: 0xF7F3EC), Color(light: 0x141312, dark: 0xCEC6BA)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    static let wordmarkFont = "AvenirNext-Regular"
    /// Switch track when on. Ink on light; on dark a warm taupe, not the cream
    /// accent: the white knob vanished on a cream track (screenshot run).
    static let switchTint = Color(light: 0x1B1A18, dark: 0xA08D77)
    /// Swipe-action buttons whose icon and label are white (system swipe
    /// actions draw them white on the tint): dark enough in both modes. The
    /// cream accent left a white eye on cream (27 Oct screenshots).
    static let swipeTint = Color(light: 0x1B1A18, dark: 0x7D6B58)
}

/// Every switch in the app: the system switch with `Theme.switchTint`.
struct BrandSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(SwitchToggleStyle()).tint(Theme.switchTint)
    }
}

extension View {
    /// Lists and forms on the page colour (cream / ink) instead of the
    /// system's grouped grey, so they match Home and the title pages.
    func brandListBackground() -> some View {
        scrollContentBackground(.hidden).background(Theme.background.ignoresSafeArea())
    }

    /// A fade from the page colour under the status bar and the Back button,
    /// shown once the page has scrolled past its header (iOS 18+), so text
    /// never slides under them with nothing behind it.
    func topScrollScrim(after offset: CGFloat = 140) -> some View { modifier(TopScrollScrim(threshold: offset)) }
}

struct TopScrollScrim: ViewModifier {
    let threshold: CGFloat
    @State private var shown = false
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > threshold } action: { _, v in
                    withAnimation(.easeOut(duration: 0.2)) { shown = v }
                }
                .overlay(alignment: .top) {
                    // Solid behind the Back / ⋯ buttons (to ~56 pt below the safe
                    // area), then fades out: 64 pt left the Resume button showing
                    // under Back (screenshot run 2).
                    LinearGradient(stops: [.init(color: Theme.background, location: 0), .init(color: Theme.background, location: 0.62),
                                           .init(color: Theme.background.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 92)
                        .ignoresSafeArea(edges: .top)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    /// Light/dark pair, resolved by the system from the trait collection.
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> UIColor {
        let l = UIColor(hex: light, alpha: lightAlpha), d = UIColor(hex: dark, alpha: darkAlpha)
        return UIColor { $0.userInterfaceStyle == .dark ? d : l }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32, alpha: CGFloat = 1) {
        self.init(uiColor: .dynamic(light: light, dark: dark, lightAlpha: alpha, darkAlpha: alpha))
    }
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat, darkAlpha: CGFloat) {
        self.init(uiColor: .dynamic(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }
}

/// Settings → General → Appearance. Applied to the app's windows (not the
/// player's, which is always dark) so sheets, menus and alerts follow too.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Automatic" : self == .light ? "Light" : "Dark" }
    var style: UIUserInterfaceStyle { self == .system ? .unspecified : self == .light ? .light : .dark }

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? "") ?? .system
    }

    @MainActor static func apply() {
        let style = current.style
        for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
        where !(w is PlayerWindowMarker) && w.overrideUserInterfaceStyle != style {
            w.overrideUserInterfaceStyle = style
        }
    }
}

/// Applies the appearance as soon as the root view has a window (before the
/// first frame is shown) and whenever the setting changes.
struct AppearanceProbe: UIViewRepresentable {
    let mode: String
    final class Probe: UIView {
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { AppearanceMode.apply() } }
    }
    func makeUIView(context: Context) -> Probe { let p = Probe(); p.isUserInteractionEnabled = false; return p }
    func updateUIView(_ uiView: Probe, context: Context) { AppearanceMode.apply() }
}

// MARK: - Brand mark

/// The Folio leaf, on a 100 × 100 grid (the same curve as the app icon,
/// `docs/brand/leaf.svg`).
struct LeafShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 100 * r.width, y: r.minY + y / 100 * r.height) }
        var path = Path()
        path.move(to: p(27, 83))
        path.addCurve(to: p(20, 56), control1: p(22, 77), control2: p(20, 68))
        path.addCurve(to: p(25, 31), control1: p(20, 44), control2: p(21, 36))
        path.addCurve(to: p(44, 21.5), control1: p(29, 26), control2: p(36, 23))
        path.addCurve(to: p(70, 12.5), control1: p(54, 19.5), control2: p(63, 17))
        path.addCurve(to: p(55, 57), control1: p(70.5, 30), control2: p(66, 45))
        path.addCurve(to: p(27, 83), control1: p(45, 68), control2: p(34, 73))
        path.closeSubpath()
        return path
    }
}

/// The leaf's curled edge (tip to tip), drawn as a thin highlight.
struct LeafEdge: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 100 * r.width, y: r.minY + y / 100 * r.height) }
        var path = Path()
        path.move(to: p(70, 12.5))
        path.addCurve(to: p(55, 57), control1: p(70.5, 30), control2: p(66, 45))
        path.addCurve(to: p(27, 83), control1: p(45, 68), control2: p(34, 73))
        return path
    }
}

/// The leaf as drawn on the icon: ink on light, cream on dark.
struct FolioLeaf: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let stops: [Color] = scheme == .dark
            ? [Color(uiColor: UIColor(hex: 0xF2EDE6)), Color(uiColor: UIColor(hex: 0xD9D3CB)), Color(uiColor: UIColor(hex: 0xB5AEA5))]
            : [Color(uiColor: UIColor(hex: 0x121314)), Color(uiColor: UIColor(hex: 0x2E2F31)), Color(uiColor: UIColor(hex: 0x5A5A5B))]
        GeometryReader { g in
            ZStack {
                LeafShape().fill(LinearGradient(stops: [.init(color: stops[0], location: 0), .init(color: stops[1], location: 0.55), .init(color: stops[2], location: 1)],
                                                startPoint: UnitPoint(x: 0.15, y: 0.3), endPoint: UnitPoint(x: 0.75, y: 0.75)))
                LeafEdge().stroke(.white.opacity(scheme == .dark ? 0.6 : 0.5), style: StrokeStyle(lineWidth: max(0.5, g.size.width * 0.0045), lineCap: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// "FOLIO" in the brand's wide-tracked geometric sans.
struct Wordmark: View {
    var size: CGFloat = 22
    var tracking: CGFloat? = nil
    var body: some View {
        Text("FOLIO")
            .font(.custom(Theme.wordmarkFont, size: size))
            .tracking(tracking ?? size * 0.42)
            .accessibilityLabel("Folio")
    }
}

// MARK: - Zoom transitions (iOS 18+)

/// A poster that a page zooms out of: the id and the namespace both views share.
struct ZoomSource {
    let id: AnyHashable
    let ns: Namespace.ID
    init(_ id: some Hashable, _ ns: Namespace.ID) { self.id = AnyHashable(id); self.ns = ns }
}

extension View {
    /// Marks the view a page zooms out of (`zoomDestination` on the page).
    @ViewBuilder
    func zoomSource(_ z: ZoomSource?, cornerRadius: CGFloat = 12) -> some View {
        if #available(iOS 18.0, *), let z {
            matchedTransitionSource(id: z.id, in: z.ns) { $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
        } else {
            self
        }
    }

    /// The pushed page grows out of its source and shrinks back into it on
    /// Back (SwiftUI's zoom navigation transition).
    @ViewBuilder
    func zoomDestination(_ id: some Hashable, in ns: Namespace.ID) -> some View {
        // Same AnyHashable wrapping as ZoomSource, so the ids always match.
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: AnyHashable(id), in: ns)).ignoresTapsWhileLeaving() } else { self.ignoresTapsWhileLeaving() }
    }

    /// A pushed page stops taking taps the moment it starts going away.
    ///
    /// 1.14.1 report: after a swipe closed a title page, the zoom finished on
    /// screen but the pop committed ~1.3 s later; meanwhile the invisible page
    /// still took taps, so tapping the next title's row hit this page's Resume
    /// button (same spot) and played it. UIKit calls viewWillDisappear when the
    /// pop begins ("before any animations are configured"), and on a cancelled
    /// interactive pop calls viewWillAppear again (transition coordinator docs).
    func ignoresTapsWhileLeaving() -> some View { modifier(LeaveGuard()) }
}

private struct PageLeavingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True from the moment a pushed page starts going away (LeaveGuard).
    var pageLeaving: Bool {
        get { self[PageLeavingKey.self] }
        set { self[PageLeavingKey.self] = newValue }
    }
}

private struct LeaveGuard: ViewModifier {
    @State private var leaving = false
    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!leaving)
            .environment(\.pageLeaving, leaving)
            .background(LeavingProbe { leaving = $0 }.frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// A child view controller of the page's hosting controller: it receives the
/// page's appearance callbacks (automatic forwarding).
private struct LeavingProbe: UIViewControllerRepresentable {
    let onChange: (Bool) -> Void
    final class Probe: UIViewController {
        var onChange: ((Bool) -> Void)?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); onChange?(false) }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            dlog("nav", "page leaving: taps off")
            onChange?(true)
        }
    }
    func makeUIViewController(context: Context) -> Probe { let p = Probe(); p.onChange = onChange; return p }
    func updateUIViewController(_ vc: Probe, context: Context) { vc.onChange = onChange }
}

/// Frosted "glass" background. Uses Liquid Glass on iOS 26 when built with
/// the iOS 26 SDK, material blur otherwise.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 18
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

struct GlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // contentShape: the whole circle is the button. Without it a tap on
            // the interactive glass (not on the icon) went to the glass effect
            // and the button's action never ran — the title page's Back button
            // only worked when you hit the chevron itself.
            content.glassEffect(.regular.interactive(), in: .circle).contentShape(Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        #else
        content.background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
        #endif
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, interactive: interactive))
    }
    func glassCircle() -> some View { modifier(GlassCircle()) }
}

/// Simple async image with a placeholder.
struct PosterImage: View {
    let url: String?
    var aspect: CGFloat = 2.0 / 3.0
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let url, let u = URL(string: url) {
                    CachedImage(url: u, maxPixel: 700) { $0.resizable().scaledToFill() } placeholder: { placeholder }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Theme.card
            Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
        }
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Icon for a toolbar item. On iOS 26 an icon-only toolbar button reacts only
/// to taps on the glyph itself, though the system draws a full circle around
/// it (Apple Developer Forums thread 815492) — a thin glyph like "ellipsis"
/// was hit-or-miss. The whole 44 pt square is made tappable.
struct ToolbarGlyph: View {
    let systemName: String
    init(_ systemName: String) { self.systemName = systemName }
    var body: some View {
        Image(systemName: systemName)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
