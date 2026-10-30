import Foundation
import os
import SwiftUI
import UIKit

/// Library, artwork and Discover trace: Settings → Help & Diagnostics →
/// Diagnostics → Trace library and images (or `-libTrace` at launch). Off by
/// default.
///
/// Each line goes to the unified log (subsystem dev.silentneo.glassplayer,
/// one category per area, signpost intervals for Instruments) and to app.log
/// as "[<category>] …", so a shared report has the whole timeline.
enum LibTrace {
    static var on: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.libTrace) || CommandLine.arguments.contains("-libTrace")
    }

    struct Channel: Sendable {
        let name: String
        let logger: Logger
        let signposter: OSSignposter

        init(_ name: String) {
            self.name = name
            logger = Logger(subsystem: PiPTrace.subsystem, category: name)
            signposter = OSSignposter(subsystem: PiPTrace.subsystem, category: name)
        }

        func log(_ message: @autoclosure () -> String) {
            guard LibTrace.on else { return }
            let line = message()
            logger.info("\(line, privacy: .public)")
            dlog(name, line)
        }

        func begin(_ interval: StaticString) -> OSSignpostIntervalState? {
            LibTrace.on ? signposter.beginInterval(interval, id: signposter.makeSignpostID()) : nil
        }

        func end(_ interval: StaticString, _ state: OSSignpostIntervalState?) {
            if let state { signposter.endInterval(interval, state) }
        }
    }

    /// Zoom transitions between Home and title pages: every zoom source, where
    /// it is and whether it can be seen.
    static let zoom = Channel("zoom")
    /// Artwork: which view asked, memory hit or miss, where the picture came from.
    static let image = Channel("image")
    /// Discover: provider pages, their tabs and catalog requests.
    static let discover = Channel("discover")
    /// Player panels: which row they open on.
    static let panel = Channel("panel")
    /// The WebDAV library index: each folder listed or kept, and why.
    static let index = Channel("index")
    /// Home's layout: the grid's width, columns and size, and where each
    /// entry sits in it.
    static let layout = Channel("layout")

    /// Milliseconds since `start`, for "… after N ms".
    static func ms(since start: CFTimeInterval) -> Int { Int((CACurrentMediaTime() - start) * 1000) }
}

/// A plain UIView behind each zoom source while the trace is on, so the log
/// can say where every source with an id is, and whether anything hides it
/// (a hidden list cell, a zero alpha, a transparent layer).
struct ZoomProbe: UIViewRepresentable {
    let id: AnyHashable

    final class Probe: UIView {
        var id: AnyHashable = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                ZoomProbe.live.add(self)
                LibTrace.zoom.log("source \(id) added at \(frameInWindow)")
            } else {
                ZoomProbe.live.remove(self)
                LibTrace.zoom.log("source \(id) removed from the window")
            }
        }

        var frameInWindow: CGRect { convert(bounds, to: nil).integral }

        /// The first view up the tree that hides it, or nil when nothing does.
        var hiddenBy: String? {
            var v: UIView? = self
            while let x = v {
                if x.isHidden { return "\(type(of: x)) isHidden" }
                let opacity = x.layer.presentation()?.opacity ?? x.layer.opacity
                if x.alpha < 0.01 || opacity < 0.01 {
                    return "\(type(of: x)) alpha \(String(format: "%.2f", x.alpha)) layer opacity \(String(format: "%.2f", opacity))"
                }
                v = x.superview
            }
            return nil
        }
    }

    @MainActor static let live = NSHashTable<Probe>.weakObjects()

    /// Every source registered under `id`, one line.
    @MainActor static func dump(_ id: AnyHashable, _ when: String) {
        guard LibTrace.on else { return }
        let list = live.allObjects.filter { $0.id == id && $0.window != nil }
        let parts = list.map { p in "\(p.frameInWindow) " + (p.hiddenBy.map { "hidden (\($0))" } ?? "visible") }
        LibTrace.zoom.log("\(when): \(list.count) source(s) for \(id)" + (parts.isEmpty ? "" : ": " + parts.joined(separator: "; ")))
    }

    /// `dump` every 100 ms for `seconds` (a page going back and after).
    @MainActor static func timeline(_ id: AnyHashable, _ what: String, seconds: Double = 2.5) {
        guard LibTrace.on else { return }
        let start = CACurrentMediaTime()
        for i in 0...Int(seconds * 10) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                MainActor.assumeIsolated { dump(id, "\(what) +\(LibTrace.ms(since: start)) ms") }
            }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let p = Probe()
        p.id = id
        p.isUserInteractionEnabled = false
        return p
    }

    func updateUIView(_ uiView: Probe, context: Context) { uiView.id = id }
}

/// Trace (library and images): where an entry sits in Home's grid (the
/// grid's own coordinate space, so scrolling doesn't log), each time that
/// changes.
struct GridProbe: ViewModifier {
    let name: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if LibTrace.on {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(GridProbe.space)).integral }) { r in
                LibTrace.layout.log("\(name) at (\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height)))")
            }
        } else {
            content
        }
    }

    static let space = "homeGrid"
}
