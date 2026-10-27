import UIKit

/// Lab (`-lingerLab`): what is left of a page after it goes back.
///
/// 27 Oct report: "I think the page is still on screen but hidden after
/// backing for a few moments. That's what's causing the sudden play." Device
/// logs agree that it can stay: after some swipes back, the navigation path is
/// already Home but the page's `onDisappear` comes 0.9–1.4 s later.
///
/// Every frame, for every page the navigation has had: is it still in the
/// window, the navigation's top, drawn (opacity, frame), touchable, and how
/// many of 50 points spread over the screen a touch would reach it at. Every
/// touch: which page it went to. Only changes are logged.
///
/// Self-contained (no other lab code needed), so the same file runs on an
/// older build for comparison.
@MainActor
final class LingerLab: NSObject {
    static let on = CommandLine.arguments.contains("-lingerLab")
    static let shared = LingerLab()

    private var link: CADisplayLink?
    private final class Seen { weak var vc: UIViewController?; let id: Int; var last = ""; var gone = false
        init(_ vc: UIViewController, _ id: Int) { self.vc = vc; self.id = id } }
    private var seen: [Seen] = []
    private var nextId = 1
    private weak var lastTop: UIViewController?
    private weak var watchedWindow: UIWindow?
    private var lastTransition = "none"

    static func startIfAsked() {
        guard on else { return }
        let l = CADisplayLink(target: shared, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        shared.link = l
        dlog("linger", "lab on")
    }

    // MARK: Finding Home's navigation

    private func mainWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first { $0.windowLevel == .normal && nav(in: $0.rootViewController) != nil }
    }

    private func nav(in vc: UIViewController?) -> UINavigationController? {
        guard let vc else { return nil }
        if let n = vc as? UINavigationController { return n }
        for c in vc.children { if let n = nav(in: c) { return n } }
        return nil
    }

    private func id(of vc: UIViewController?) -> String {
        guard let vc, let s = seen.first(where: { $0.vc === vc }) else { return "?" }
        return s.id == 1 ? "Home" : "page#\(s.id)"
    }

    // MARK: Each frame

    @objc private func tick() {
        guard let w = mainWindow(), let nav = nav(in: w.rootViewController) else { return }
        if watchedWindow !== w {
            watchedWindow = w
            let g = Watcher(); g.lab = self
            w.addGestureRecognizer(g)
        }
        for vc in nav.viewControllers where !seen.contains(where: { $0.vc === vc }) {
            let s = Seen(vc, nextId); nextId += 1
            seen.append(s)
            if s.id > 1 { dlog("linger", "page#\(s.id) pushed") }
        }
        if nav.topViewController !== lastTop {
            lastTop = nav.topViewController
            dlog("linger", "navigation top is now \(id(of: lastTop)) (stack: \(nav.viewControllers.map { id(of: $0) }.joined(separator: ", ")))")
        }
        let tc = nav.transitionCoordinator
        let tr = tc.map { $0.isInteractive ? "interactive" : "animated" } ?? "none"
        if tr != lastTransition { lastTransition = tr; dlog("linger", "navigation transition: \(tr)") }

        for s in seen where s.id > 1 && !s.gone {
            guard let vc = s.vc else { s.gone = true; dlog("linger", "page#\(s.id) released"); continue }
            let v = vc.view!
            let inStack = nav.viewControllers.contains(vc)
            let place = nav.topViewController === vc ? "top" : (inStack ? "in the stack" : "NOT in the stack")
            let state: String
            if v.window == nil {
                state = "not in the window (\(place))"
            } else {
                let shown = presentedOpacity(v)
                let f = presentedFrame(v, in: w)
                let hits = gridHits(w, page: v)
                state = "IN THE WINDOW, \(place), drawn at opacity \(String(format: "%.1f", shown)) in \(rough(f)), alpha \(String(format: "%.2f", modelAlpha(v))), touchable \(touchable(v) ? "yes" : "no"), touches would reach it at \(hits)/50 points"
            }
            if state != s.last { s.last = state; dlog("linger", "page#\(s.id): \(state)") }
        }
    }

    private func presentedOpacity(_ v: UIView) -> Float {
        var o: Float = 1
        var l: CALayer? = v.layer
        while let x = l { o *= (x.presentation() ?? x).opacity; if x.isHidden { return 0 }; l = x.superlayer }
        return o
    }

    private func modelAlpha(_ v: UIView) -> CGFloat {
        var a: CGFloat = 1
        var x: UIView? = v
        while let y = x { a *= y.alpha; x = y.superview }
        return a
    }

    private func touchable(_ v: UIView) -> Bool {
        var x: UIView? = v
        while let y = x { if !y.isUserInteractionEnabled || y.isHidden { return false }; x = y.superview }
        return true
    }

    private func presentedFrame(_ v: UIView, in w: UIWindow) -> CGRect {
        guard let pl = v.layer.presentation(), let wl = w.layer.presentation() else { return v.convert(v.bounds, to: w) }
        return pl.convert(pl.bounds, to: wl)
    }

    /// The frame to the nearest 10 pt, so a moving page doesn't log every pixel.
    private func rough(_ f: CGRect) -> String {
        func r(_ x: CGFloat) -> Int { Int((x / 10).rounded()) * 10 }
        return "(\(r(f.minX)), \(r(f.minY)), \(r(f.width))×\(r(f.height)))"
    }

    private func gridHits(_ w: UIWindow, page: UIView) -> Int {
        var n = 0
        for i in 0..<5 {
            for j in 0..<10 {
                let p = CGPoint(x: w.bounds.width * (CGFloat(i) + 0.5) / 5, y: w.bounds.height * (CGFloat(j) + 0.5) / 10)
                if let h = w.hitTest(p, with: nil), h.isDescendant(of: page) { n += 1 }
            }
        }
        return n
    }

    // MARK: Touches

    fileprivate func touch(_ t: UITouch, _ phase: String) {
        let p = t.location(in: nil)
        var owner = "no page"
        if let tv = t.view {
            if let s = seen.last(where: { $0.vc.map { tv.isDescendant(of: $0.view) } ?? false }) {
                let top = (s.vc?.navigationController?.topViewController === s.vc)
                owner = (s.id == 1 ? "Home" : "page#\(s.id)") + (top ? " (top)" : " (NOT the top)")
            } else {
                owner = String(describing: type(of: tv))
            }
        }
        dlog("linger", "touch \(phase) (\(Int(p.x)), \(Int(p.y))) → \(owner)")
    }

    /// Sees every touch in the window without taking part in it.
    private final class Watcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        weak var lab: LingerLab?
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
            delegate = self
        }
        convenience init() { self.init(target: nil, action: nil) }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { touches.forEach { lab?.touch($0, "down") } }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { touches.forEach { lab?.touch($0, "up") }; end(event) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { touches.forEach { lab?.touch($0, "cancelled") }; end(event) }
        private func end(_ e: UIEvent) {
            if (e.allTouches ?? []).allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) { state = .failed }
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
