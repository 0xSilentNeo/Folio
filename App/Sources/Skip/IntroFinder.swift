import Foundation

/// The first minutes of a local file's sound, decoded for the intro finder
/// (1.30.0) by an mpv of its own: no picture, no subtitles, no window, and
/// its "sound output" is a file (`ao=pcm`), so nothing is played, the audio
/// session isn't touched, and the player's own mpv and Picture in Picture
/// never hear of it. mpv writes to a file as fast as it can decode.
enum IntroAudio {
    /// How much of a file is analysed, seconds.
    static let analysed = 600

    struct Sound {
        var fingerprint: [UInt16]
        /// Seconds of sound decoded.
        var seconds: Double
    }

    /// The fingerprint of the first `seconds` of `url`'s sound; nil when it
    /// couldn't be decoded or the task was cancelled. Never on the caller's
    /// thread: the decode runs on a utility queue.
    static func fingerprint(of url: URL, seconds: Int = analysed) async -> Sound? {
        let cancel = Flag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Sound?, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    c.resume(returning: fingerprintNow(of: url, seconds: seconds, cancelled: { cancel.isSet }))
                }
            }
        } onCancel: { cancel.set() }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
        func set() { lock.lock(); on = true; lock.unlock() }
    }

    /// Blocks until the sound is decoded: for a background queue only.
    static func fingerprintNow(of url: URL, seconds: Int, cancelled: () -> Bool) -> Sound? {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("intro-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        guard decode(url.path, to: wav.path, seconds: seconds, cancelled: cancelled), !cancelled(),
              let data = try? Data(contentsOf: wav, options: .mappedIfSafe),
              let pcm = samples(fromWAV: data) else { return nil }
        let fp = pcm.withUnsafeBufferPointer { IntroFingerprint.compute(pcm: $0) }
        return Sound(fingerprint: fp, seconds: Double(pcm.count) / Double(IntroFingerprint.sampleRate))
    }

    /// Runs an mpv over `path` that writes its first `seconds` of sound to
    /// `wav`: mono, 8 kHz, 16-bit. False when mpv couldn't, or was cancelled.
    static func decode(_ path: String, to wav: String, seconds: Int, cancelled: () -> Bool) -> Bool {
        setlocale(LC_NUMERIC, "C")
        guard let h = mpv_create() else { return false }
        let options: [(String, String)] = [
            // Nothing of the user's setup: no mpv.conf, scripts or key bindings.
            ("config", "no"), ("load-scripts", "no"), ("osc", "no"), ("ytdl", "no"), ("terminal", "no"),
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("msg-level", "all=no"),
            ("resume-playback", "no"), ("save-position-on-quit", "no"),
            ("vid", "no"), ("sid", "no"), ("audio-display", "no"), ("sub-auto", "no"), ("audio-file-auto", "no"),
            // Only the file output: with no fallback, a real output can never open.
            ("ao", "pcm"), ("ao-pcm-file", wav), ("ao-pcm-waveheader", "yes"),
            ("audio-channels", "mono"), ("audio-samplerate", String(IntroFingerprint.sampleRate)), ("audio-format", "s16"),
            ("end", String(seconds)), ("cache", "no"), ("demuxer-max-bytes", "8MiB"), ("demuxer-max-back-bytes", "1MiB"),
            ("demuxer-readahead-secs", "2"),
            // One decoding thread: it shares the phone with the film playing.
            ("ad-lavc-threads", "1"), ("idle", "yes"), ("keep-open", "no"),
        ]
        var aoSet = false
        for (name, value) in options {
            let r = mpv_set_option_string(h, name, value)
            if name == "ao" { aoSet = r >= 0 }
        }
        mpv_request_log_messages(h, "no")
        guard aoSet, mpv_initialize(h) >= 0 else {
            mpv_terminate_destroy(h)
            dlog("skip", "on device: this engine has no file sound output (ao=pcm \(aoSet ? "set" : "refused"))")
            return false
        }
        let command: [String] = ["loadfile", path]
        let words: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
        var args: [UnsafePointer<CChar>?] = words.map { UnsafePointer<CChar>($0) }
        args.append(nil)
        let loaded = mpv_command(h, &args)
        words.forEach { free($0) }
        var ok = false
        if loaded >= 0 {
            // A file that takes more than 3 minutes is given up on.
            let deadline = Date().addingTimeInterval(180)
            loop: while !cancelled(), Date() < deadline {
                guard let ev = mpv_wait_event(h, 0.25) else { continue }
                switch ev.pointee.event_id {
                case MPV_EVENT_END_FILE:
                    if let d = ev.pointee.data {
                        let end = d.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        ok = end.reason == MPV_END_FILE_REASON_EOF
                    }
                    break loop
                case MPV_EVENT_SHUTDOWN: break loop
                default: break
                }
            }
        }
        // Closes the file output, which completes the WAV, before returning.
        mpv_terminate_destroy(h)
        return ok
    }

    /// The samples of a WAV as mpv writes it: 16-bit (asked for), or 32-bit
    /// float if the engine kept its own format. Mono is asked for; more
    /// channels are averaged. The header's lengths aren't trusted (mpv fills
    /// them in last): the sound is everything after the "data" tag.
    static func samples(fromWAV data: Data) -> [Int16]? {
        guard data.count > 44, data.prefix(4) == Data("RIFF".utf8), data[data.startIndex + 8..<data.startIndex + 12] == Data("WAVE".utf8) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Int16]? in
            func u16(_ o: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) }
            func u32(_ o: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
            var at = 12, tag = 0, channels = 0, bits = 0, start = -1
            while at + 8 <= raw.count {
                let id = String(decoding: raw[at..<at + 4], as: UTF8.self), size = u32(at + 4)
                if id == "fmt ", at + 24 <= raw.count {
                    tag = u16(at + 8); channels = u16(at + 10); bits = u16(at + 22)
                    // "Extensible": the real format follows the 24 bytes of the plain one.
                    if tag == 0xFFFE, size >= 26, at + 34 <= raw.count { tag = u16(at + 32) }
                } else if id == "data" {
                    start = at + 8
                    break
                }
                at += 8 + size + (size & 1)
            }
            guard start > 0, channels > 0, (tag == 1 && bits == 16) || (tag == 3 && bits == 32) else { return nil }
            let width = bits / 8 * channels
            let count = (raw.count - start) / width
            var out = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                var sum: Float = 0
                for c in 0..<channels {
                    let o = start + i * width + c * (bits / 8)
                    if tag == 1 { sum += Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self))) }
                    else { sum += Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) * 32767 }
                }
                let v = sum / Float(channels)
                out[i] = v.isFinite ? Int16(max(-32768, min(32767, v))) : 0
            }
            return out
        }
    }
}

