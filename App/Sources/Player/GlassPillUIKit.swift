import SwiftUI
import UIKit

/// The right-hand pill (Tracks · Settings · Now Playing) as real UIKit:
/// a Liquid Glass UIVisualEffectView capsule with three UIButtons. The
/// popovers are presented from these buttons — iOS 26 morphs a popover out
/// of a glass source element, which it does not do for an invisible anchor.
struct PanelPillView: UIViewRepresentable {
    @ObservedObject var ui: PlayerUIState
    var height: CGFloat

    func makeUIView(context: Context) -> PanelPillUIView {
        let v = PanelPillUIView(height: height)
        v.onTap = { kind in ui.toggle(kind) }
        for (kind, button) in v.buttons { ui.anchors[kind] = button }
        return v
    }

    func updateUIView(_ v: PanelPillUIView, context: Context) {
        v.setActive(ui.panel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PanelPillUIView, context: Context) -> CGSize? {
        CGSize(width: height * 3 + 8, height: height)
    }
}

final class PanelPillUIView: UIView {
    var onTap: ((PlayerUIState.Panel) -> Void)?
    private(set) var buttons: [PlayerUIState.Panel: UIButton] = [:]
    private let effect: UIVisualEffectView
    private let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect()
            g.isInteractive = true
            effect = UIVisualEffectView(effect: g)
        } else {
            effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        #else
        effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        #endif
        super.init(frame: .zero)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor), effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor), effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            effect.cornerConfiguration = .capsule()
        } else {
            effect.layer.cornerRadius = height / 2; effect.clipsToBounds = true
        }
        #else
        effect.layer.cornerRadius = height / 2; effect.clipsToBounds = true
        #endif

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: effect.contentView.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: effect.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.contentView.bottomAnchor),
        ])
        let items: [(PlayerUIState.Panel, String)] = [(.tracks, "switch.2"), (.settings, "slider.horizontal.3"), (.nowPlaying, "list.bullet")]
        for (kind, symbol) in items {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.layer.cornerRadius = height / 2
            b.widthAnchor.constraint(equalToConstant: height).isActive = true
            b.addAction(UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.onTap?(kind)
            }, for: .touchUpInside)
            b.addAction(UIAction { [weak b] _ in UIView.animate(withDuration: 0.12) { b?.transform = CGAffineTransform(scaleX: 0.84, y: 0.84) } }, for: .touchDown)
            b.addAction(UIAction { [weak b] _ in UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0) { b?.transform = .identity } },
                        for: [.touchUpInside, .touchUpOutside, .touchCancel])
            stack.addArrangedSubview(b)
            buttons[kind] = b
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: PlayerUIState.Panel?) {
        for (kind, b) in buttons {
            b.backgroundColor = kind == active ? UIColor.white.withAlphaComponent(0.2) : .clear
        }
    }
}

/// iOS 26: the three panel buttons as bar button items in a UIToolbar. The
/// system draws them as one Liquid Glass capsule, and a popover presented
/// from one of them morphs out of that glass (verified in the pop lab, V7).
///
/// 1.16.0: each item wraps a plain UIButton (UIBarButtonItem(customView:)),
/// 44 pt square, 38 pt on iOS 27. The other buttons stay on screen while one
/// of them has its menu open.
struct PanelToolbarView: UIViewRepresentable {
    @ObservedObject var ui: PlayerUIState
    /// Called when the toolbar moved a button into its "⋯" overflow: it needs
    /// to be wider. 27 Oct recording: upright on the phone, two of the three
    /// buttons went into a "⋯" whose menu did nothing (custom-view items have
    /// no menu form), though the simulator fits all three at 186 pt.
    var onOverflow: () -> Void = {}
    /// Where the glass capsule is once laid out, in the toolbar's own
    /// coordinates (1.22.2): its left and right edges, which can lie past
    /// the toolbar's. The player row places the toolbar so the capsule
    /// itself sits in its slot, never over the time bar.
    var onCapsule: (CGFloat, CGFloat) -> Void = { _, _ in }

    /// A toolbar that says when its buttons don't all fit and where its
    /// capsule is, and takes touches only on its buttons.
    final class FitToolbar: UIToolbar {
        var onOverflow: (() -> Void)?
        var onCapsule: ((CGFloat, CGFloat) -> Void)?
        private var checkPending = false
        private var reported: (CGFloat, CGFloat)?
        private var settle: DispatchWorkItem?

