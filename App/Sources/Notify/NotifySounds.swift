import AVFoundation
import UserNotifications

/// The sound of each group's notifications (1.25.0).
///
/// iOS plays a notification's own sound only from the app's bundle or its
/// Library/Sounds folder, as aiff, wav or caf (Linear PCM, IMA4, µLaw or
/// aLaw), under 30 seconds; a longer one plays the default sound instead
/// (Apple, UNNotificationSound). So:
/// - Folio's sounds are made for it and ship in the app;
/// - Apple's alert tones (Tri-tone, Chime, Bloom…) are read from this
///   iPhone's own system folder and copied into Library/Sounds when picked.
///   That folder isn't a documented API, so the list shows only what this
///   iPhone actually lets Folio read;
/// - a sound from Files is converted to caf and cut to 29 seconds.
enum NotifySound: Equatable, Hashable {
    case standard
    case none
    case folio(String)      // file stem in the app's sounds folder
    case apple(String)      // path under UISounds, e.g. "New/Bloom.caf"
    case custom(String)     // file name in Library/Sounds

    init(_ s: String) {
        if s == "none" { self = .none; return }
        if s.hasPrefix("folio:") { self = .folio(String(s.dropFirst(6))); return }
        if s.hasPrefix("apple:") { self = .apple(String(s.dropFirst(6))); return }
        if s.hasPrefix("custom:") { self = .custom(String(s.dropFirst(7))); return }
        self = .standard
    }

    var stored: String {
        switch self {
        case .standard: return "default"
        case .none: return "none"
        case .folio(let n): return "folio:" + n
        case .apple(let p): return "apple:" + p
        case .custom(let n): return "custom:" + n
        }
    }

    var label: String {
        switch self {
        case .standard: return "Default"
        case .none: return "None"
        case .folio(let n): return NotifySounds.display(n)
        case .apple(let p): return NotifySounds.appleName(p)
        case .custom(let n): return NotifySounds.display((n as NSString).deletingPathExtension.replacingOccurrences(of: "custom-", with: ""))
        }
    }
}

enum NotifySounds {
    static var librarySounds: URL {
        let u = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func choice(for g: NotifyGroup) -> NotifySound {
        let all = UserDefaults.standard.dictionary(forKey: SettingsKey.notifySounds) as? [String: String] ?? [:]
        return NotifySound(all[g.rawValue] ?? "default")
    }

    static func set(_ s: NotifySound, for g: NotifyGroup) {
        var all = UserDefaults.standard.dictionary(forKey: SettingsKey.notifySounds) as? [String: String] ?? [:]
        all[g.rawValue] = s.stored
        UserDefaults.standard.set(all, forKey: SettingsKey.notifySounds)
        _ = file(for: s)
    }

    /// The sound a group's notification plays (nil: silent).
    static func sound(for g: NotifyGroup) -> UNNotificationSound? {
        let c = choice(for: g)
        switch c {
        case .standard: return .default
        case .none: return nil
        default:
            guard let f = file(for: c) else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(f.lastPathComponent))
        }
    }

    /// The sound's file in Library/Sounds, copied there first if needed.
    @discardableResult
    static func file(for s: NotifySound) -> URL? {
        let fm = FileManager.default
        switch s {
        case .standard, .none: return nil
        case .folio(let n):
            let dest = librarySounds.appendingPathComponent("folio-\(n).caf")
            if !fm.fileExists(atPath: dest.path), let src = folioURL(n) { try? fm.copyItem(at: src, to: dest) }
            return fm.fileExists(atPath: dest.path) ? dest : nil
        case .apple(let p):
            let dest = librarySounds.appendingPathComponent("apple-" + ((p as NSString).lastPathComponent))
            if !fm.fileExists(atPath: dest.path) {
                let src = URL(fileURLWithPath: appleRoot).appendingPathComponent(p)
                do { try fm.copyItem(at: src, to: dest) } catch { dlog("notify", "Apple's sound \(p) not copied: \(error.localizedDescription)") }
            }
            return fm.fileExists(atPath: dest.path) ? dest : nil
        case .custom(let n):
            let u = librarySounds.appendingPathComponent(n)
            return fm.fileExists(atPath: u.path) ? u : nil
        }
    }

