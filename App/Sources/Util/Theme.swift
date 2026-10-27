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
    func zoomDestination(_ id: some Hashable, in ns: Namespace.ID, zoom: Bool = true) -> some View {
        // Same AnyHashable wrapping as ZoomSource, so the ids always match.
        // zoom: false — pushed the usual way, from a page that shows the system
        // bar (a zoom between pages that show and hide the bar is what iOS
        // gets wrong, see pageButtons).
        if #available(iOS 18.0, *), zoom {
            navigationTransition(.zoom(sourceID: AnyHashable(id), in: ns)).ignoresTapsWhileLeaving().environment(\.zoomsFromTile, true)
        } else {
            self.ignoresTapsWhileLeaving().environment(\.zoomsFromTile, false)
        }
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
private struct ZoomsFromTileKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The page zooms out of a tile and back into it (zoomDestination, iOS 18+).
    var zoomsFromTile: Bool {
        get { self[ZoomsFromTileKey.self] }
        set { self[ZoomsFromTileKey.self] = newValue }
    }
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
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            setPageTouchable(true)
            onChange?(false)
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            setPageTouchable(false)
            PopTouchLab.start(for: self)
            dlog("nav", "page leaving: taps off")
            onChange?(true)
            // Pages that keep the system bar (Settings, folders, addon titles):
            // react-native-screens #5054 (iOS 27.0, traced in UIKit) — when the
            // screen below hides the bar, UIKit fades it out (alpha 0) alongside
            // a zoom back; if the swipe is let go, it shows the bar again but
            // leaves alpha at 0, so the page's title and Back button are gone.
            guard let nav = navigationController, let tc = transitionCoordinator else { return }
            tc.animate(alongsideTransition: nil) { [weak nav] ctx in
                guard ctx.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let nav, !nav.isNavigationBarHidden, nav.navigationBar.alpha < 0.99 else { return }
                    dlog("nav", "swipe back let go: the navigation bar was left at alpha \(String(format: "%.2f", nav.navigationBar.alpha)); shown again")
                    nav.navigationBar.alpha = 1
                }
            }
        }
    }
    func makeUIViewController(context: Context) -> Probe { let p = Probe(); p.onChange = onChange; return p }
    func updateUIViewController(_ vc: Probe, context: Context) { vc.onChange = onChange }
}

/// Lab (`-popTouchLab`): from the moment a page starts going back, where a
/// touch at the middle of the page's screen area would go, each frame for
/// 1.5 s — the page, or what's underneath (Home).
@MainActor
private final class PopTouchLab: NSObject {
    static var current: PopTouchLab?
    static let on = CommandLine.arguments.contains("-popTouchLab")
    private var link: CADisplayLink?
    private weak var page: UIView?
    private weak var window: UIWindow?
    private var point = CGPoint.zero
    private var t0 = CACurrentMediaTime()
    private var last = ""

