import SwiftUI
import UIKit

/// The system segmented control (with `selectedSegmentTintColor`). On iOS 26 its thumb is Liquid Glass: it
/// lifts into a glass lens while touched or dragged and settles into the
/// tint colour — the same behaviour as the tab bar.
struct SegmentPicker<T: Hashable>: UIViewRepresentable {
    let options: [(T, String)]
    @Binding var selection: T

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UISegmentedControl {
        let c = UISegmentedControl(items: options.map(\.1))
        // Dynamic colours: ink thumb with cream text on light, the reverse on
        // dark (the player's window is always dark).
        c.selectedSegmentTintColor = Theme.uiAccent
        c.setTitleTextAttributes([.foregroundColor: UIColor.label.withAlphaComponent(0.85), .font: UIFont.systemFont(ofSize: 14, weight: .semibold)], for: .normal)
        c.setTitleTextAttributes([.foregroundColor: Theme.uiOnAccent, .font: UIFont.systemFont(ofSize: 14, weight: .semibold)], for: .selected)
        c.selectedSegmentIndex = options.firstIndex { $0.0 == selection } ?? 0
        c.addAction(UIAction { [weak c] _ in
            guard let c, c.selectedSegmentIndex >= 0, c.selectedSegmentIndex < context.coordinator.options.count else { return }
            context.coordinator.set?(c.selectedSegmentIndex)
        }, for: .valueChanged)
        c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return c
    }

    func updateUIView(_ c: UISegmentedControl, context: Context) {
        context.coordinator.options = options.map(\.1)
        context.coordinator.set = { i in
            let v = options[i].0
            if v != selection { selection = v }
        }
        let i = options.firstIndex { $0.0 == selection } ?? 0
        if c.selectedSegmentIndex != i { c.selectedSegmentIndex = i }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        let ideal = uiView.intrinsicContentSize
        let w = proposal.width.map { $0.isFinite ? $0 : ideal.width } ?? ideal.width
        return CGSize(width: max(80, w), height: max(32, ideal.height))
    }

    final class Coordinator {
        var options: [String] = []
        var set: ((Int) -> Void)?
    }
}
