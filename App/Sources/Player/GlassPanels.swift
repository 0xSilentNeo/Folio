import SwiftUI

#if compiler(>=6.2)
/// iOS 26: the panel pill and its panels as ONE Liquid Glass shape that grows.
///
/// Closed, the glass is the pill (a capsule holding the three buttons). Opening
/// grows that same glass — its size, its place and its corner radius — from
/// the pill into the panel above it, revealing the panel's content inside it;
/// closing shrinks it back into the pill. This keeps the look of the iOS popover
/// morph (the panel grows out of its button) without its two problems:
/// - UIKit can't interrupt a popover transition, so taps waited ~1–1.25 s
///   (device log). A SwiftUI animation retargets at any moment: a tap during a
///   close reopens at once, a tap outside during an open closes at once.
/// - The video was frozen under the popover's glass (the stutter). Nothing is
///   frozen here.
///
/// Why not `glassEffectID` alone: in the simulator recording (glass lab), Apple's
/// documented morph stretches a small shape out of its neighbour, but a panel
/// this size only materialized (faded in at full size) in every set-up tried.
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

    /// The panel whose content is in the glass (stays through the close).
    @State private var displayed: PlayerUIState.Panel?
    /// The glass is the panel (true) or the pill (false). Animated.
    @State private var open = false
    @State private var contentOpacity = 0.0
    /// Each panel's content height, measured before it first opens.
    @State private var natural: [PlayerUIState.Panel: CGFloat] = [:]
    @State private var measuring: PlayerUIState.Panel?
    @State private var generation = 0

    /// SwiftUI's default animation.
    private let morph = Animation.default
    private let panelRadius: CGFloat = 28
    private let gap: CGFloat = 8

    struct Item: Identifiable { let id: PlayerUIState.Panel; let icon: String; let title: String }
    static let items: [Item] = [
        Item(id: .tracks, icon: "switch.2", title: "Tracks"),
        Item(id: .settings, icon: "slider.horizontal.3", title: "Settings"),
        Item(id: .nowPlaying, icon: "list.bullet", title: "Now Playing"),
    ]

    private var pillSize: CGSize { CGSize(width: tune.pillHeight * 3 + 8, height: tune.pillHeight) }

    private func height(_ k: PlayerUIState.Panel) -> CGFloat {
        k == .nowPlaying ? maxHeight : min(natural[k] ?? maxHeight, maxHeight)
    }

    var body: some View {
        // The row keeps the pill's size; the glass grows out of it (overlay).
        Color.clear
            .frame(width: pillSize.width, height: pillSize.height)
            .overlay(alignment: .bottomTrailing) { glass }
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

    private var glass: some View {
        let k = displayed
        let size = open && k != nil ? CGSize(width: width, height: height(k!)) : pillSize
        let radius = open ? panelRadius : pillSize.height / 2
        return ZStack(alignment: .bottomTrailing) {
            if let k {
                PlayerPanel(kind: k, model: model, ui: ui, width: width, maxHeight: maxHeight,
                            onLoadSubtitle: onLoadSubtitle, onRotationLock: onRotationLock, bare: true,
                            onNaturalHeight: { natural[k] = $0 })
                    .frame(width: width, height: height(k))
                    .opacity(contentOpacity)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
            pill
                .frame(width: pillSize.width, height: pillSize.height)
                .opacity(open ? 0 : 1)
                .allowsHitTesting(!open)
                .accessibilityHidden(open)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .background { MorphGlass(cornerRadius: radius, interactive: !open) }
        // Open: the panel sits just above where the pill is.
        .padding(.bottom, open ? pillSize.height + gap : 0)
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

    // MARK: Motion

    private func show(_ k: PlayerUIState.Panel?) {
        guard let k else { close(); return }
        if k == .nowPlaying || natural[k] != nil { grow(k) } else { measuring = k }
    }

    private func measured(_ k: PlayerUIState.Panel, _ h: CGFloat) {
        natural[k] = h
        guard measuring == k else { return }
        measuring = nil
        if ui.panel == k { grow(k) }
    }

    private func grow(_ k: PlayerUIState.Panel) {
        generation += 1
        if displayed != k {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { contentOpacity = 0; displayed = k }
        }
        withAnimation(morph) { open = true }
        withAnimation(.easeOut(duration: 0.2).delay(0.12)) { contentOpacity = 1 }
    }

    private func close() {
        measuring = nil
        guard displayed != nil else { return }
        generation += 1
        let gen = generation
        withAnimation(.easeOut(duration: 0.12)) { contentOpacity = 0 }
        withAnimation(morph, completionCriteria: .logicallyComplete) {
            open = false
        } completion: {
            if gen == generation, ui.panel == nil { displayed = nil }
        }
    }
}

/// The glass behind the pill / panel. Its corner radius is interpolated frame
/// by frame (Animatable), so the capsule-to-card change is smooth.
@available(iOS 26.0, *)
struct MorphGlass: View, Animatable {
    var cornerRadius: CGFloat
    var interactive: Bool
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    var body: some View {
        Color.clear.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
    }
}
#endif
