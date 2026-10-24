import SwiftUI
import MediaPlayer
import AVFoundation
import UIKit

/// Hosts the PiP sample-buffer layer (behind) and the mpv GL view (front),
/// plus all touch gestures.
struct VideoSurface: UIViewRepresentable {
    let model: PlayerModel
    let ui: PlayerUIState

    func makeCoordinator() -> Coordinator { Coordinator(model: model, ui: ui) }

    func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.backgroundColor = .black
        v.install(model.pip.view)
        v.install(model.videoView)
        model.videoContainer = v
        context.coordinator.attach(to: v)
        return v
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {}

    final class ContainerView: UIView {
        /// Frame-based, not Auto Layout: the video layers are touched by mpv's
        /// threads, and a layout pass that reaches them off the main thread
        /// must never involve the constraint engine.
        func install(_ sub: UIView) {
            sub.translatesAutoresizingMaskIntoConstraints = true
            sub.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            sub.frame = bounds
            addSubview(sub)
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

        func attach(to v: UIView) {
            view = v
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            double.numberOfTapsRequired = 2
            let single = UITapGestureRecognizer(target: self, action: #selector(singleTap(_:)))
            single.require(toFail: double)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
            long.minimumPressDuration = 0.4
            long.allowableMovement = 12
            long.delegate = self
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let all: [UIGestureRecognizer] = [double, single, pan, long, pinch]
            all.forEach { v.addGestureRecognizer($0) }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UILongPressGestureRecognizer && other is UIPanGestureRecognizer) ||
            (g is UIPanGestureRecognizer && other is UILongPressGestureRecognizer)
        }

        @objc private func singleTap(_ g: UITapGestureRecognizer) {
            if ui.panel != nil { ui.closePanel(); return }
            if ui.showTune { withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { ui.showTune = false }; return }
            if ui.showInfo || ui.showStats { withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { ui.showInfo = false; ui.showStats = false }; return }
            if ui.showConsole { ui.showConsole = false; return }
            withAnimation(.easeOut(duration: 0.2)) { ui.toggleControls() }
        }

        @objc private func doubleTap(_ g: UITapGestureRecognizer) {
            guard !ui.locked, let v = view else { return }
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
            guard !ui.locked, let v = view, !longPressActive, UserDefaults.standard.bool(forKey: SettingsKey.gestureControl) else { return }
            let t = g.translation(in: v)
            switch g.state {
            case .began:
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
                    // Vertical swipes: brightness on the outer left, volume on the
                    // outer right, nothing in the middle third — a swipe near the
                    // centre is almost always accidental. Judged from where the
                    // finger first touched (the pan begins ~10 pt later).
                    let downX = start.x - t.x
                    let w = v.bounds.width
                    if downX < w * 0.35 {
                        panMode = .brightness
                        panStartValue = Double(v.window?.windowScene?.screen.brightness ?? UIScreen.main.brightness)
                    } else if downX > w * 0.65 {
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
                    ui.scrubTime = target
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
                    setHUD(.init(icon: value == 0 ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill",
                                 text: "\(Int(value * 100))%", progress: value, kind: .volume))
                case .none: break
                }
            case .ended, .cancelled:
                if panMode == .seek, let target = ui.scrubTime, g.state == .ended {
                    model.seek(to: target)
                }
                ui.scrubbing = false
                ui.scrubTime = nil
                hideHUD(after: panMode == .seek ? 0.5 : 0.9)
                panMode = .none
            default: break
            }
        }

        @objc private func pinch(_ g: UIPinchGestureRecognizer) {
            guard !ui.locked, g.state == .ended else { return }
            if g.scale > 1.15, !model.zoomToFill { model.toggleZoom() }
            else if g.scale < 0.87, model.zoomToFill { model.toggleZoom() }
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
    private static let view: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 10, height: 10))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        return v
    }()
    private static var slider: UISlider? { view.subviews.compactMap { $0 as? UISlider }.first }

    static func attach(to window: UIWindow?) {
        guard let window, view.superview !== window else { return }
        view.removeFromSuperview()
        window.addSubview(view)
        view.layoutIfNeeded()
    }

    static var current: Float { AVAudioSession.sharedInstance().outputVolume }

    static func set(_ value: Float) {
        guard let slider else { return }
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }
}
