import SwiftUI

#if compiler(>=6.2)
/// iOS 26: the panel pill and its panels, morphing with SwiftUI's Liquid Glass.
///
/// Apple, "Applying Liquid Glass to custom views": views with `glassEffect`
/// inside one `GlassEffectContainer` "morph in and out of each other during
/// transitions", coordinated by `glassEffectID(_:in:)` — "SwiftUI uses the
/// identifier to animate shapes to and from each other during transitions."
///
/// The pill and the open panel share one glass identity: opening replaces the
/// pill with the panel (as the iOS popover did: it "animates from and
/// replaces" its item), and the pill's glass morphs into the panel's; closing
/// morphs it back. Unlike the popover's transition (which UIKit can't
/// interrupt: taps waited ~1–1.25 s on an iPhone 17 Pro), a SwiftUI animation
/// can be interrupted at any time, so the pill is tappable the moment a close
/// begins. Nothing is frozen: the video keeps playing under the glass.
@available(iOS 26.0, *)
struct GlassPanelPill: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState
    let ns: Namespace.ID
    let width: CGFloat
    let maxHeight: CGFloat
    let onLoadSubtitle: () -> Void
    let onRotationLock: (Bool) -> Void
    @ObservedObject private var tune = UITune.shared

    /// The panel on screen (changes inside `withAnimation`, so the glass morphs).
    @State private var displayed: PlayerUIState.Panel?
    /// Each panel's content height, measured before it first opens.
    @State private var natural: [PlayerUIState.Panel: CGFloat] = [:]
    @State private var measuring: PlayerUIState.Panel?

    /// The glass identity the pill and the panel share.
    private let glassID = "panels"
    /// SwiftUI's default animation (as in Apple's morph example).
    private let morph = Animation.default

    struct Item: Identifiable { let id: PlayerUIState.Panel; let icon: String; let title: String }
    static let items: [Item] = [
        Item(id: .tracks, icon: "switch.2", title: "Tracks"),
        Item(id: .settings, icon: "slider.horizontal.3", title: "Settings"),
        Item(id: .nowPlaying, icon: "list.bullet", title: "Now Playing"),
    ]

    private var pillSize: CGSize { CGSize(width: tune.pillHeight * 3 + 8, height: tune.pillHeight) }

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            ZStack {
                if displayed == nil {
                    pill
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID(glassID, in: ns)
                } else {
                    Color.clear       // keeps the pill's place in the row while a panel is open
                }
            }
            .frame(width: pillSize.width, height: pillSize.height)
            .overlay(alignment: .bottomTrailing) {
                if let k = displayed {
                    PlayerPanel(kind: k, model: model, ui: ui, width: width, maxHeight: maxHeight,
                                onLoadSubtitle: onLoadSubtitle, onRotationLock: onRotationLock, bare: true,
                                onNaturalHeight: { natural[k] = $0 })
                        .frame(width: width, height: height(k))
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                        .glassEffectID(glassID, in: ns)
                        .padding(.bottom, pillSize.height + 8)       // just above where the pill is
                }
            }
        }
        .background {
            // A panel's height, measured off screen the first time it opens.
            if let m = measuring {
                PlayerPanel(kind: m, model: model, ui: ui, width: width, maxHeight: maxHeight,
                            onLoadSubtitle: {}, onRotationLock: { _ in }, bare: true,
                            onNaturalHeight: { h in measured(m, h) })
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: ui.panel) { _, new in show(new) }
        .onAppear { if let p = ui.panel { show(p) } }
    }

    private var pill: some View {
        HStack(spacing: 0) {
            ForEach(Self.items) { item in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    ui.toggle(item.id)
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: tune.pillHeight, height: tune.pillHeight)
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle(scale: 0.82))
                .accessibilityLabel(item.title)
            }
        }
        .padding(.horizontal, 4)
        .foregroundStyle(.white)
    }

    private func height(_ k: PlayerUIState.Panel) -> CGFloat {
        k == .nowPlaying ? maxHeight : min(natural[k] ?? maxHeight, maxHeight)
    }

    private func show(_ k: PlayerUIState.Panel?) {
        guard let k else {
            measuring = nil
            withAnimation(morph) { displayed = nil }
            return
        }
        if k == .nowPlaying || natural[k] != nil {
            withAnimation(morph) { displayed = k }
        } else {
            measuring = k          // opens as soon as its height is known (next layout)
        }
    }

    private func measured(_ k: PlayerUIState.Panel, _ h: CGFloat) {
        natural[k] = h
        guard measuring == k else { return }
        measuring = nil
        if ui.panel == k { withAnimation(morph) { displayed = k } }
    }
}
#endif
