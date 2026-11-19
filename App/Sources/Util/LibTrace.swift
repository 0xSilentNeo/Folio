import Foundation
import os
import SwiftUI
import UIKit

/// Library, artwork and Discover trace: Settings → Help & Diagnostics →
/// Diagnostics → Trace library and images (or `-libTrace` at launch). Off by
/// default.
///
/// Each line goes to the unified log (subsystem: the app's bundle ID,
/// one category per area, signpost intervals for Instruments) and to app.log
/// as "[<category>] …", so a shared report has the whole timeline.
enum LibTrace {
    /// From TraceFlags' copy (0.90.0): this read the setting and looked
    /// through the launch arguments on every call, and every tile drawn and
    /// every line traced calls it.
    static var on: Bool { TraceFlags.lib }

    struct Channel: Sendable {
        let name: String
        let logger: Logger
        let signposter: OSSignposter

        init(_ name: String) {
            self.name = name
            logger = Logger(subsystem: PiPTrace.subsystem, category: name)
            signposter = OSSignposter(subsystem: PiPTrace.subsystem, category: name)
        }

        /// To the unified log at debug level (0.90.0): nothing is done for
        /// it unless something is reading the log live (Xcode, Console with
        /// debug messages shown, Instruments). At info level every line was
        /// also kept in the system's own log, a second write for each one.
        /// app.log has every line as before.
        func log(_ message: @autoclosure () -> String) {
            guard LibTrace.on else { return }
            let line = message()
            logger.debug("\(line, privacy: .public)")
            dlog(name, line)
        }

        func begin(_ interval: StaticString) -> OSSignpostIntervalState? {
            LibTrace.on ? signposter.beginInterval(interval, id: signposter.makeSignpostID()) : nil
        }

        func end(_ interval: StaticString, _ state: OSSignpostIntervalState?) {
            if let state { signposter.endInterval(interval, state) }
        }

        /// A point on the signpost lane (and the line in the log).
        func event(_ name: StaticString, _ message: @autoclosure () -> String) {
            guard LibTrace.on else { return }
            let line = message()
            signposter.emitEvent(name, "\(line, privacy: .public)")
            logger.debug("\(line, privacy: .public)")
            dlog(self.name, line)
        }
    }

    // MARK: A scroll, as one line

    private final class Scroll {
        var from = 0, to = 0, steps = 0
        var start: CFTimeInterval = 0
        var task: DispatchWorkItem?
    }
    @MainActor private static var scrolls: [String: Scroll] = [:]

    /// A scroll view's moves as one line, written once it has rested for
    /// 0.3 s (0.90.0): "now playing offset 0 → 1840 (212 steps in 1900 ms)".
    /// A line a move was a line a frame for as long as a finger was on the
    /// panel. Where it started, where it came to rest and how long it took
    /// are what the line was for.
    @MainActor static func scrolled(_ label: String, from old: Int, to new: Int) {
        guard on else { return }
        let s = scrolls[label] ?? Scroll()
        if s.task == nil { s.from = old; s.steps = 0; s.start = CACurrentMediaTime() }
        s.to = new
        s.steps += 1
        s.task?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let s = scrolls.removeValue(forKey: label) else { return }
                // Less the 0.3 s it waited to see the scroll had stopped.
                let took = max(0, ms(since: s.start) - 300)
                panel.log("\(label) offset \(s.from) → \(s.to) (\(s.steps) step\(s.steps == 1 ? "" : "s") in \(took) ms)")
            }
        }
        s.task = work
        scrolls[label] = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
    /// Title pages: opening one (an event), its data loading (an interval),
    /// and the page appearing (an event), for Instruments' os_signpost lane.
    static let title = Channel("title")

    /// Milliseconds since `start`, for "… after N ms".
    static func ms(since start: CFTimeInterval) -> Int { Int((CACurrentMediaTime() - start) * 1000) }
}

/// The three trace switches and whether the screen is being recorded, kept
/// in memory (0.90.0). `LibTrace.on`, `PiPTrace.on` and `NetTrace.on` each
/// read UserDefaults on every call: with all three left on ("keep on until
/// I turn them off") that was a settings read for every tile drawn, every
/// request and every line. The copy is read again when any setting changes.
enum TraceFlags {
    struct Values: Equatable, Sendable {
        var lib = false
        var net = false
        var pip = false
        /// The screen is being recorded or mirrored.
        var captured = false
    }