    /// Where a sound can be heard before picking it.
    static func previewURL(_ s: NotifySound) -> URL? {
        switch s {
        case .folio(let n): return folioURL(n)
        case .apple(let p): return URL(fileURLWithPath: appleRoot).appendingPathComponent(p)
        case .custom: return file(for: s)
        default: return nil
        }
    }

    // MARK: Folio's

    static func folioURL(_ n: String) -> URL? {
        Bundle.main.url(forResource: n, withExtension: "caf", subdirectory: "sounds")
    }

    static var folio: [String] {
        guard let dir = Bundle.main.url(forResource: "sounds", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { $0.hasSuffix(".caf") }.map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    static func display(_ stem: String) -> String {
        stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }

    // MARK: Apple's

    /// The system's alert sounds folder (in the simulator, inside its runtime).
    static var appleRoot: String {
        (ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? "") + "/System/Library/Audio/UISounds"
    }

    /// The classic text tones' files (names as The Apple Wiki's UISounds list gives them).
    static let classic: [(file: String, name: String)] = [
        ("sms-received1.caf", "Tri-tone"), ("sms-received2.caf", "Chime"), ("sms-received3.caf", "Glass"),
        ("sms-received4.caf", "Horn"), ("sms-received5.caf", "Bell"), ("sms-received6.caf", "Electronic"),
    ]

    static func appleName(_ path: String) -> String {
        let f = (path as NSString).lastPathComponent
        if let c = classic.first(where: { $0.file == f }) { return c.name }
        return display((f as NSString).deletingPathExtension)
    }

    /// Apple's tones this iPhone lets Folio read: the classic six, then the
    /// "New" folder's (Anticipate, Bloom, Calypso…). Empty when it can't.
    static var apple: [String] {
        let fm = FileManager.default
        let root = appleRoot
        var out = classic.map(\.file).filter { fm.isReadableFile(atPath: root + "/" + $0) }
        if let more = try? fm.contentsOfDirectory(atPath: root + "/New") {
            out += more.filter { $0.hasSuffix(".caf") && fm.isReadableFile(atPath: root + "/New/" + $0) }.sorted().map { "New/" + $0 }
        }
        return out
    }

    // MARK: From Files

    /// Converts an audio file to a caf Library/Sounds can play from,
    /// cut to 29 seconds. Returns its file name.
    static func importSound(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let stem = url.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -_")).inverted).joined()
        let name = "custom-\(stem.isEmpty ? "sound" : String(stem.prefix(40))).caf"
        let dest = librarySounds.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: min(2, format.channelCount), AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let maxFrames = AVAudioFramePosition(29 * format.sampleRate)
        var written: AVAudioFramePosition = 0
        let chunk: AVAudioFrameCount = 8192
        while written < min(input.length, maxFrames) {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), min(input.length, maxFrames) - written))
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
            try input.read(into: buf, frameCount: n)
            if buf.frameLength == 0 { break }
            try output.write(from: buf)
            written += AVAudioFramePosition(buf.frameLength)
        }
        dlog("notify", "sound imported: \(name), \(Int(Double(written) / format.sampleRate)) s")
        return name
    }

    static var custom: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: librarySounds.path)) ?? []).filter { $0.hasPrefix("custom-") }.sorted()
    }
}

/// Plays a sound once, for the picker.
@MainActor
final class SoundPreview {
    static let shared = SoundPreview()
    private var player: AVAudioPlayer?

    func play(_ s: NotifySound) {
        player?.stop()
        guard let u = NotifySounds.previewURL(s) else { return }
        player = try? AVAudioPlayer(contentsOf: u)
        player?.play()
    }
}