    static func start(for probe: UIViewController) {
        guard on else { return }
        var vc: UIViewController = probe
        while let p = vc.parent, !(p is UINavigationController) { vc = p }
        guard let page = vc.view, let w = page.window else { return }
        let lab = PopTouchLab()
        lab.page = page; lab.window = w
        lab.point = CGPoint(x: w.bounds.midX, y: w.bounds.height * 0.62)
        let l = CADisplayLink(target: lab, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        lab.link = l
        current = lab
        dlog("navprobe", "page leaving: where a touch at (\(Int(lab.point.x)), \(Int(lab.point.y))) goes")
    }

    @objc private func tick() {
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        guard ms < 1500, let w = window else { link?.invalidate(); link = nil; Self.current = nil; return }
        let hit = w.hitTest(point, with: nil)
        let now: String
        if let hit, let page, hit.isDescendant(of: page) { now = "the leaving page" }
        else { now = hit.map { String(describing: type(of: $0)) } ?? "nothing" }
        if now != last { last = now; dlog("navprobe", "\(ms) ms after leaving began: touch → \(now)") }
    }
}

extension LeavingProbe.Probe {
    /// The page's own view (the navigation controller's child that holds
    /// this probe) stops or starts taking touches, at once.
    ///
    /// A page that zooms back into its tile stays on screen, over Home, for
    /// the whole zoom, and SwiftUI's zoom transition is interruptible: the
    /// page keeps taking touches meanwhile. So a tap meant for Home landed on
    /// the page's episode row and played it (27 Oct log, 19:12:55: "page
    /// leaving: taps off", then 114 ms later "episode row → play"). The
    /// SwiftUI side of this guard (`allowsHitTesting`, through @State) only
    /// applies at SwiftUI's next update; UIKit's flag applies to the very next
    /// touch. UIView docs: with isUserInteractionEnabled false, touches
    /// "intended for the view are ignored", and hitTest(_:with:) "ignores
    /// view objects that … have disabled user interactions" — so the tap goes
    /// to the view underneath: Home, which then opens what you tapped.
    func setPageTouchable(_ on: Bool) {
        var vc: UIViewController = self
        while let p = vc.parent, !(p is UINavigationController) { vc = p }
        guard vc !== self, vc.parent is UINavigationController else { return }
        if vc.view.isUserInteractionEnabled != on { vc.view.isUserInteractionEnabled = on }
    }
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

extension View {
    /// The ‹ and ⋯ of a page that zooms out of a tile (title pages).
    ///
    /// iOS 18+: drawn by the page itself, with the navigation bar hidden as it
    /// is on Home. Until 1.17.1 they were the system navigation bar's, so each
    /// zoom to or from a title page also showed or hid the bar, alongside the
    /// zoom — and iOS gets that wrong when the zoom follows a swipe:
    /// - Apple Developer Forums thread 774524, "Toolbar Display Bug When Using
    ///   Zoom NavigationTransition with Swipe-Back Gesture" (an Apple engineer:
    ///   "That's sounds like a bug"): after a swipe back the page's toolbar can
    ///   stay on the screen below. 26 Oct device recording: ‹ and ••• over Home.
    /// - react-native-screens #5054 (iOS 27.0, traced in UIKit): when the
    ///   screen below hides the bar, a swipe back that is let go leaves the
    ///   bar at alpha 0, so ‹ and ••• vanish. 27 Oct simulator run: the same.
    /// With the bar hidden on both screens nothing changes alongside the zoom,
    /// and the buttons are part of the page, so they come and go with it.
    /// The swipe back is the zoom transition's own, so hiding the bar doesn't
    /// turn it off. A page pushed without the zoom (a file opened from a
    /// folder) keeps the system bar: hiding it turns UIKit's own back swipe
    /// off (1.11.0).
    @ViewBuilder
    func pageButtons<Trailing: View>(zooms: Bool, back: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) -> some View {
        pageChrome(zooms: zooms, title: nil, back: back, trailing: trailing)
    }

    /// Every page that zooms out of something (1.17.2: Settings, folders,
    /// addon titles and their streams too) draws its own bar — see
    /// pageButtons. Its title, when it has one, sits in the middle, over a
    /// fade from the page colour so a list scrolling under it stays readable.
    /// 27 Oct screenshot: Settings' title and ‹ stayed on Home after Settings
    /// had zoomed back into its button — the same iOS bug as on title pages.
    /// A page pushed without the zoom keeps the system bar (and its title).
    @ViewBuilder
    func pageChrome<Trailing: View>(zooms: Bool, title: String?, back: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) -> some View {
        if #available(iOS 18.0, *), zooms {
            let t = trailing()
            toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Where the system bar put them (measured on iOS 27): 44 pt
                    // high at the top of the safe area, 16 pt from the sides, in
                    // a bar 54 pt high (so the page's layout doesn't move).
                    ZStack {
                        if let title {
                            Text(title).font(.headline).lineLimit(1)
                                .padding(.horizontal, 72)
                                .accessibilityAddTraits(.isHeader)
                        }
                        HStack(spacing: 0) {
                            Button(action: back) { PageButtonLabel(systemName: "chevron.left", width: 44) }
                                .buttonStyle(PressStyle(scale: 0.94))
                                .accessibilityLabel("Back")
                            Spacer(minLength: 0)
                            t
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .padding(.bottom, 10)
                    .background(alignment: .top) {
                        if title != nil {
                            LinearGradient(stops: [.init(color: Theme.background, location: 0), .init(color: Theme.background, location: 0.7),
                                                   .init(color: Theme.background.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                                .ignoresSafeArea(edges: .top)
                                .allowsHitTesting(false)
                        }
                    }
                }
        } else if let title {
            navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { trailing() } }
        } else {
            navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { trailing() } }
        }
    }
}

/// A page button's face: a glass circle (Back) or capsule (⋯), the whole of
/// it tappable. Inside the system toolbar just the glyph.
struct PageButtonLabel: View {
    let systemName: String
    var width: CGFloat = 44
    @Environment(\.zoomsFromTile) private var inPage
    var body: some View {
        if #available(iOS 18.0, *), inPage {
            // The system bar's glyph size (large symbol scale; measured on iOS 27).
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .imageScale(.large)
                .frame(width: width, height: 44)
                .glass(cornerRadius: 22, interactive: true)
                .contentShape(Capsule())
        } else {
            ToolbarGlyph(systemName)
        }
    }
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
