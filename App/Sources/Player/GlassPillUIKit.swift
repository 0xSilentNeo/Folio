import SwiftUI
import UIKit

/// The right-hand pill (Tracks · Settings · Now Playing) as real UIKit:
/// a Liquid Glass UIVisualEffectView capsule with three UIButtons. The
/// popovers are presented from these buttons — iOS 26 morphs a popover out
/// of a glass source element, which it does not do for an invisible anchor.
/// (Outplayer's VideoMenuButton is the same construction.)
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
struct PanelToolbarView: UIViewRepresentable {
    @ObservedObject var ui: PlayerUIState

    func makeUIView(context: Context) -> UIToolbar {
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
        var barItems: [UIBarButtonItem] = [.flexibleSpace()]
        for (kind, symbol, title) in items {
            let item = UIBarButtonItem(primaryAction: UIAction(title: title, image: UIImage(systemName: symbol)) { [weak ui] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                ui?.toggle(kind)
            })
            item.accessibilityLabel = title
            ui.barItems[kind] = item
            barItems.append(item)
        }
        bar.items = barItems
        ui.panelBar = bar
        return bar
    }

    func updateUIView(_ bar: UIToolbar, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIToolbar, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: 50)
    }
}
