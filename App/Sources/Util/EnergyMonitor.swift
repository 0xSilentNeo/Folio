import Foundation
import UIKit
import Darwin
import os

/// Where the power goes: our own process's CPU time, split by thread name,
/// plus the thermal state, as one log line every 30 s while the app is in
/// front (and at once when the thermal state changes). Reading thread times
/// costs microseconds; it is only ever a diagnosis aid.
///
///   [energy] cpu 23% (main 4%, mpv/vo 11%, mpv/vd 6%, audio 1%) thermal=fair playing=yes
final class EnergyMonitor {
    static let shared = EnergyMonitor()
    private var timer: Timer?
    private var mainThread: thread_t = 0
    private var observers: [NSObjectProtocol] = []
    /// Set by the player while a file plays, so the line says what the load is for.
    var playing = false { didSet { if playing != oldValue { updateNet() } } }
    var note = ""

    /// Bytes received per 2-s slot while a file plays (1.30.4): bursts let
    /// the radio sleep between them, a trickle keeps it up all film.
    private var netTimer: Timer?
    private var netLast: (cell: UInt32, wifi: UInt32)?
    private var netLastAt: CFTimeInterval = 0
    private var netCell: [UInt64] = []
    private var netWifi: [UInt64] = []
    private var netSeconds: Double = 0

    func start() {
        mainThread = pthread_mach_thread_np(pthread_self())   // called on the main thread
        // Battery level in each line (1.30.1): a report could say how hard the
        // app worked but not what a session cost the battery.
        UIDevice.current.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sample(reason: "thermal change")
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.schedule() })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sample(reason: "going to background")
            self?.timer?.invalidate(); self?.timer = nil
            self?.updateNet()
        })
        observers.append(nc.addObserver(forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            dlog("energy", "low power mode \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
        })
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.sample(reason: nil) }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updateNet()
    }

    /// The 2-s sampling runs while a file plays with Folio in front (the
    /// line it feeds is only written then).
    private func updateNet() {
        let want = playing && timer != nil
        if want, netTimer == nil {
            netLast = NetSlots.counters()
            netLastAt = CACurrentMediaTime()
            netCell = []; netWifi = []; netSeconds = 0
            let t = Timer(timeInterval: NetSlots.slot, repeats: true) { [weak self] _ in self?.netTick() }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            netTimer = t
        } else if !want, let t = netTimer {
            t.invalidate()
            netTimer = nil
            netLast = nil
        }
    }

    private func netTick() {
        let now = NetSlots.counters(), at = CACurrentMediaTime()
        if let last = netLast {
            // 32-bit counters: the difference wraps with them.
            netCell.append(UInt64(now.cell &- last.cell))
            netWifi.append(UInt64(now.wifi &- last.wifi))
            netSeconds += at - netLastAt
        }
        netLast = now
        netLastAt = at
    }

    /// The app's memory footprint (what iOS counts against its limit) and
    /// how much more it may use before iOS ends it. 27 Oct: three memory
    /// warnings, then the app was gone with no crash record — iOS had ended
    /// it for memory; the log had no numbers to say what was using it.
    static var memory: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        let used = kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
        let left = Int(os_proc_available_memory() / 1_048_576)
        return "mem \(used) MB (\(left) MB left)"
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "?"
        }
    }

    /// The battery's level and state, the screen's brightness and how far
    /// above SDR white it is showing HDR (1.30.1): the screen is usually the
    /// largest draw while a video plays, and none of it shows in the app's
    /// own CPU time. Main thread (UIDevice, UIScreen).
    static var power: String {
        var out = ""
        let d = UIDevice.current
        if d.batteryLevel >= 0 {
            let state: String
            switch d.batteryState {
            case .charging: state = " charging"; case .full: state = " full"; default: state = ""
            }
            out += String(format: " battery=%.0f%%%@", d.batteryLevel * 100, state)
        }
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first ?? UIScreen.main
        out += String(format: " brightness=%.0f%%", screen.brightness * 100)
        if screen.currentEDRHeadroom > 1.01 { out += String(format: " hdr=%.1f×", screen.currentEDRHeadroom) }
        return out
    }

    /// One line now (also used by the player when a file starts/stops).
    func sample(reason: String?) {
        let threads = threadUsage()
        let total = threads.reduce(0) { $0 + $1.1 }
        let top = threads.sorted { $0.1 > $1.1 }.prefix(5).filter { $0.1 >= 0.5 }
            .map { String(format: "%@ %.0f%%", $0.0, $0.1) }.joined(separator: ", ")
        var line = String(format: "cpu %.0f%%", total)
        if !top.isEmpty { line += " (\(top))" }
        line += " \(Self.memory) thermal=\(Self.thermal) playing=\(playing ? "yes" : "no")"
        line += Self.power
        if ProcessInfo.processInfo.isLowPowerModeEnabled { line += " lowPower" }
        if netTimer != nil {
            if let net = NetSlots.line(cell: netCell, wifi: netWifi, seconds: netSeconds) { line += " " + net }
            netCell = []; netWifi = []; netSeconds = 0
        }
        if !note.isEmpty { line += " " + note }
        if let reason { line += " · \(reason)" }
        dlog("energy", line)
    }

    /// Current CPU share of every thread of this process, by name, in percent
    /// of one core (Mach's running average over the last ~second).
    private func threadUsage() -> [(String, Double)] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride))
        }
        var byName: [String: Double] = [:]
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount) }
            }
            guard kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            let pct = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            guard pct > 0 else { continue }
            byName[name(of: list[i]), default: 0] += pct
        }
        return byName.map { ($0.key, $0.value) }
    }

    private func name(of t: thread_t) -> String {
        if t == mainThread { return "main" }
        if let p = pthread_from_mach_thread_np(t) {
            var buf = [CChar](repeating: 0, count: 64)
            if pthread_getname_np(p, &buf, buf.count) == 0 {
                let s = String(cString: buf)
                if !s.isEmpty { return Self.shortName(s) }
            }
        }
        return "other"
    }

    private static func shortName(_ s: String) -> String {
        if s.hasPrefix("com.apple.main-thread") { return "main" }
        if s.contains("WebKit") || s.contains("WebCore") || s.contains("JavaScriptCore") { return "webkit" }
        if s.contains("AudioUnit") || s.contains("AURemoteIO") || s.hasPrefix("com.apple.audio") || s.contains("caulk") { return "audio" }
        if s.contains("coreanimation") || s.contains("CA::") { return "coreanimation" }
        if s.hasPrefix("com.apple.NSURLSession") || s.hasPrefix("com.apple.CFNetwork") { return "network" }
        if s.hasPrefix("com.apple.root") || s.hasPrefix("com.apple.coremedia") { return "gcd" }
        return s.count > 18 ? String(s.prefix(18)) : s
    }
}