/// Finds a local episode's intro by comparing its sound with a neighbouring
/// episode's, and remembers fingerprints and results so each file is decoded
/// once (1.30.0). One analysis at a time. Nothing leaves the phone.
actor IntroFinder {
    static let shared = IntroFinder()

    struct Intro: Equatable { var start: Double; var end: Double }

    /// What is kept for one file, under its name, size and date.
    struct Entry: Codable {
        var fingerprint: Data
        var start: Double?
        var end: Double?
        /// Files it was compared with and no intro found: not tried again.
        var tried: [String] = []
        var used = Date()
    }

    /// At most this many files are remembered (about 13 KB each): the ones
    /// used longest ago go first.
    static let cap = 120

    private let file: URL
    private var entries: [String: Entry]?
    private var busy = false

    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IntroDetect", isDirectory: true).appendingPathComponent("intros.json")) {
        self.file = file
    }

    /// A file under its name, size and modification date: a replaced file is
    /// analysed again, a moved one isn't.
    static func key(for url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        return "\(url.lastPathComponent)|\(size)|\(Int(date.timeIntervalSince1970))"
    }

    /// Whether the finder may look at a file at all: a file in the app's own
    /// Documents (the Media library and downloads), named as an episode.
    nonisolated static func eligible(_ url: URL, documents: URL = MPVFiles.documents) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path, root = documents.standardizedFileURL.path
        guard path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return false }
        let p = TitleParser.parse(url.lastPathComponent)
        return p.episode != nil && p.extra == nil
    }

    /// Whether the phone has the energy to spare right now: not in Low Power
    /// Mode, and not warm.
    nonisolated static var phoneIsCool: Bool {
        !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState == .nominal
    }

    /// The intro already found for this file, if any. No decoding.
    func known(for url: URL) -> Intro? {
        guard let key = Self.key(for: url), let e = load()[key], let s = e.start, let end = e.end else { return nil }
        return Intro(start: s, end: end)
    }

    /// Whether `find` would have anything to do for this file: false once it
    /// has an intro, or has been compared with every neighbour it has.
    func worthTrying(_ url: URL) -> Bool {
        guard let key = Self.key(for: url) else { return false }
        let e = load()[key]
        if e?.start != nil { return false }
        return !candidates(for: url, tried: e?.tried ?? []).isEmpty
    }

    /// Decodes what isn't known yet (this file, one neighbour), compares,
    /// remembers. Returns this file's intro, or nil. Waits its turn when
    /// another analysis is running; gives up when its task is cancelled.
    func find(for url: URL) async -> Intro? {
        while busy {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return nil }
        }
        busy = true
        defer { busy = false }
        if let k = known(for: url) { return k }
        guard let key = Self.key(for: url) else { return nil }
        guard let other = candidates(for: url, tried: load()[key]?.tried ?? []).first, let otherKey = Self.key(for: other) else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        var decoded = 0
        func fingerprint(_ u: URL, _ k: String) async -> [UInt16]? {
            if let e = load()[k] { return Self.values(e.fingerprint) }
            guard let s = await IntroAudio.fingerprint(of: u) else { return nil }
            decoded += 1
            var all = load()
            all[k] = Entry(fingerprint: Self.data(s.fingerprint))
            entries = all
            return s.fingerprint
        }
        guard let a = await fingerprint(url, key), !Task.isCancelled, let b = await fingerprint(other, otherKey), !Task.isCancelled else {
            save()
            dlog("skip", "on device: \(url.lastPathComponent): sound not read (\(Task.isCancelled ? "cancelled" : "decode failed")) after \(Self.ms(t0)) ms")
            return nil
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let match = IntroMatcher.match(a, b)
        var all = load()
        if let m = match {
            all[key]?.start = m.startA; all[key]?.end = m.endA
            // The neighbour has its intro at once when it is played.
            if all[otherKey]?.start == nil { all[otherKey]?.start = m.startB; all[otherKey]?.end = m.endB }
        } else {
            all[key]?.tried.append(otherKey)
            all[otherKey]?.tried.append(key)
        }
        all[key]?.used = Date(); all[otherKey]?.used = Date()
        entries = all
        save()
        let found = match.map { String(format: "intro %.1f-%.1f s (the other %.1f-%.1f s, %.0f%% of bits differ)", $0.startA, $0.endA, $0.startB, $0.endB, $0.errorRate * 100) } ?? "no shared intro"
        dlog("skip", "on device: \(url.lastPathComponent) with \(other.lastPathComponent): \(found); decoded \(decoded) file(s) in \(Int((t1 - t0) * 1000)) ms, compared \(a.count)×\(b.count) frames in \(Self.ms(t1)) ms")
        return match.map { Intro(start: $0.startA, end: $0.endA) }
    }

    /// The neighbours to compare with, not yet tried: files of the same
    /// folder, finished (nothing written to them in the last two minutes).
    private func candidates(for url: URL, tried: [String]) -> [URL] {
        let folder = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return IntroNeighbours.of(url.lastPathComponent, among: names).map { folder.appendingPathComponent($0) }.filter { u in
            guard let k = Self.key(for: u), !tried.contains(k),
                  let date = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
            return Date().timeIntervalSince(date) > 120
        }
    }

    private static func ms(_ since: CFAbsoluteTime) -> Int { Int((CFAbsoluteTimeGetCurrent() - since) * 1000) }

    static func data(_ values: [UInt16]) -> Data {
        values.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func values(_ data: Data) -> [UInt16] {
        data.withUnsafeBytes { raw in
            (0..<raw.count / 2).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = read
        return read
    }

    private func save() {
        var all = load()
        if all.count > Self.cap {
            for (k, _) in all.sorted(by: { $0.value.used < $1.value.used }).prefix(all.count - Self.cap) { all[k] = nil }
            entries = all
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: file, options: .atomic) }
    }
}
