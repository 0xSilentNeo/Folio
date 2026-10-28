import Foundation
import os
import QuartzCore
import UIKit

/// Picture in Picture trace: Settings → Help & Diagnostics → Diagnostics →
/// Trace Picture in Picture. Off by default.
///
/// Each line goes to the unified log (subsystem dev.silentneo.glassplayer,
/// category "pip", with signpost intervals for Instruments) and to app.log as
/// "[pip] +N ms …", N counted from the start of the current transition
/// (going into PiP, or coming back to the app while PiP plays), so the
/// report you send has the whole timeline.
@MainActor
enum PiPTrace {
    static let subsystem = "dev.silentneo.glassplayer"
    nonisolated static let logger = Logger(subsystem: subsystem, category: "pip")
    nonisolated static let signposter = OSSignposter(subsystem: subsystem, category: "pip")

    static var on: Bool { UserDefaults.standard.bool(forKey: SettingsKey.pipTrace) }

    private static var t0: CFTimeInterval = 0
    static var sinceMark: Int { Int((CACurrentMediaTime() - t0) * 1000) }

    /// A transition starts: later lines count from here.
    static func mark(_ what: String) {
        guard on else { return }
        t0 = CACurrentMediaTime()
        event("— \(what)")
    }

    static func event(_ what: String) {
        guard on else { return }
        let line = "+\(sinceMark) ms \(what)"
        logger.info("\(line, privacy: .public)")
        signposter.emitEvent("pip", "\(what, privacy: .public)")
        dlog("pip", line)
    }

    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        on ? signposter.beginInterval(name, id: signposter.makeSignpostID()) : nil
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        if let state { signposter.endInterval(name, state) }
    }

    // MARK: The video's own timeline

    /// Which frame mpv has on screen, every 8 ms for `seconds`, read on a
    /// background queue (mpv property reads wait for its core, and must not
    /// hold up the main thread). mpv's playback time while video plays is the
    /// time of the last frame its video output showed (playloop.c,
    /// handle_playback_time). Logged as a summary: stalls (the frame didn't
    /// change for more than 1.5 frame durations) and jumps (frames skipped),
    /// with mpv's dropped/delayed frame counters before and after.
    final class Sampler: @unchecked Sendable {
        private struct Sample { let t: CFTimeInterval; let pos: Double; let frame: Int64 }
        private let client: MPVClient
        private let queue = DispatchQueue(label: "pip.trace.sampler", qos: .utility)
        private var timer: DispatchSourceTimer?
        private var samples: [Sample] = []
        private var counters0: [String: Int64] = [:]
        private let started = CACurrentMediaTime()
        private let base: CFTimeInterval
        private let label: String
        private static let counterNames = ["frame-drop-count", "decoder-frame-drop-count", "vo-delayed-frame-count", "mistimed-frame-count"]

        init(client: MPVClient, label: String, base: CFTimeInterval) {
            self.client = client
            self.label = label
            self.base = base
        }

        func start(seconds: Double, done: @escaping @MainActor (String) -> Void) {
            queue.async { [self] in
                for n in Self.counterNames { counters0[n] = client.int(n) ?? -1 }
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
                t.setEventHandler { [self] in
                    if CACurrentMediaTime() - started > seconds {
                        timer?.cancel(); timer = nil
                        let text = summary()
                        DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
                        return
                    }
                    guard !client.isShutDown else { return }
                    samples.append(Sample(t: CACurrentMediaTime(), pos: client.double("time-pos") ?? -1, frame: client.int("estimated-frame-number") ?? -1))
                }
                timer = t
                t.resume()
            }
        }

        private func ms(_ t: CFTimeInterval) -> Int { Int((t - base) * 1000) }

        private func summary() -> String {
            let fps = client.double("container-fps") ?? client.double("estimated-vf-fps") ?? 24
            let frameMS = 1000 / max(1, fps)
            var stalls: [String] = []
            var jumps: [String] = []
            var lastChange = samples.first
            var longestStall = 0.0
            for i in 1..<max(1, samples.count) {
                let a = samples[i - 1], b = samples[i]
                guard b.frame != a.frame || abs(b.pos - a.pos) > 0.0005 else { continue }
                if let c = lastChange {
                    let held = (b.t - c.t) * 1000
                    if held > frameMS * 1.5 {
                        stalls.append("\(Int(held)) ms from +\(ms(c.t))")
                        longestStall = max(longestStall, held)
                    }
                }
                let step = b.frame - a.frame
                if step > 1 || step < 0 { jumps.append("\(step > 0 ? "+" : "")\(step) frames at +\(ms(b.t))") }
                lastChange = b
            }
            var counters: [String] = []
            for n in Self.counterNames {
                let now = client.int(n) ?? -1
                if let was = counters0[n], was >= 0, now >= 0, now != was { counters.append("\(n) +\(now - was)") }
            }
            let span = samples.isEmpty ? 0 : Int((samples.last!.t - samples.first!.t) * 1000)
            return String(format: "%@ video timeline: %ld samples over %ld ms, %.3g fps (%.1f ms a frame); longest hold %.0f ms; ", label, samples.count, span, fps, frameMS, longestStall)
                + "stalls: \(stalls.isEmpty ? "none" : stalls.prefix(12).joined(separator: ", ")); "
                + "jumps: \(jumps.isEmpty ? "none" : jumps.prefix(12).joined(separator: ", ")); "
                + "mpv counters: \(counters.isEmpty ? "unchanged" : counters.joined(separator: ", "))"
        }
    }

    /// Main-thread frames over 25 ms (UI hitches) while a transition runs.
    @MainActor
    final class HitchWatch: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var until: CFTimeInterval = 0
        private var hitches: [String] = []

        func start(seconds: Double) {
            link?.invalidate()
            hitches = []
            last = 0
            until = CACurrentMediaTime() + seconds
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func tick(_ l: CADisplayLink) {
            if last > 0 {
                let gap = (l.timestamp - last) * 1000
                if gap > 25 { hitches.append("\(Int(gap)) ms at +\(PiPTrace.sinceMark)") }
            }
            last = l.timestamp
            if CACurrentMediaTime() > until {
                l.invalidate(); link = nil
                PiPTrace.event("main thread: \(hitches.isEmpty ? "no frame over 25 ms" : "frames over 25 ms: " + hitches.prefix(12).joined(separator: ", "))")
            }
        }
    }

    // MARK: What the app looks like when iOS takes its snapshot

    /// UIKit takes the app switcher snapshot "shortly after"
    /// sceneDidEnterBackground returns (UIWindowSceneDelegate docs). The
    /// scene's windows are logged and drawn into an image
    /// (diagnostics/pip-ui-*.jpg, included in the report).
    static func captureUI(_ reason: String) {
        guard on else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for s in scenes {
            event("\(reason): scene \(stateName(s.activationState)), orientation \(s.interfaceOrientation.isLandscape ? "landscape" : "portrait"), \(s.windows.count) window(s)")
            for (i, w) in s.windows.enumerated() {
                let root = w.rootViewController.map { String(describing: type(of: $0)) } ?? "none"
                event("  window \(i) \(type(of: w)) level \(w.windowLevel.rawValue) hidden \(w.isHidden) alpha \(String(format: "%.2f", w.alpha)) key \(w.isKeyWindow) \(Int(w.bounds.width))×\(Int(w.bounds.height)) root \(root)")
            }
            guard let top = s.windows.filter({ !$0.isHidden && $0.alpha > 0.01 }).max(by: { $0.windowLevel.rawValue < $1.windowLevel.rawValue }) else {
                event("  no visible window to draw")
                continue
            }
            let image = UIGraphicsImageRenderer(bounds: top.bounds).image { _ in _ = top.drawHierarchy(in: top.bounds, afterScreenUpdates: false) }
            let file = Diagnostics.shared.dir.appendingPathComponent("pip-ui-\(Int(Date().timeIntervalSince1970))-\(reason.replacingOccurrences(of: " ", with: "-")).jpg")
            if let data = image.jpegData(compressionQuality: 0.5) {
                try? data.write(to: file)
                event("  drew the top window (\(type(of: top))) into \(file.lastPathComponent)")
            }
        }
        pruneImages()
    }

    /// The snapshots iOS keeps for the app switcher, from the app's own
    /// Library/SplashBoard (name, size, when written).
    static func listSnapshots(_ reason: String) {
        guard on else { return }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("SplashBoard", isDirectory: true)
        guard let e = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else {
            event("\(reason): no SplashBoard folder")
            return
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            lines.append("\(u.path.replacingOccurrences(of: lib.path + "/", with: "")) \(v.fileSize ?? 0) B \(v.contentModificationDate.map(f.string) ?? "?")")
        }
        event("\(reason): SplashBoard has \(lines.count) file(s)\(lines.isEmpty ? "" : ": " + lines.sorted().joined(separator: " | "))")
    }

    /// Keeps the newest 8 window images.
    private static func pruneImages() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Diagnostics.shared.dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let imgs = files.filter { $0.lastPathComponent.hasPrefix("pip-ui-") }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
        for old in imgs.dropFirst(8) { try? fm.removeItem(at: old) }
    }

    static func stateName(_ s: UIScene.ActivationState) -> String {
        switch s {
        case .foregroundActive: return "active"
        case .foregroundInactive: return "inactive"
        case .background: return "background"
        case .unattached: return "unattached"
        @unknown default: return "unknown"
        }
    }

    // MARK: Scene life (always logged: rare, one line each)

    private static var sceneObservers: [NSObjectProtocol] = []

    /// Scene connections and state changes, in app.log ("[scene] …"). A new
    /// scene connecting while the app is already running means the root view
    /// is built again — the launch splash plays again with it.
    static func watchScenes() {
        guard sceneObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIScene.willConnectNotification, "connects"),
            (UIScene.didDisconnectNotification, "disconnected"),
            (UIScene.willEnterForegroundNotification, "will enter foreground"),
            (UIScene.didActivateNotification, "active"),
            (UIScene.willDeactivateNotification, "will deactivate"),
            (UIScene.didEnterBackgroundNotification, "in background"),
        ]
        for (name, what) in names {
            sceneObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                let id = (note.object as? UIScene)?.session.persistentIdentifier.prefix(8) ?? "?"
                MainActor.assumeIsolated {
                    dlog("scene", "\(id) \(what)")
                    PiPTrace.event("scene \(what)")
                    if name == UIScene.didEnterBackgroundNotification {
                        PiPTrace.captureUI("entered background")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { PiPTrace.listSnapshots("2 s in the background") }
                    } else if name == UIScene.willEnterForegroundNotification {
                        PiPTrace.listSnapshots("coming forward")
                    }
                }
            })
        }
    }
}
