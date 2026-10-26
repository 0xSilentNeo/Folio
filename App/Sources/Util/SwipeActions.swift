import SwiftUI
import UIKit

/// A button revealed by swiping a row to the left (title page episodes).
struct SwipeAction: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void
}

/// Swipe a row left to reveal actions; a long swipe runs the first one.
///
/// Title pages are a ScrollView inside a navigation stack, so the system's
/// List swipe actions (rows of a List only — swipeActions docs) aren't
/// available there, and a swipe to the right is the back swipe. This uses a
/// UIKit pan recognizer (UIGestureRecognizerRepresentable, iOS 18) whose
/// delegate only lets it begin for a mostly horizontal swipe to the LEFT (or
/// either way while the row is open): vertical scrolling and the back swipe
/// never meet it. When it begins it takes the touch from the row, so the
/// row's own tap (play) can't fire.
struct SwipeRow<Content: View>: View {
    let id: String
    @Binding var openID: String?
    let actions: [SwipeAction]
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    private let buttonWidth: CGFloat = 76
    private var reveal: CGFloat { buttonWidth * CGFloat(actions.count) }
    private var isOpen: Bool { openID == id }

    var body: some View {
        if #available(iOS 18.0, *), !actions.isEmpty {
            ZStack(alignment: .trailing) {
                buttons
                content
                    .offset(x: offset)
                    // While open, a tap on the row closes it (it doesn't play).
                    .overlay {
                        if isOpen { Color.clear.contentShape(Rectangle()).onTapGesture { close() } }
                    }
                    .gesture(LeftSwipeRecognizer(isOpen: isOpen, onChanged: changed, onEnded: ended))
            }
            .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
            .onChange(of: openID) { _, v in if v != id, offset != 0 { withAnimation(.snappy(duration: 0.25)) { offset = 0 } } }
        } else {
            content
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            ForEach(actions.reversed()) { a in
                Button {
                    close()
                    a.action()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: a.icon).font(.system(size: 17, weight: .semibold))
                        Text(a.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(a.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(a.title)
            }
        }
        .frame(width: max(0, -offset - 6))
        .opacity(offset < -8 ? 1 : 0)
    }

    private func changed(_ t: CGFloat) {
        var x = (isOpen ? -reveal : 0) + t
        if x > 0 { x = 0 }
        let full = width * 0.6
        if x < -reveal, -x < full { x = -reveal + (x + reveal) * 0.5 }   // gentle resistance past the buttons
        offset = x
    }

    private func ended(_ t: CGFloat, _ velocity: CGFloat) {
        if width > 0, -offset >= width * 0.6, let first = actions.first {
            close()
            first.action()
        } else if -offset > reveal / 2 || velocity < -600 {
            withAnimation(.snappy(duration: 0.25)) { offset = -reveal }
            openID = id
        } else {
            close()
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.25)) { offset = 0 }
        if isOpen { openID = nil }
    }
}

/// Thumbnails (grid tiles): there's no room for buttons beside a tile, so a
/// swipe to the left lays the actions over the tile itself. A tap outside the
/// buttons, a swipe to the right, or opening another tile closes it.
struct SwipeTile<Content: View>: View {
    let id: String
    @Binding var openID: String?
    let actions: [SwipeAction]
    var cornerRadius: CGFloat = 12
    @ViewBuilder var content: Content

    @State private var drag: CGFloat = 0
    private var isOpen: Bool { openID == id }

    var body: some View {
        if #available(iOS 18.0, *), !actions.isEmpty {
            content
                .offset(x: drag)
                .overlay { if isOpen { panel.transition(.opacity) } }
                .gesture(LeftSwipeRecognizer(isOpen: isOpen, onChanged: changed, onEnded: ended))
        } else {
            content
        }
    }

    private var panel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.black.opacity(0.35)))
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 8) {
                ForEach(actions) { a in
                    Button {
                        close()
                        a.action()
                    } label: {
                        Label(a.title, systemImage: a.icon)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(a.tint, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(a.title)
                }
            }
            .padding(10)
        }
    }

    private func changed(_ t: CGFloat) {
        // The tile follows the finger a little, so the swipe is felt.
        drag = isOpen ? 0 : max(-24, min(0, t * 0.3))
    }

    private func ended(_ t: CGFloat, _ velocity: CGFloat) {
        dlog("ui", "swipe tile \(id): ended at \(Int(t)) pt, \(Int(velocity)) pt/s (\(isOpen ? "open" : "closed"))")
        withAnimation(.snappy(duration: 0.25)) {
            drag = 0
            if isOpen {
                if t > 20 || velocity > 300 { openID = nil }
            } else if t < -40 || velocity < -500 {
                openID = id
            }
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { if isOpen { openID = nil } }
    }
}

@available(iOS 18.0, *)
private struct LeftSwipeRecognizer: UIGestureRecognizerRepresentable {
    var isOpen: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isOpen = false
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: nil)
            guard abs(v.x) > abs(v.y) * 1.5 else { return false }      // mostly horizontal
            return v.x < 0 || isOpen                                   // to the left, or closing an open row
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        context.coordinator.isOpen = isOpen
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isOpen = isOpen
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let t = g.translation(in: nil).x
        switch g.state {
        case .changed: onChanged(t)
        case .ended, .cancelled, .failed: onEnded(t, g.velocity(in: nil).x)
        default: break
        }
    }
}
