import UIKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// Watches every touch in the window without taking part in it: it never
/// begins, cancels nothing and delays nothing. It only measures how far the
/// finger has travelled on the screen, so a control that starts something
/// (Play, an episode row) can tell a tap from a swipe that happened to start
/// on it.
///
/// Why: a title page opened from Home goes back with the zoom transition's
/// own swipe, not the navigation controller's back-swipe recognizers that
/// `BackSwipeProbe` watches, and that swipe didn't stop the episode row under
/// the finger from counting a tap (26 Oct recording and log: "episode row →
/// play", no back swipe logged, the page then zoomed back to Home). Window
/// coordinates are the screen's, so the page moving along with the finger
/// doesn't hide the movement (as it did for the Play button in 1.16.0).
final class TouchTracker: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static let shared = TouchTracker()

    /// More than this (pt) on screen is a swipe, not a tap.
    static let tapSlop: CGFloat = 12

    private weak var tracked: UITouch?
    private var start: CGPoint = .zero
    private var travel: CGFloat = 0
    private var lastTravel: CGFloat = 0
    private var lastEnd: CFTimeInterval = 0

    private init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    /// Put on Home (1.17.2): its tiles check the travel too.
    struct Host: UIViewRepresentable {
        final class V: UIView {
            override func didMoveToWindow() { super.didMoveToWindow(); if let w = window { TouchTracker.install(on: w) } }
        }
        func makeUIView(context: Context) -> V { let v = V(); v.isUserInteractionEnabled = false; return v }
        func updateUIView(_ uiView: V, context: Context) {}
    }

    /// A tap on a control that starts something, or a swipe that happened to
    /// start on it? Logs and says so when it was a swipe.
    static func wasSwipe(_ what: String) -> Bool {
        let moved = recentTravel
        guard moved > tapSlop else { return false }
        dlog("nav", "\(what) ignored (the finger moved \(Int(moved)) pt: a swipe, not a tap)")
        return true
    }

    static func install(on window: UIWindow) {
        guard shared.view !== window else { return }
        shared.view?.removeGestureRecognizer(shared)
        window.addGestureRecognizer(shared)
    }

    /// How far the finger travelled: the touch that is down now, or the one
    /// that ended within the last half second (a button acts on touch up).
    static var recentTravel: CGFloat {
        if shared.tracked != nil { return shared.travel }
        return CACurrentMediaTime() - shared.lastEnd < 0.5 ? shared.lastTravel : 0
    }

    /// Lab (`-touchLog`): every touch's start and end in the log.
    static let logs = CommandLine.arguments.contains("-touchLog")

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let t = touches.first else { return }
        tracked = t
        start = t.location(in: nil)
        travel = 0
        if Self.logs {
            // The view the touch went to, and three of its containers.
            var chain: [String] = []
            var v = t.view
            while let x = v, chain.count < 4 { chain.append(String(describing: type(of: x))); v = x.superview }
            dlog("touch", "down (\(Int(start.x)), \(Int(start.y))) → \(chain.joined(separator: " < "))")
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        let p = t.location(in: nil)
        travel = max(travel, hypot(p.x - start.x, p.y - start.y))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { ended(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { ended(touches) }

    private func ended(_ touches: Set<UITouch>) {
        guard let t = tracked, touches.contains(t) else { return }
        let p = t.location(in: nil)
        lastTravel = max(travel, hypot(p.x - start.x, p.y - start.y))
        lastEnd = CACurrentMediaTime()
        if Self.logs { dlog("touch", "up (\(Int(p.x)), \(Int(p.y))), moved \(Int(lastTravel)) pt") }
        tracked = nil
        state = .failed            // never recognizes; UIKit resets it for the next touch
    }

    override func reset() {
        super.reset()
        tracked = nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
