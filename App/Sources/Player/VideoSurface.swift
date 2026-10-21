import SwiftUI
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
        func install(_ sub: UIView) {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: trailingAnchor),
                sub.topAnchor.constraint(equalTo: topAnchor),
                sub.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
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
            if ui.showInfo { ui.showInfo = false; return }
            if ui.showConsole { ui.showConsole = false; return }
            withAnimation(.easeOut(duration: 0.2)) { ui.toggleControls() }
        }

        @objc private func doubleTap(_ g: UITapGestureRecognizer) {
            guard !ui.locked, let v = view else { return }
            let x = g.location(in: v).x / max(v.bounds.width, 1)
            let step = Double(UserDefaults.standard.integer(forKey: SettingsKey.seekStep))
            if x < 0.35 {
                model.seek(by: -step)
                flashHUD(icon: "gobackward", text: "-\(Int(step))s")
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
            guard !ui.locked, let v = view, !longPressActive else { return }
            let t = g.translation(in: v)
            switch g.state {
            case .began:
                let vel = g.velocity(in: v)
                if abs(vel.x) > abs(vel.y) {
                    guard model.duration > 0 else { panMode = .none; return }
                    panMode = .seek
                    panStartValue = model.position
                    ui.scrubbing = true
                } else if g.location(in: v).x < v.bounds.width / 2 {
                    panMode = .brightness
                    panStartValue = Double(v.window?.windowScene?.screen.brightness ?? UIScreen.main.brightness)
                } else {
                    panMode = .volume
                    panStartValue = model.volume
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
                    ui.gestureHUD = .init(icon: delta >= 0 ? "forward" : "backward",
                                          text: "\(PlayerModel.format(target))  (\(sign)\(PlayerModel.format(abs(delta))))",
                                          progress: target / model.duration, kind: .seek)
                case .brightness:
                    let value = min(1, max(0, panStartValue - Double(t.y / (v.bounds.height * 0.8))))
                    (v.window?.windowScene?.screen ?? UIScreen.main).brightness = CGFloat(value)
                    ui.gestureHUD = .init(icon: value < 0.34 ? "sun.min.fill" : "sun.max.fill", text: "\(Int(value * 100))%", progress: value, kind: .brightness)
                case .volume:
                    let value = min(150, max(0, panStartValue - Double(t.y / (v.bounds.height * 0.8)) * 100))
                    model.setVolume(value)
                    ui.gestureHUD = .init(icon: value == 0 ? "speaker.slash.fill" : value < 40 ? "speaker.wave.1.fill" : value < 90 ? "speaker.wave.2.fill" : "speaker.wave.3.fill",
                                          text: "\(Int(value))%", progress: min(1, value / 150), kind: .volume)
                case .none: break
                }
            case .ended, .cancelled:
                if panMode == .seek, let target = ui.scrubTime, g.state == .ended {
                    model.seek(to: target)
                }
                ui.scrubbing = false
                ui.scrubTime = nil
                panMode = .none
                hideHUD(after: 0.8)
            default: break
            }
        }

        @objc private func pinch(_ g: UIPinchGestureRecognizer) {
            guard !ui.locked, g.state == .ended else { return }
            if g.scale > 1.15, !model.zoomToFill { model.toggleZoom() }
            else if g.scale < 0.87, model.zoomToFill { model.toggleZoom() }
        }

        private func flashHUD(icon: String, text: String) {
            ui.gestureHUD = .init(icon: icon, text: text)
            hideHUD(after: 0.7)
        }

        private func hideHUD(after seconds: Double) {
            hudWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, !self.ui.scrubbing, !self.model.holdSpeedActive else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.ui.gestureHUD = nil }
            }
            hudWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }
}
