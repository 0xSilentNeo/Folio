import SwiftUI
import MediaPlayer
import AVFoundation
import UIKit

/// Hosts the video — with the OpenGL renderer, PiP's sample-buffer layer
/// itself; with Metal, the Metal view in front of it — plus all touch
/// gestures.
struct VideoSurface: UIViewRepresentable {
    let model: PlayerModel
    let ui: PlayerUIState

    func makeCoordinator() -> Coordinator { Coordinator(model: model, ui: ui) }

    func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.backgroundColor = .black
        v.install(model.pip.view)
        if model.videoView !== model.pip.view { v.install(model.videoView) }
        model.videoContainer = v
        context.coordinator.attach(to: v)
        return v
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {}

    final class ContainerView: UIView {
        /// Frame-based, not Auto Layout: the video layers are touched by mpv's
        /// threads, and a layout pass that reaches them off the main thread
        /// must never involve the constraint engine.
        ///
        /// Laid out by bounds and centre (1.28.2): Fill scales the video
        /// layer's view (PlayerModel.applyLayerZoom), and a scaled view's
        /// frame is undefined, so autoresizing it on a turn of the phone
        /// could size it wrong.
        func install(_ sub: UIView) {
            sub.translatesAutoresizingMaskIntoConstraints = true
            sub.autoresizingMask = []
            sub.bounds = CGRect(origin: .zero, size: bounds.size)
            sub.center = CGPoint(x: bounds.midX, y: bounds.midY)
            addSubview(sub)
            clipsToBounds = true
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = bounds.size, mid = CGPoint(x: bounds.midX, y: bounds.midY)
            for sub in subviews where sub.bounds.size != size || sub.center != mid {
                sub.bounds = CGRect(origin: .zero, size: size)
                sub.center = mid
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: PlayerModel
        let ui: PlayerUIState
        weak var view: UIView?

        private enum PanMode { case none, seek, brightness, volume }
        private var panMode: PanMode = .none
        private var panStartValue: Double = 0
        private var longPressActive = false
        private var hudWork: DispatchWorkItem?

        init(model: PlayerModel, ui: PlayerUIState) {
            self.model = model
            self.ui = ui
        }

        /// While a menu is open: a tap closes it at once. The single tap below
        /// waits for the double tap to fail first (~0.35 s), and a tap to the
        /// right of a menu lands here, not on the player's tap catcher — the
        /// 27 Oct lab measured 350–410 ms there against 0–1 ms to the left
        /// (taps in the right-hand safe-area strip reach this view).
        private var panelTap: UITapGestureRecognizer?
        private var tapGestures: [UIGestureRecognizer] = []

        func attach(to v: UIView) {
            view = v
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            double.numberOfTapsRequired = 2
            // The single tap no longer waits ~0.35 s for a double tap to
            // fail (1.28.2): the controls answer at once, and the second tap
            // of a double tap leaves them as the first set them.
            let single = UITapGestureRecognizer(target: self, action: #selector(singleTap(_:)))
            let closer = UITapGestureRecognizer(target: self, action: #selector(closePanelTap(_:)))
            closer.delegate = self
            double.delegate = self
            single.delegate = self
            panelTap = closer
            tapGestures = [double, single]
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
            long.minimumPressDuration = 0.4
            long.allowableMovement = 12
            long.delegate = self
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let all: [UIGestureRecognizer] = [closer, double, single, pan, long, pinch]
            all.forEach { v.addGestureRecognizer($0) }
        }

        /// The menu closer acts only while a menu is open; the usual taps only
        /// while none is.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g === panelTap { return ui.panel != nil }
            if tapGestures.contains(where: { $0 === g }) { return ui.panel == nil }
            return true
        }

        @objc private func closePanelTap(_ g: UITapGestureRecognizer) {
            guard ui.panel != nil else { return }
            dlog("ui", "panel: tap outside (video)")
            ui.closePanel()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UILongPressGestureRecognizer && other is UIPanGestureRecognizer) ||
            (g is UIPanGestureRecognizer && other is UILongPressGestureRecognizer)
        }

        /// When the last single tap landed: the second tap of a double tap
        /// also arrives here, and mustn't toggle the controls back.
        private var lastSingleTap: CFTimeInterval = 0

        @objc private func singleTap(_ g: UITapGestureRecognizer) {
            let now = CACurrentMediaTime()
            defer { lastSingleTap = now }
            if now - lastSingleTap < 0.35 { return }
            if ui.panel != nil { dlog("ui", "panel: video tap closes it"); ui.closePanel(); return }
            if ui.showInfo || ui.showStats { withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { ui.showInfo = false; ui.showStats = false }; return }
            if ui.showConsole { ui.showConsole = false; return }
            withAnimation(.easeOut(duration: 0.2)) { ui.toggleControls() }
        }

        @objc private func doubleTap(_ g: UITapGestureRecognizer) {
            guard !ui.locked, let v = view else { return }
            FolioTips.gestureUsed()
            let x = g.location(in: v).x / max(v.bounds.width, 1)
            let step = Double(UserDefaults.standard.integer(forKey: SettingsKey.seekStep))
            let back = Double(max(1, UserDefaults.standard.integer(forKey: SettingsKey.seekBackStep)))
            if x < 0.35 {
                model.seek(by: -back)
                flashHUD(icon: "gobackward", text: "-\(Int(back))s")
            } else if x > 0.65 {
                model.seek(by: step)
                flashHUD(icon: "goforward", text: "+\(Int(step))s")
            } else {
                model.togglePause()
            }
        }

        @objc private func longPress(_ g: UILongPressGestureRecognizer) {
            guard !ui.locked else { return }
            switch g.state {
            case .began:
                longPressActive = true
                FolioTips.gestureUsed()
                model.beginHoldSpeed()
                if model.holdSpeedActive {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            case .ended, .cancelled, .failed:
                longPressActive = false
                if model.holdSpeedActive { model.endHoldSpeed() }
            default: break
            }
        }

        @objc private func pan(_ g: UIPanGestureRecognizer) {
            // A pan cut short by the lock or a long press still has to let go
            // of the scrub, or the time label stayed frozen (review, 2 Nov).
            if [.ended, .cancelled, .failed].contains(g.state), panMode != .none, ui.locked || longPressActive {
                ui.scrubbing = false
                model.clock.scrubTime = nil
                hideHUD(after: 0.3)
                panMode = .none
                return
            }
            guard !ui.locked, let v = view, !longPressActive, UserDefaults.standard.bool(forKey: SettingsKey.gestureControl) else { return }
            let t = g.translation(in: v)
            switch g.state {
            case .began:
                FolioTips.gestureUsed()
                let vel = g.velocity(in: v)
                let start = g.location(in: v)
                // A swipe that starts at the bottom edge is the home gesture (or
                // the app switcher); from the top it's Control Centre. Never seek
                // on those, even when the first movement is slightly sideways.
                if start.y > v.bounds.height - 28 || start.y < 28 { panMode = .none; return }
                // Commit to seeking only for a clearly horizontal start.
                if abs(vel.x) > abs(vel.y) * 1.5 {
                    guard model.duration > 0 else { panMode = .none; return }
                    panMode = .seek
                    panStartValue = model.position
                    ui.scrubbing = true
                } else {
                    // Vertical swipes: brightness on the outer left 25%, volume on
                    // the outer right 25%, nothing in the middle half — a swipe
                    // near the centre is almost always accidental. Judged from where
                    // the finger first touched (the pan begins ~10 pt later).
                    let downX = start.x - t.x
                    let w = v.bounds.width
                    if downX < w * 0.25 {
                        panMode = .brightness
                        panStartValue = Double(v.window?.windowScene?.screen.brightness ?? UIScreen.main.brightness)
                        if model.brightnessBefore == nil { model.brightnessBefore = CGFloat(panStartValue) }
                    } else if downX > w * 0.75 {
                        panMode = .volume
                        SystemVolume.attach(to: v.window)
                        panStartValue = Double(SystemVolume.current)
                    } else {
                        panMode = .none
                    }
                }
            case .changed:
                switch panMode {
                case .seek:
                    let range = min(max(model.duration * 0.25, 90), 360)
                    let delta = Double(t.x / max(v.bounds.width, 1)) * range
                    let target = min(max(0, panStartValue + delta), model.duration)
                    model.clock.scrubTime = target
                    model.scrub(to: target)
                    let sign = delta >= 0 ? "+" : "-"
                    setHUD(.init(icon: delta >= 0 ? "forward" : "backward",
                                 text: "\(PlayerModel.format(target))  (\(sign)\(PlayerModel.format(abs(delta))))",
                                 progress: target / model.duration, kind: .seek))
                case .brightness:
                    let value = min(1, max(0, panStartValue - Double(t.y / (v.bounds.height * 0.7))))
                    (v.window?.windowScene?.screen ?? UIScreen.main).brightness = CGFloat(value)
                    setHUD(.init(icon: value < 0.34 ? "sun.min.fill" : "sun.max.fill", text: "\(Int(value * 100))%", progress: value, kind: .brightness))
                case .volume:
                    // Device volume, 0–100 %, like the hardware buttons (mpv's own
                    // volume stays at 100 so nothing is scaled in software).
                    let value = min(1, max(0, panStartValue - Double(t.y / (v.bounds.height * 0.7))))
                    SystemVolume.set(Float(value))
                    // iOS shows its own volume indicator; the player's HUD only as a fallback.
                    if !SystemVolume.nativeHUD {
                        setHUD(.init(icon: value == 0 ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill",
                                     text: "\(Int(value * 100))%", progress: value, kind: .volume))
                    }
                case .none: break
                }
            case .ended, .cancelled, .failed:
                if panMode == .seek, let target = model.clock.scrubTime, g.state == .ended {
                    model.seek(to: target)
                }
                ui.scrubbing = false
                model.clock.scrubTime = nil
                hideHUD(after: panMode == .seek ? 0.5 : 0.9)
                panMode = .none
            default: break
            }
        }

        /// Pinch between Fit and Fill (1.23.1): the picture follows the
        /// fingers, then springs to Fit or Fill when they lift.
        ///
        /// 1.28.2, the video layer (OpenGL, Metal on engine 3): Fit and Fill
        /// are one scale of the layer's view (PlayerModel.applyLayerZoom),
        /// and the pinch moves that same scale. Nothing is handed over when
        /// it starts or ends: the spring goes on from where the fingers left
        /// the picture, at their speed, and subtitles follow every step.
        /// Metal on its own layer: mpv frames the picture itself as the
        /// fingers move (live panscan).
        private var pinchFromFill = false
        private var pinchRatio: CGFloat = 1
        private var pinchPanscan: Double = 0
        /// The layer's scale when the fingers came down.
        private var pinchBase: CGFloat = 1
        /// The last two steps of the pinch (scale, time): its speed at the end.
        private var pinchSteps: [(CGFloat, CFTimeInterval)] = []
        private var panscanAnimation: CADisplayLink?
        private var panscanFrom: Double = 0, panscanTo: Double = 0, panscanStart: CFTimeInterval = 0
        private var panscanDone: (() -> Void)?

        @objc private func pinch(_ g: UIPinchGestureRecognizer) {
            guard !ui.locked else { return }
            let layer = model.onLayer
            switch g.state {
            case .began:
                panscanAnimation?.invalidate(); panscanAnimation = nil
                pinchFromFill = model.zoomToFill
                pinchRatio = model.fillRatio
                pinchPanscan = pinchFromFill ? 1 : 0
                pinchSteps = []
                if layer, pinchRatio > 1.02 { pinchBase = model.beginLayerPinch() }
            case .changed:
                guard pinchRatio > 1.02 else { return }
                if layer {
                    // Fit (1) to Fill (the ratio), with a little give past either end.
                    let s = Self.rubber(pinchBase * g.scale, 1, pinchRatio)
                    model.setLayerScale(s)
                    pinchSteps.append((s, CACurrentMediaTime()))
                    if pinchSteps.count > 3 { pinchSteps.removeFirst() }
                } else {
                    let lo: CGFloat = pinchFromFill ? 1 / pinchRatio : 1
                    let hi: CGFloat = pinchFromFill ? 1 : pinchRatio
                    // Scale relative to Fit, within Fit…Fill → panscan 0…1.
                    let fit = (pinchFromFill ? pinchRatio : 1) * min(max(g.scale, lo), hi)
                    pinchPanscan = Double((fit - 1) / (pinchRatio - 1))
                    model.setLivePanscan(pinchPanscan)
                }
            case .ended, .cancelled, .failed:
                // Picture already the screen's shape: Fit and Fill look alike;
                // a firm pinch still switches, as before.
                guard pinchRatio > 1.02 else {
                    if g.state == .ended, (g.scale > 1.15 && !model.zoomToFill) || (g.scale < 0.87 && model.zoomToFill) { model.toggleZoom() }
                    return
                }
                if layer {
                    let r = pinchRatio
                    let s = model.layerScale
                    // Past halfway decides, or a quick flick the way it went.
                    let speed: CGFloat = pinchSteps.count >= 2
                        ? (pinchSteps.last!.0 - pinchSteps.first!.0) / max(0.008, CGFloat(pinchSteps.last!.1 - pinchSteps.first!.1))
                        : 0
                    var toFill = s > (1 + r) / 2
                    if abs(speed) > 0.9 { toFill = speed > 0 }
                    if g.state != .ended { toFill = pinchFromFill }
                    model.endLayerPinch(fill: toFill, velocity: g.state == .ended ? speed : 0)
                } else {
                    let toFill = pinchPanscan >= 0.5
                    let changes = g.state == .ended && toFill != pinchFromFill
                    let end: Double = changes ? (toFill ? 1 : 0) : (pinchFromFill ? 1 : 0)
                    animatePanscan(from: pinchPanscan, to: end) { [weak model] in
                        guard let model else { return }
                        if changes { model.setZoom(fill: toFill) } else { model.setLivePanscan(end) }
                    }
                }
            default: break
            }
        }

        /// Metal: panscan eased to Fit or Fill over a quarter second, a step per screen refresh.
        private func animatePanscan(from: Double, to: Double, done: @escaping () -> Void) {
            panscanAnimation?.invalidate()
            panscanFrom = from; panscanTo = to; panscanStart = CACurrentMediaTime(); panscanDone = done
            let link = CADisplayLink(target: self, selector: #selector(panscanStep(_:)))
            link.add(to: .main, forMode: .common)
            panscanAnimation = link
        }

        @objc private func panscanStep(_ link: CADisplayLink) {
            let t = min(1, (CACurrentMediaTime() - panscanStart) / 0.25)
            let eased = 1 - pow(1 - t, 3)
            model.setLivePanscan(panscanFrom + (panscanTo - panscanFrom) * eased)
            guard t >= 1 else { return }
            link.invalidate(); panscanAnimation = nil
            let done = panscanDone; panscanDone = nil
            done?()
        }

        /// The pinch's scale within lo…hi, with a little give past either end.
        /// At most 10% past either end (1.23.4: fingers spread wide took the
        /// picture to 2.4× Fit in the simulator).
        static func rubber(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            if x < lo { return max(lo * 0.9, lo - (lo - x) * 0.25) }
            if x > hi { return min(hi * 1.1, hi + (x - hi) * 0.25) }
            return x
        }

        private func flashHUD(icon: String, text: String) {
            setHUD(.init(icon: icon, text: text))
            hideHUD(after: 0.7)
        }

        /// First appearance springs in; later updates only move the value.
        private func setHUD(_ hud: PlayerUIState.GestureHUD) {
            hudWork?.cancel()
            if ui.gestureHUD == nil || ui.gestureHUD?.kind != hud.kind {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { ui.gestureHUD = hud }
            } else {
                ui.gestureHUD = hud
            }
        }

        private func hideHUD(after seconds: Double) {
            hudWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, !self.ui.scrubbing, !self.model.holdSpeedActive else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.ui.gestureHUD = nil }
            }
            hudWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }
}


/// Device output volume, set the way the hardware buttons do (through
/// MPVolumeView's slider — the only public way to change it).
@MainActor
enum SystemVolume {
    /// The volume view sets the device volume (like the hardware buttons). It
    /// is *hidden* so iOS shows its own volume indicator for swipes too — a
    /// visible MPVolumeView in the window makes iOS suppress that indicator.
    /// Apple's MPVolumeView docs don't describe the indicator rules and volume
    /// can't be changed in the Simulator, so the first swipe checks that the
    /// volume really moved; if a hidden view can't set it on this iOS, it falls
    /// back to an invisible-but-unhidden view and the player's own HUD.
    private static let view: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 10, height: 10))
        v.isUserInteractionEnabled = false
        v.isHidden = true
        return v
    }()
    private static var slider: UISlider? { view.subviews.compactMap { $0 as? UISlider }.first }
    private static var checked = false
    /// The last value asked for (1.28.8: the check below compared with the
    /// first, which a swipe has long left 0.3 s on, so it failed for no
    /// reason: iOS's indicator went for the rest of the run and the volume
    /// jumped back to where the swipe began).
    private static var asked: Float = 0
    private static var baseline: Float?
    /// iOS's own indicator is in use (so the player doesn't draw its HUD for volume).
    private(set) static var nativeHUD = true

