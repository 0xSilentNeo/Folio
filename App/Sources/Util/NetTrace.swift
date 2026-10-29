import Foundation

/// Timing of addon requests, from URLSession's own measurements
/// (URLSessionTaskMetrics): how long a request waited before it went out,
/// DNS, connection, TLS, the wait for the first byte of the answer, and the
/// body. Shows whether a request is slow at the server, queued, or failing to
/// connect. Lines go to app.log as "[net] …".
///
/// Failures and answers slower than 5 s are always logged; every request
/// when Settings → Help & Diagnostics → Diagnostics → Trace network requests
/// is on. Addresses are cut to the host and the addon resource ("…/stream/
/// series/tt….json"): the part in between holds the addon's settings and
/// keys.
enum NetTrace {
    static var on: Bool { UserDefaults.standard.bool(forKey: SettingsKey.netTrace) }

    /// Collects the metrics of one request (per-task delegate).
    final class Timer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _metrics: URLSessionTaskMetrics?
        var metrics: URLSessionTaskMetrics? { lock.lock(); defer { lock.unlock() }; return _metrics }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.lock(); _metrics = metrics; lock.unlock()
        }
    }

    private static let lock = NSLock()
    private static var inFlight: [String: Int] = [:]

    /// Marks a request to `host` as started; returns how many were already
    /// out to that host.
    static func begin(_ host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = inFlight[host, default: 0]
        inFlight[host] = n + 1
        return n
    }

    static func end(_ host: String) {
        lock.lock(); inFlight[host] = max(0, inFlight[host, default: 1] - 1); lock.unlock()
    }

    /// Host plus the addon resource, never the settings in between.
    static func short(_ url: URL) -> String {
        let p = url.path
        for marker in ["/stream/", "/catalog/", "/meta/", "/subtitles/", "/manifest.json"] {
            if let r = p.range(of: marker) { return (url.host ?? "?") + " …" + p[r.lowerBound...] }
        }
        return (url.host ?? "?") + " …/" + url.lastPathComponent.prefix(24)
    }

    static func report(_ kind: String, url: URL, others: Int, started: CFAbsoluteTime, timer: Timer, status: Int?, bytes: Int?, error: Error?) {
        let total = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        guard on || error != nil || total > 5000 || (status.map { !(200..<300).contains($0) } ?? false) else { return }
        var head = "\(kind) \(short(url))"
        if let error {
            let e = error as NSError
            head += " → failed (\(e.domain) \(e.code): \(e.localizedDescription))"
        } else {
            head += " → HTTP \(status ?? 0), \(bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?")"
        }
        head += " in \(total) ms; \(others) other request(s) to this host already out"
        dlog("net", head + phases(timer.metrics))
    }

    /// "; queued 3 ms, DNS 21, connect 40, TLS 61, waited for the answer 8040, body 120; h2, new connection".
    private static func phases(_ m: URLSessionTaskMetrics?) -> String {
        guard let m, let t = m.transactionMetrics.last else { return "; no timing from URLSession" }
        func ms(_ a: Date?, _ b: Date?) -> String { guard let a, let b else { return "-" }; return String(Int(b.timeIntervalSince(a) * 1000)) }
        var parts: [String] = []
        let firstStep = t.domainLookupStartDate ?? t.connectStartDate ?? t.requestStartDate
        parts.append("queued \(ms(t.fetchStartDate, firstStep)) ms")
        if t.domainLookupStartDate != nil { parts.append("DNS \(ms(t.domainLookupStartDate, t.domainLookupEndDate))") }
        if t.connectStartDate != nil { parts.append("connect \(ms(t.connectStartDate, t.connectEndDate))") }
        if t.secureConnectionStartDate != nil { parts.append("TLS \(ms(t.secureConnectionStartDate, t.secureConnectionEndDate))") }
        if t.requestStartDate != nil {
            if t.responseStartDate != nil {
                parts.append("waited for the answer \(ms(t.requestEndDate ?? t.requestStartDate, t.responseStartDate))")
                parts.append("body \(ms(t.responseStartDate, t.responseEndDate))")
            } else {
                parts.append("request sent, no answer")
            }
        } else {
            parts.append("request never sent")
        }
        let how = [t.networkProtocolName, t.isReusedConnection ? "reused connection" : "new connection",
                   t.resourceFetchType == .localCache ? "from cache" : nil, m.redirectCount > 0 ? "\(m.redirectCount) redirect(s)" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        return "; " + parts.joined(separator: ", ") + (how.isEmpty ? "" : "; " + how)
    }
}