    /// `-libTrace` at launch; the arguments don't change.
    private static let libArgument = CommandLine.arguments.contains("-libTrace")

    private static let box: OSAllocatedUnfairLock<Values> = {
        let box = OSAllocatedUnfairLock(initialState: stored(captured: false))
        let nc = NotificationCenter.default
        // On the thread that wrote the setting, never the main queue: with
        // queue .main a write from another thread waits for the main thread,
        // which froze Folio at launch before 1.30.6 (TraceExpiry.watch).
        // Three reads and a compare; this fires for every setting.
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in TraceFlags.refresh() }
        // UIKit posts this on the main thread.
        nc.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: nil) { _ in
            if Thread.isMainThread { MainActor.assumeIsolated { TraceFlags.noteCapture() } }
            else { DispatchQueue.main.async { MainActor.assumeIsolated { TraceFlags.noteCapture() } } }
        }
        // The screen's state is the main thread's to read: after this, when
        // the first look came from another thread.
        DispatchQueue.main.async { MainActor.assumeIsolated { TraceFlags.noteCapture() } }
        return box
    }()

    private static func stored(captured: Bool) -> Values {
        let d = UserDefaults.standard
        return Values(lib: d.bool(forKey: SettingsKey.libTrace) || libArgument, net: d.bool(forKey: SettingsKey.netTrace),
                      pip: d.bool(forKey: SettingsKey.pipTrace), captured: captured)
    }

    /// Reads the switches again. Inside the lock, so of two threads the one
    /// that reads last also writes last; reading a setting calls nothing of Folio's.
    static func refresh() {
        box.withLock { v in
            let new = stored(captured: v.captured)
            if new != v { v = new }
        }
    }

    static var values: Values { box.withLock { $0 } }
    static var lib: Bool { box.withLock { $0.lib } }
    static var net: Bool { box.withLock { $0.net } }
    static var pip: Bool { box.withLock { $0.pip } }
    /// The screen is being recorded or mirrored.
    static var captured: Bool { box.withLock { $0.captured } }

    /// Whether the per-tile lines are written: the library trace is on and
    /// the screen isn't being recorded.
    ///
    /// Paused while recording (0.90.0): a source added or removed for every
    /// tile that scrolls by, each tile's place in the grid, and all but the
    /// first and last look at a zoom's sources. The recorder already takes
    /// a good part of the phone, these are the lines that come by the
    /// hundred while scrolling, and what they say (where each tile is, and
    /// whether it can be seen) is what the recording shows. Everything
    /// tied to something that happened stays: a page opening and closing
    /// with its sources, artwork, Discover, the panel, the index, requests
    /// and Picture in Picture.
    static var perTile: Bool { let v = values; return v.lib && !v.captured }

    @MainActor private static var paused = false

    /// The screen began or stopped being recorded: kept, and said once each way.
    @MainActor static func noteCapture() {
        let now = UIScreen.main.isCaptured
        box.withLock { $0.captured = now }
        let v = values
        let pause = now && (v.lib || v.pip)
        guard pause != paused else { return }
        paused = pause
        dlog("trace", pause ? "paused while the screen is recorded: no line per tile and no frame timing; the rest goes on" : "resumed: the screen isn't recorded any more")
    }

    /// For the tests: what the screen's state is taken to be.
    static func setCaptured(_ on: Bool) { box.withLock { $0.captured = on } }
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
            // Not said while the screen is recorded (0.90.0, TraceFlags.perTile):
            // two lines for every tile that scrolls by. Still kept in
            // `live`, so a page opening or closing lists its sources.
            if window != nil {
                ZoomProbe.live.add(self)
                if TraceFlags.perTile { LibTrace.zoom.log("source \(id) added at \(frameInWindow)") }
            } else {
                ZoomProbe.live.remove(self)
                if TraceFlags.perTile { LibTrace.zoom.log("source \(id) removed from the window") }
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

    /// `dump` every 250 ms for `seconds` (a page going back and after);
    /// every 100 ms until 1.24.1, 26 walks of every probe's views during a zoom.
    @MainActor static func timeline(_ id: AnyHashable, _ what: String, seconds: Double = 2.5) {
        guard LibTrace.on else { return }
        let start = CACurrentMediaTime()
        let last = Int(seconds * 4)
        for i in 0...last {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) {
                MainActor.assumeIsolated {
                    // While the screen is recorded (0.90.0): the first and
                    // the last look only, not all 11.
                    guard i == 0 || i == last || !TraceFlags.captured else { return }
                    dump(id, "\(what) +\(LibTrace.ms(since: start)) ms")
                }
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
    /// Where the view is in the window, not in its grid row (a whole row).
    var inWindow = false

    /// The last place seen, logged once it has held for 0.3 s (1.24.1): rows
    /// outside the grid (List and Details) have no "homeGrid" space, so their
    /// place changed on every scrolled frame and logged two lines each time
    /// (6 Nov report: 254 pairs in 3 s, each a UserDefaults read and a date
    /// format on the main thread). A box, so noting it doesn't redraw.
    @State private var pending = Pending()
    final class Pending { var task: DispatchWorkItem? }

    @ViewBuilder
    func body(content: Content) -> some View {
        if LibTrace.on {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: inWindow ? .global : .named(GridProbe.space)).integral }) { r in
                pending.task?.cancel()
                // Not while the screen is recorded (0.90.0, TraceFlags.perTile).
                guard TraceFlags.perTile else { return }
                let name = name
                let work = DispatchWorkItem {
                    LibTrace.layout.log("\(name) at (\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height)))")
                }
                pending.task = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        } else {
            content
        }
    }

    static let space = "homeGrid"
}

