import SwiftUI

/// Live-adjustable player UI values (Settings panel → Developer → Tune UI).
/// Everything persists; `reset()` restores the defaults.
@MainActor
final class UITune: ObservableObject {
    static let shared = UITune()

    struct Def { static let panelWidth = 0.42, panelMax = 340.0, textScale = 1.0, pillHeight = 46.0
                 static let response = 0.55, damping = 0.74, startScale = 0.1, blur = true }

    @Published var panelWidth: Double { didSet { save("panelWidth", panelWidth) } }   // fraction of screen width (landscape)
    @Published var panelMax: Double { didSet { save("panelMax", panelMax) } }         // pt cap
    @Published var textScale: Double { didSet { save("textScale", textScale) } }
    @Published var pillHeight: Double { didSet { save("pillHeight", pillHeight) } }
    @Published var response: Double { didSet { save("response", response) } }
    @Published var damping: Double { didSet { save("damping", damping) } }
    @Published var startScale: Double { didSet { save("startScale", startScale) } }
    @Published var blur: Bool { didSet { UserDefaults.standard.set(blur, forKey: "tune.blur") } }

    private init() {
        func d(_ k: String, _ v: Double) -> Double { UserDefaults.standard.object(forKey: "tune." + k) as? Double ?? v }
        panelWidth = d("panelWidth", Def.panelWidth)
        panelMax = d("panelMax", Def.panelMax)
        textScale = d("textScale", Def.textScale)
        pillHeight = d("pillHeight", Def.pillHeight)
        response = d("response", Def.response)
        damping = d("damping", Def.damping)
        startScale = d("startScale", Def.startScale)
        blur = UserDefaults.standard.object(forKey: "tune.blur") as? Bool ?? Def.blur
    }

    private func save(_ k: String, _ v: Double) { UserDefaults.standard.set(v, forKey: "tune." + k) }

    func reset() {
        panelWidth = Def.panelWidth; panelMax = Def.panelMax; textScale = Def.textScale; pillHeight = Def.pillHeight
        response = Def.response; damping = Def.damping; startScale = Def.startScale; blur = Def.blur
    }

    var openSpring: Animation { .spring(response: response, dampingFraction: damping) }
    var closeSpring: Animation { .spring(response: max(0.2, response * 0.7), dampingFraction: 0.9) }

    var typeSize: DynamicTypeSize {
        switch textScale {
        case ..<0.85: return .xSmall
        case ..<0.95: return .small
        case ..<1.05: return .large
        case ..<1.15: return .xLarge
        default: return .xxLarge
        }
    }

    var summary: String {
        String(format: "w %.0f%% / %.0fpt · text %.2f · pill %.0f · spring %.2f/%.2f · from %.2f · blur %@",
               panelWidth * 100, panelMax, textScale, pillHeight, response, damping, startScale, blur ? "on" : "off")
    }
}

/// The tuning card shown over the player.
struct TuneCard: View {
    @ObservedObject var tune = UITune.shared
    @ObservedObject var ui: PlayerUIState

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Tune UI").font(.headline)
                        Spacer()
                        Button("Reset") { tune.reset() }.font(.caption.weight(.semibold))
                        CloseDot { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ui.showTune = false } }
                    }
                    Group {
                        row("Panel width", value: $tune.panelWidth, in: 0.28...0.65, fmt: "%.0f%%", scale: 100)
                        row("Panel max", value: $tune.panelMax, in: 260...520, fmt: "%.0f pt")
                        row("Text size", value: $tune.textScale, in: 0.8...1.2, fmt: "%.2f×")
                        row("Pill height", value: $tune.pillHeight, in: 38...58, fmt: "%.0f pt")
                        row("Spring response", value: $tune.response, in: 0.2...1.2, fmt: "%.2f s")
                        row("Spring damping", value: $tune.damping, in: 0.4...1.0, fmt: "%.2f")
                    }
                    HStack {
                        Button {
                            ui.toggle(.nowPlaying)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { ui.closePanel() }
                        } label: {
                            Label("Replay panel animation", systemImage: "play.circle").font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity).frame(height: 32).background(.white.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(PressStyle(scale: 0.96))
                    }
                    Text(tune.summary).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).textSelection(.enabled)
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: 380)
                .glass(cornerRadius: 24)
                .padding(.leading, 20).padding(.top, 60)
                Spacer()
            }
            Spacer()
        }
    }

    private func row(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, fmt: String, scale: Double = 1) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range).tint(Theme.accent)
            Text(String(format: fmt, value.wrappedValue * scale)).font(.caption.monospacedDigit()).frame(width: 58, alignment: .trailing)
        }
    }
}