    static func attach(to window: UIWindow?) {
        guard let window, view.superview !== window else { return }
        view.removeFromSuperview()
        window.addSubview(view)
        view.layoutIfNeeded()
    }

    static var current: Float { AVAudioSession.sharedInstance().outputVolume }

    static func set(_ value: Float) {
        guard let slider else { return }
        // Where the volume was when the first change was asked for: small
        // steps (the keyboard's are 1/16) add up against it.
        if baseline == nil { baseline = current }
        let before = baseline ?? current
        slider.value = value
        slider.sendActions(for: .valueChanged)
        asked = value
        // Checked once a real move has been asked for.
        guard !checked, abs(value - before) > 0.1 else { return }
        checked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let now = current, value = asked
            // Asked back to where it began meanwhile: nothing to tell from.
            guard abs(value - before) > 0.05 else { checked = false; return }
            // "Didn't set it" is the volume not having moved at all (1.30.1).
            // It was "not within 0.08 of what was asked", and a Bluetooth
            // headset moves in steps of 1/16 and a moment late: 12 Nov report,
            // AirPods, "wanted 0.66, got 0.75", and iOS's indicator was gone
            // for the rest of the run.
            if abs(now - before) < 0.01 && nativeHUD {
                dlog("player", String(format: "volume: hidden volume view didn't set the volume (wanted %.2f, got %.2f); using the player's HUD", value, now))
                nativeHUD = false
                view.isHidden = false
                view.alpha = 0.01
                slider.value = value
                slider.sendActions(for: .valueChanged)
            } else {
                dlog("player", String(format: "volume: set through the hidden volume view (%.2f); iOS shows its indicator", now))
            }
        }
    }
}