/// Diagnostic traces switch themselves off a day after they were turned on
/// (1.28.8). The 11 Nov report had all three on from an earlier hunt: they
/// log every tile that scrolls by, sample the picture 120 times a second
/// around each trip away, and save screenshots, all of which costs battery
/// long after the question they were turned on for was answered.
enum TraceExpiry {
    static let keys = [SettingsKey.libTrace, SettingsKey.netTrace, SettingsKey.pipTrace]
    static let life: TimeInterval = 86400

    private static func stamp(_ key: String) -> String { "traceOnSince." + key }

    /// At launch, and whenever a setting changes: each trace that's on has
    /// the time it was turned on, and one on for over a day goes off.
    /// Stamped as it's switched (1.28.10), not only at launch: a trace
    /// turned off and on again days later died at the next launch, just
    /// when it was wanted. `now` and `defaults` are parameters for the tests.
    @discardableResult
    static func check(now: Date = Date(), defaults d: UserDefaults = .standard) -> Bool {
        var ended: [String] = []
        for k in keys {
            guard d.bool(forKey: k) else {
                if d.object(forKey: stamp(k)) != nil { d.removeObject(forKey: stamp(k)) }
                continue
            }
            guard let since = d.object(forKey: stamp(k)) as? Date else { d.set(now, forKey: stamp(k)); continue }
            if now.timeIntervalSince(since) > life {
                d.removeObject(forKey: stamp(k))
                d.set(false, forKey: k)
                ended.append(k)
            }
        }
        if !ended.isEmpty { dlog("app", "diagnostic traces on for over a day: turned off (\(ended.joined(separator: ", ")))") }
        return !ended.isEmpty
    }

    /// Watches the switches, so each is stamped when it's turned on.
    static func watch() {
        check()
        // On the thread that wrote the setting, not the main queue (1.30.6):
        // with queue .main, every write from another thread waited for the
        // main thread to run this. On a fresh install the library metadata
        // is first opened off the main thread and writes a setting as it
        // starts (MetadataService.init), while the main thread waited for
        // that same start (ThumbLoader): Folio froze at launch. The look
        // is cheap and thread-safe; only a change goes to the main thread.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            // Only when a stamp is missing or left over: this fires for every setting.
            let d = UserDefaults.standard
            if keys.contains(where: { d.bool(forKey: $0) != (d.object(forKey: stamp($0)) != nil) }) {
                DispatchQueue.main.async { check() }
            }
        }
    }
}
