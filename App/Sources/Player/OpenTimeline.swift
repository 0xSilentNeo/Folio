import Foundation

/// What mpv did while a network file opened, read from its own log (1.23.2):
/// the connections it made (to which host, when), the demuxer's seeks, and
/// when the first picture came. Real-Debrid files took 9–10 s to open on the
/// phone (5 Nov report: 9919, 9009 and 8955 ms) but under 1 s in the
/// simulator against a lab server with Real-Debrid's measured delays (its
/// WebDAV host answers 0.74 s after a new connection from Melbourne), and
/// mpv's log only keeps the last file. This line, in the app's log, says
/// where the phone's seconds go. Host names only: never a path or a token.
enum OpenTimeline {
    struct Line { let time: Double; let module: String; let text: String }

    /// "[   0.774][d][ffmpeg] tcp: Starting connection attempt to 1.2.3.4 port 443"
    static func parse(_ line: Substring) -> Line? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let t = Double(line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)) else { return nil }
        var rest = line[line.index(after: close)...]
        guard rest.hasPrefix("["), let lvlEnd = rest.firstIndex(of: "]") else { return nil }
        rest = rest[rest.index(after: lvlEnd)...]
        guard rest.hasPrefix("["), let modEnd = rest.firstIndex(of: "]") else { return nil }
        let module = String(rest[rest.index(after: rest.startIndex)..<modEnd])
        let text = rest[rest.index(after: modEnd)...].trimmingCharacters(in: .whitespaces)
        return Line(time: t, module: module, text: text)
    }

    private static func host(_ url: Substring) -> String {
        URL(string: String(url))?.host ?? "?"
    }

    /// The end of mpv's log, at most `limit` bytes of it (1.30.2): the whole
    /// debug-level log was read and parsed for every network file opened,
    /// megabytes of it late in a session. Read leniently (a log can hold
    /// bytes that aren't UTF-8), from the first whole line.
    static func tail(of url: URL, limit: UInt64 = 512 * 1024) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return "" }
        let from = size > limit ? size - limit : 0
        guard (try? h.seek(toOffset: from)) != nil, let data = try? h.readToEnd() else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        guard from > 0 else { return text }
        // Cut mid-line: the rest of that line is left out.
        guard let nl = text.firstIndex(of: "\n") else { return "" }
        return String(text[text.index(after: nl)...])
    }

    /// The summary of the last open in `log` (mpv's log-file text), or nil
    /// when it has none.
    static func summary(_ log: String) -> String? {
        let lines = log.split(separator: "\n").compactMap(parse)
        // The last file opened: its "Opening <url>" from the stream layer.
        guard let start = lines.lastIndex(where: { ($0.module == "ffmpeg" || $0.module == "stream_callback" || $0.module == "stream") && $0.text.hasPrefix("Opening http") }) else { return nil }
        let t0 = lines[start].time
        var events: [String] = []
        var connections = 0
        var hosts: [String] = []
        func add(_ s: String, _ t: Double) { events.append(String(format: "%@ +%.2f", s, t - t0)) }
        for l in lines[start...] {
            let x = l.text
            if l.module == "ffmpeg", x.hasPrefix("tcp: Starting connection attempt to ") {
                connections += 1
                let addr = x.dropFirst("tcp: Starting connection attempt to ".count).split(separator: " ").first.map(String.init) ?? "?"
                hosts.append(addr)
                add("connect \(addr)", l.time)
            } else if l.module == "ffmpeg", x.hasPrefix("Opening http") {
                add("request to \(host(x.dropFirst("Opening ".count).split(separator: " ").first ?? ""))", l.time)
            } else if l.module == "ffmpeg", x.localizedCaseInsensitiveContains("redirect") || x.contains("Location") {
                add("redirect", l.time)
            } else if l.module == "mkv", x.hasPrefix("Deferring reading cues") {
                add("index deferred", l.time)
            } else if l.module == "mkv", x.localizedCaseInsensitiveContains("cues") || x.localizedCaseInsensitiveContains("seek") && !x.hasPrefix("Parsing seek head") {
                add("mkv: \(x.prefix(40))", l.time)
            } else if l.module == "demux", x.hasPrefix("Detected file format") {
                add("format known", l.time)
            } else if l.module == "cplayer", x.hasPrefix("Opening done") {
                add("opened", l.time)
            } else if l.module == "cplayer", x.hasPrefix("Starting playback") {
                add("decoders ready", l.time)
            } else if l.module == "cplayer", x.hasPrefix("first video frame") {
                add("first picture", l.time)
                break
            } else if l.module == "cplayer", x.hasPrefix("playback restart complete") {
                add("playing", l.time)
                break
            } else if l.module == "cache" || l.module == "stream", x.localizedCaseInsensitiveContains("seek") {
                add("\(l.module): \(x.prefix(40))", l.time)
            }
            if events.count >= 24 { events.append("…"); break }
        }
        return "open timeline: \(connections) connection(s)" + (hosts.isEmpty ? "" : " (\(Set(hosts).count) address(es))") + ": " + events.joined(separator: " · ")
    }
}

/// mpv's `vo-passes` (its render passes for a new frame, with GPU times in
/// nanoseconds) in one line: how many, their total, the slowest three.
enum RenderPasses {
    static func summary(_ json: String) -> String? {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let fresh = o["fresh"] as? [[String: Any]] else { return nil }
        func ms(_ v: Any?) -> Double { ((v as? NSNumber)?.doubleValue ?? 0) / 1_000_000 }
        let passes = fresh.map { (desc: ($0["desc"] as? String) ?? "?", avg: ms($0["avg"]), peak: ms($0["peak"])) }
        let total = passes.reduce(0) { $0 + $1.avg }
        let peak = passes.reduce(0) { $0 + $1.peak }
        let slowest = passes.sorted { $0.avg > $1.avg }.prefix(3)
            .map { String(format: "%@ %.2f ms", String($0.desc.prefix(48)), $0.avg) }
        let names = passes.map { String($0.desc.prefix(32)) }
        if total == 0 {
            // No GPU timer on this renderer: the passes' names still say what runs.
            return "\(passes.count) passes (no GPU timings): " + names.joined(separator: ", ")
        }
        return String(format: "%d passes, %.1f ms on average (peaks add up to %.1f ms); slowest: ", passes.count, total, peak) + slowest.joined(separator: ", ")
    }
}
