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
        return bar
    }

    /// The toolbar and its three items (also built by the toolbar probe, UILab).
    static func makeBar(onTap: @escaping (PlayerUIState.Panel) -> Void) -> (UIToolbar, [PlayerUIState.Panel: UIBarButtonItem]) {
        let bar = UIToolbar()
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

    func updateUIView(_ bar: UIToolbar, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIToolbar, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: 50)
    }
}
