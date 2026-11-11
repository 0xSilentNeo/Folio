import SwiftUI

/// Player UI sizes, read from the saved values (the tuning card that
/// changed them is gone; the defaults apply unless one was saved).
@MainActor
final class UITune: ObservableObject {
    static let shared = UITune()

    struct Def { static let panelWidth = 0.42, panelMax = 340.0, textScale = 1.0, pillHeight = 46.0 }

    @Published var panelWidth: Double { didSet { save("panelWidth", panelWidth) } }   // fraction of screen width (landscape)
    @Published var panelMax: Double { didSet { save("panelMax", panelMax) } }         // pt cap
    @Published var textScale: Double { didSet { save("textScale", textScale) } }
    @Published var pillHeight: Double { didSet { save("pillHeight", pillHeight) } }

    private init() {
        func d(_ k: String, _ v: Double) -> Double { UserDefaults.standard.object(forKey: "tune." + k) as? Double ?? v }
        panelWidth = d("panelWidth", Def.panelWidth)
        panelMax = d("panelMax", Def.panelMax)
        textScale = d("textScale", Def.textScale)
        pillHeight = d("pillHeight", Def.pillHeight)
    }

    private func save(_ k: String, _ v: Double) { UserDefaults.standard.set(v, forKey: "tune." + k) }

    var typeSize: DynamicTypeSize {
        switch textScale {
        case ..<0.85: return .xSmall
        case ..<0.95: return .small
        case ..<1.05: return .large
        case ..<1.15: return .xLarge
        default: return .xxLarge
        }
    }
}