/// What the radios received (1.30.4), from the interfaces' counters: the
/// whole phone's, nearly all Folio's while a video plays.
enum NetSlots {
    /// One slot, in seconds.
    static let slot: TimeInterval = 2
    /// Less than this in a slot is quiet: keep-alives, a full TCP window's probes.
    static let busyBytes: UInt64 = 64 * 1024

    /// "net cellular 26.4 Mb/s (data in 15 of 15 2-s slots)": a stream that
    /// keeps the radio up has data in every slot; read in bursts, in a few.
    /// Nil when neither received anything worth saying.
    static func line(cell: [UInt64], wifi: [UInt64], seconds: Double) -> String? {
        guard seconds > 0 else { return nil }
        var parts: [String] = []
        for (name, slots) in [("cellular", cell), ("Wi-Fi", wifi)] {
            let total = slots.reduce(0, +)
            guard total >= busyBytes else { continue }
            let mbps = Double(total) * 8 / 1_000_000 / seconds
            let busy = slots.filter { $0 >= busyBytes }.count
            parts.append(String(format: "%@ %.1f Mb/s (data in %ld of %ld %.0f-s slots)", name, mbps, busy, slots.count, slot))
        }
        return parts.isEmpty ? nil : "net " + parts.joined(separator: ", ")
    }

    /// Bytes received so far: cellular (pdp_ip*) and Wi-Fi (en0). 32-bit
    /// counters, which wrap: only their differences mean anything.
    static func counters() -> (cell: UInt32, wifi: UInt32) {
        var cell: UInt32 = 0, wifi: UInt32 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (0, 0) }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            let i = a.pointee
            p = i.ifa_next
            guard let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = i.ifa_data, let cname = i.ifa_name else { continue }
            let name = String(cString: cname)
            let received = data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes
            if name.hasPrefix("pdp_ip") {
                cell = cell &+ received
            } else if name == "en0" {
                wifi = wifi &+ received
            }
        }
        return (cell, wifi)
    }
}