        /// A menu is up or on its way: iOS lifts its button out of the
        /// toolbar into the menu's glass, which isn't "doesn't fit", and the
        /// capsule round the others isn't the capsule at rest (5 Nov phone
        /// log: "now 202 pt wide" and "capsule at 68…114" as a menu opened).
        private var menuUp: Bool { window?.rootViewController?.presentedViewController != nil }

        private var buttons: [UIView] { (items ?? []).compactMap(\.customView) }

        /// No safe area: the player row already keeps its controls where they
        /// go. With the controls wider than 80%, the toolbar's right end lies
        /// in the landscape safe area (62 pt on a 17 Pro Max), and UIKit moved
        /// the glass that much to the left, over the time bar (1.22.1 at 90%:
        /// 4 Nov screenshot; simulator log: capsule 3…173 → −20…152).
        override var safeAreaInsets: UIEdgeInsets { .zero }

        /// Its own views too: the glass inside reads the screen's safe area
        /// by itself (simulator: still 7–10 pt to the left with only the
        /// toolbar's turned off).
        private func dropSafeArea(_ v: UIView) {
            v.insetsLayoutMarginsFromSafeArea = false
            v.layoutMargins = .zero
            v.directionalLayoutMargins = .zero
            for sub in v.subviews { dropSafeArea(sub) }
        }

        /// The capsule's edges: the glass view UIKit draws behind the buttons
        /// (iOS 26.5: UIPlatformGlassInteractionView), else the smallest view
        /// that holds them all, else the buttons and 16 pt around them.
        private func capsuleSpan() -> (CGFloat, CGFloat)? {
            let shown = buttons.filter { $0.window != nil && !$0.isHidden }
            guard !shown.isEmpty else { return nil }
            let area = shown.map { $0.convert($0.bounds, to: self) }.reduce(CGRect.null) { $0.union($1) }
            var glass: CGRect?
            var smallest: CGRect?
            func visit(_ v: UIView) {
                for sub in v.subviews where !sub.isHidden && sub.alpha > 0 && !shown.contains(sub) {
                    let f = sub.convert(sub.bounds, to: self)
                    if f.insetBy(dx: -1, dy: -1).contains(area) {
                        if String(describing: type(of: sub)).contains("Glass"), glass.map({ f.width < $0.width }) ?? true { glass = f }
                        if f.width < bounds.width - 1, smallest.map({ f.width < $0.width }) ?? true { smallest = f }
                    }
                    visit(sub)
                }
            }
            visit(self)
            if let f = glass ?? smallest { return (f.minX, f.maxX) }
            return (area.minX - 16, area.maxX + 16)
        }

        /// Once per launch: the toolbar's views and where they are, so a
        /// report shows where UIKit put the glass on that iOS (1.22.2).
        private static var described = false
        private func describeViews() {
            guard !Self.described, window != nil, bounds.width > 0, buttons.contains(where: { $0.window != nil }) else { return }
            Self.described = true
            var lines: [String] = []
            func visit(_ v: UIView, _ depth: Int) {
                guard depth <= 5, lines.count < 40 else { return }
                let f = v.convert(v.bounds, to: self)
                lines.append(String(repeating: "  ", count: depth) + "\(type(of: v)) x \(Int(f.minX))…\(Int(f.maxX)) w \(Int(f.width))" + (v.isHidden ? " hidden" : ""))
                for sub in v.subviews { visit(sub, depth + 1) }
            }
            for sub in subviews { visit(sub, 0) }
            dlog("ui", "player toolbar \(Int(bounds.width)) pt, its views:\n" + lines.joined(separator: "\n"))
        }

