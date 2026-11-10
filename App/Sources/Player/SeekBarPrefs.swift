import SwiftUI
import CryptoKit

/// Look of the player's progress bar (changed from the player's
/// ••• → Progress bar menu or Settings → Playback).
@MainActor
final class SeekBarPrefs: ObservableObject {
    static let shared = SeekBarPrefs()
    private let d = UserDefaults.standard

    @Published var markerStyle: String { didSet { d.set(markerStyle, forKey: "seekMarkerStyle") } }      // segments | ticks | dots | none
    @Published var markerColor: String { didSet { d.set(markerColor, forKey: "seekMarkerColor") } }      // white | accent | yellow | cyan
    @Published var showChapterTitle: Bool { didSet { d.set(showChapterTitle, forKey: "seekShowChapterTitle") } }
    @Published var showSkipSegments: Bool { didSet { d.set(showSkipSegments, forKey: "seekShowSkip") } }

    private init() {
        // Segments by default (1.26.3; ticks until then). A style you picked stays.
        markerStyle = d.string(forKey: "seekMarkerStyle") ?? "segments"
        markerColor = d.string(forKey: "seekMarkerColor") ?? "white"
        showChapterTitle = d.object(forKey: "seekShowChapterTitle") as? Bool ?? true
        showSkipSegments = d.object(forKey: "seekShowSkip") as? Bool ?? true
    }

    var color: Color {
        switch markerColor {
        // Shown as "Pink": the accent is cream in the always-dark player (review, 9 Nov).
        case "accent": return .pink
        case "yellow": return .yellow
        case "cyan": return .cyan
        default: return .white
        }
    }
}

struct UserMarker: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Double
    var title: String
}

/// Your own chapter markers, saved per video.
@MainActor
final class MarkerStore {
    static let shared = MarkerStore()
    private var all: [String: [UserMarker]] = [:]
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("markers.json")
        if let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: [UserMarker]].self, from: data) {
            all = m
        }
    }

    func markers(for key: String) -> [UserMarker] { (all[key] ?? []).sorted { $0.time < $1.time } }

    func set(_ markers: [UserMarker], for key: String) {
        all[key] = markers.isEmpty ? nil : markers
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }
}

/// Frame thumbnails captured when you stop watching (Continue Watching art).
enum ThumbnailStore {
    /// Application Support, not Caches: iOS may empty Caches when the app is
    /// killed from the switcher, which made Home tiles lose their picture.
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("thumbs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            // One-time move of what Caches still holds.
            let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("thumbs", isDirectory: true)
            for f in (try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.moveItem(at: f, to: d.appendingPathComponent(f.lastPathComponent))
            }
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            var dd = d; try? dd.setResourceValues(v)
        }
        return d
    }

    /// Named by a hash of the key. The name used to be the key's last 120
    /// base64 characters, so two long paths ending alike (the same episode
    /// name in two shows' folders) shared one picture. A picture saved under
    /// the old name is moved to the new one the first time it's asked for.
    static func url(for key: String) -> URL {
        let d = dir
        let hashed = d.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg")
        let fm = FileManager.default
        if !fm.fileExists(atPath: hashed.path) {
            let safe = Data(key.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
            let legacy = d.appendingPathComponent(String(safe.suffix(120)) + ".jpg")
            if fm.fileExists(atPath: legacy.path) { try? fm.moveItem(at: legacy, to: hashed) }
        }
        return hashed
    }

    static func image(for key: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: key).path)
    }

    static func save(bgra bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int, key: String) {
        guard let provider = CGDataProvider(data: Data(bytes: bytes, count: width * height * 4) as CFData) else { return }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        if let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.75) {
            try? data.write(to: url(for: key), options: .atomic)
            // Saved behind the closing player now (1.28.2), after Home has
            // drawn: a tile that found no frame looks again.
            DispatchQueue.main.async { NotificationCenter.default.post(name: .folioThumbnailSaved, object: key) }
        }
    }
}

extension Notification.Name {
    /// A Continue Watching frame was saved (object: its key).
    static let folioThumbnailSaved = Notification.Name("FolioThumbnailSaved")
}
