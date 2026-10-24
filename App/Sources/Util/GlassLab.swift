import SwiftUI

#if compiler(>=6.2)
/// `-glassLab` (CI simulator recording): Apple's documented Liquid Glass morph
/// next to the player's pill → panel set-up and variants of it, all toggling
/// together with a slow animation, so the recording shows which set-ups
/// really morph (matched geometry) and which only materialize (fade in place).
@available(iOS 26.0, *)
struct GlassLab: View {
    @State private var open = false
    @State private var t0 = Date()
    private let anim = Animation.spring(duration: 1.6, bounce: 0.15)

    var body: some View {
        ZStack {
            // Moving colour behind the glass, so the glass is visible.
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSince(t0)
                LinearGradient(colors: [.purple, .orange, .teal, .pink],
                               startPoint: UnitPoint(x: 0.5 + 0.5 * cos(t), y: 0), endPoint: UnitPoint(x: 0.5 - 0.5 * cos(t), y: 1))
            }
            .ignoresSafeArea()
            VStack(spacing: 14) {
                Text(open ? "OPEN" : "CLOSED").font(.headline.monospaced()).foregroundStyle(.white)
                HStack(alignment: .bottom, spacing: 12) {
                    cell("A Apple example") { appleExample }
                    cell("B pill→panel overlay") { overlayVariant(interactivePill: true) }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    cell("E emerge, gap=spacing 12") { emerge(gap: 12, ns: nsE) }
                    cell("F emerge, gap=spacing 20") { emerge(gap: 20, ns: nsF) }
                }
            }
        }
        .task {
            dlog("lab", "glass lab")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                dlog("lab", "glass lab toggle → \(!open)")
                withAnimation(anim) { open.toggle() }
            }
        }
    }

    private func cell<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 6) {
            content().frame(width: 180, height: 300, alignment: .bottomTrailing)
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.white)
        }
        .padding(6)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    // A: "Applying Liquid Glass to custom views" — the eraser morphs out of the pencil.
    @Namespace private var nsA
    private var appleExample: some View {
        GlassEffectContainer(spacing: 40.0) {
            HStack(spacing: 40.0) {
                Image(systemName: "scribble.variable")
                    .frame(width: 60.0, height: 60.0).font(.system(size: 26))
                    .glassEffect()
                    .glassEffectID("pencil", in: nsA)
                if open {
                    Image(systemName: "eraser.fill")
                        .frame(width: 60.0, height: 60.0).font(.system(size: 26))
                        .glassEffect()
                        .glassEffectID("eraser", in: nsA)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var pill: some View {
        HStack(spacing: 0) {
            ForEach(["switch.2", "slider.horizontal.3", "list.bullet"], id: \.self) {
                Image(systemName: $0).font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 3).foregroundStyle(.white)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playback").font(.caption.weight(.bold))
            ForEach(0..<5, id: \.self) { i in
                HStack { Text("Row \(i + 1)").font(.caption2); Spacer(); Capsule().fill(.white.opacity(0.3)).frame(width: 30, height: 14) }
            }
        }
        .foregroundStyle(.white).padding(12)
    }

    // B/C: the player's structure (GlassPanels.swift): pill or a clear placeholder,
    // the panel in an overlay above it, same glassEffectID.
    @Namespace private var nsB
    @Namespace private var nsC
    private func overlayVariant(interactivePill: Bool) -> some View {
        let ns = interactivePill ? nsB : nsC
        return GlassEffectContainer(spacing: 40) {
            ZStack {
                if !open {
                    pill
                        .glassEffect(interactivePill ? .regular.interactive() : .regular, in: .capsule)
                        .glassEffectID("panels", in: ns)
                        .glassEffectTransition(.matchedGeometry)
                } else {
                    Color.clear
                }
            }
            .frame(width: 108, height: 34)
            .overlay(alignment: .bottomTrailing) {
                if open {
                    panelContent.frame(width: 170, height: 200)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .glassEffectID("panels", in: ns)
                        .glassEffectTransition(.matchedGeometry)
                        .padding(.bottom, 42)
                }
            }
        }
    }

    // E/F: Apple's pattern applied to the pill: the pill stays, the panel is a
    // second glass shape (its own ID) inserted above it, the gap between them
    // equal to the container's spacing ("morphs ... when the eraser's nearest
    // edge is less than or equal to the container's spacing").
    @Namespace private var nsE
    @Namespace private var nsF
    private func emerge(gap: CGFloat, ns: Namespace.ID) -> some View {
        GlassEffectContainer(spacing: gap) {
            VStack(alignment: .trailing, spacing: gap) {
                if open {
                    panelContent.frame(width: 170, height: 200)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .glassEffectID("panel", in: ns)
                }
                pill
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("pill", in: ns)
            }
            .frame(width: 180, height: 300, alignment: .bottomTrailing)
        }
    }

    // D: pill and panel siblings in one VStack (no overlay), same glass.
    @Namespace private var nsD
    private var stackVariant: some View {
        GlassEffectContainer(spacing: 40) {
            VStack(alignment: .trailing, spacing: 8) {
                if open {
                    panelContent.frame(width: 170, height: 200)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .glassEffectID("panels", in: nsD)
                        .glassEffectTransition(.matchedGeometry)
                } else {
                    Spacer(minLength: 0)
                    pill
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("panels", in: nsD)
                        .glassEffectTransition(.matchedGeometry)
                }
            }
            .frame(width: 180, height: 300, alignment: .bottomTrailing)
        }
    }
}
#endif