        override func layoutSubviews() {
            dropSafeArea(self)
            super.layoutSubviews()
            describeViews()
            // Where the capsule settles, not every step on the way: on iOS 27
            // the glass swells while a button is held and shrinks back, and
            // each step resized the time bar beside it (5 Nov: up to 13
            // sizes in one press; "the progress bar shrinks and expands").
            // Reported 0.35 s after the last change, with no menu up.
            if window != nil, capsuleSpan() != nil {
                settle?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.window != nil, !self.menuUp, let (a, b) = self.capsuleSpan() else { return }
                    let span = (a.rounded(), b.rounded())
                    guard self.reported.map({ $0 != span }) ?? true else { return }
                    self.reported = span
                    self.onCapsule?(span.0, span.1)
                }
                settle = work
                // The first one at once: the row needs it to place the toolbar.
                DispatchQueue.main.asyncAfter(deadline: .now() + (reported == nil ? 0 : 0.35), execute: work)
            }
            guard window != nil, bounds.width > 0, !checkPending, !menuUp, buttons.contains(where: { $0.window == nil }) else { return }
            // Only an overflow that lasts: while the player rotates, the
            // toolbar is briefly laid out at an in-between size (lab: an
            // overflow at launch in landscape that was gone 0.5 s later).
            checkPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.checkPending = false
                if self.window != nil, !self.menuUp, self.buttons.contains(where: { $0.window == nil }) { self.onOverflow?() }
            }
        }

        /// The toolbar is wider than its glass capsule (the empty part reaches
        /// over the time bar); only the buttons and a little around them take
        /// touches, the rest passes through to what's underneath.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let shown = buttons.filter { $0.window != nil && !$0.isHidden }
            guard !shown.isEmpty else { return super.point(inside: point, with: event) }
            let area = shown.map { $0.convert($0.bounds, to: self) }.reduce(CGRect.null) { $0.union($1) }
            return area.insetBy(dx: -8, dy: -6).contains(point)
        }
    }

    static var buttonSize: CGFloat {
        if #available(iOS 27, *) { return 38 }
        return 44
    }

    /// Width the toolbar needs for its three buttons. Built with the iOS 27 SDK, a toolbar
    /// moves items that do not fit into a "⋯" overflow menu. CI toolbar probe (iOS 27.0
    /// simulator, the player in landscape): 182 pt → one button and "⋯", 186 pt → all
    /// three. The glass capsule is 154 pt wide and sits 16 pt in from the toolbar's right
    /// edge; everything to its left is empty toolbar.
    static var width: CGFloat {
        if CommandLine.arguments.contains("-toolbarNarrow") { return 150 }   // lab: start too narrow, must widen itself
        if #available(iOS 27, *) { return 190 }
        return 176
    }

    /// The empty toolbar beside the glass, laid out beyond the toolbar's frame so the
    /// progress bar gets that space (1.16.1: at 236 pt the toolbar took ~80 pt from it,
    /// for a capsule 154 pt wide).
    static var outside: (leading: CGFloat, trailing: CGFloat) {
        if #available(iOS 27, *) { return (190 - 16 - 154, 16) }
        return (0, 0)
    }

    func makeUIView(context: Context) -> UIToolbar {
        let (bar, items) = Self.makeBar { [weak ui] kind in ui?.toggle(kind) }
        for (kind, item) in items { ui.barItems[kind] = item }
        ui.panelBar = bar
        (bar as? FitToolbar)?.onOverflow = onOverflow
        (bar as? FitToolbar)?.onCapsule = onCapsule
        return bar
    }

    /// The toolbar and its three items (also built by the toolbar probe, UILab).
    static func makeBar(onTap: @escaping (PlayerUIState.Panel) -> Void) -> (UIToolbar, [PlayerUIState.Panel: UIBarButtonItem]) {
        let bar = FitToolbar()
        bar.tintColor = .white
        bar.overrideUserInterfaceStyle = .dark
        let appearance = UIToolbarAppearance()
        appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        let items: [(PlayerUIState.Panel, String, String)] = [
            (.tracks, "switch.2", "Tracks"), (.settings, "slider.horizontal.3", "Settings"), (.nowPlaying, "list.bullet", "Now Playing"),
        ]
        let size = buttonSize
        var barItems: [UIBarButtonItem] = [.flexibleSpace()]
        var byKind: [PlayerUIState.Panel: UIBarButtonItem] = [:]
        for (kind, symbol, title) in items {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = title
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: size),
                button.heightAnchor.constraint(equalToConstant: size),
            ])
            button.addAction(UIAction { _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onTap(kind)
            }, for: .touchUpInside)
            let item = UIBarButtonItem(customView: button)
            item.accessibilityLabel = title
            byKind[kind] = item
            barItems.append(item)
        }
        bar.items = barItems
        return (bar, byKind)
    }

    func updateUIView(_ bar: UIToolbar, context: Context) {
        (bar as? FitToolbar)?.onOverflow = onOverflow
        (bar as? FitToolbar)?.onCapsule = onCapsule
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIToolbar, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: 50)
    }
}
