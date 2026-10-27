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
    var playing = false
    var note = ""

    func start() {
        mainThread = pthread_mach_thread_np(pthread_self())   // called on the main thread
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sample(reason: "thermal change")
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.schedule() })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sample(reason: "going to background")
            self?.timer?.invalidate(); self?.timer = nil
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

    /// One line now (also used by the player when a file starts/stops).
    func sample(reason: String?) {
        let threads = threadUsage()
        let total = threads.reduce(0) { $0 + $1.1 }
        let top = threads.sorted { $0.1 > $1.1 }.prefix(5).filter { $0.1 >= 0.5 }
            .map { String(format: "%@ %.0f%%", $0.0, $0.1) }.joined(separator: ", ")
        var line = String(format: "cpu %.0f%%", total)
        if !top.isEmpty { line += " (\(top))" }
        line += " \(Self.memory) thermal=\(Self.thermal) playing=\(playing ? "yes" : "no")"
        if ProcessInfo.processInfo.isLowPowerModeEnabled { line += " lowPower" }
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
