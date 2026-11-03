import CryptoKit
import UIKit
import WidgetKit

/// Copies the tracked shows' upcoming episodes into the App Group's
/// container for the Airing widget (AiringSnapshot), with a small poster for
/// each, as ContinueSnapshotWriter does for Continue Watching. The widget
/// moves from "in 2 h" to "Out now" on its own (a timeline entry per air
/// time); a new snapshot is needed only when the schedules change.
@MainActor
enum AiringSnapshotWriter {
    private static var running: Task<Void, Never>?
    /// What's in the container: an unchanged snapshot isn't written again,
    /// nor the widget reloaded (WidgetKit limits reloads).
    private static var written: AiringSnapshot?
    private static var toldNoGroup = false

    static func schedule(_ shows: [TrackedShow]) {
        running?.cancel()
        running = Task { await write(shows) }
    }

    /// The shows with an episode out in the last six hours or still to come,
    /// soonest first, each with up to eight of those episodes.
    static func snapshot(_ shows: [TrackedShow], now: Date) -> AiringSnapshot {
        let since = now.addingTimeInterval(-AiringClock.outNowWindow)
        let items: [AiringSnapshot.Item] = shows.compactMap { s in
            let eps = s.schedule.filter { $0.airDate! > since }.prefix(8)
            guard !eps.isEmpty else { return nil }
            return AiringSnapshot.Item(id: s.id, name: s.name, network: s.network,
                                       episodes: eps.map { AiringSnapshot.Episode(label: $0.label, title: $0.title, airDate: $0.airDate!) })
        }
        let sorted = items.sorted { ($0.headline(at: now)?.airDate ?? .distantFuture) < ($1.headline(at: now)?.airDate ?? .distantFuture) }
        return AiringSnapshot(items: Array(sorted.prefix(AiringSnapshot.limit)))
    }

    private static func write(_ shows: [TrackedShow]) async {
        guard let dir = AiringSnapshot.directory(create: true) else {
            if !toldNoGroup {
                toldNoGroup = true
                dlog("tracking", "no App Group container: the Airing widget shows Open Folio")
            }
            return
        }
        var snap = snapshot(shows, now: Date())
        let posters = Dictionary(shows.map { ($0.id, $0.poster) }, uniquingKeysWith: { a, _ in a })
        for i in snap.items.indices {
            snap.items[i].picture = await picture(posters[snap.items[i].id] ?? nil, in: dir)
            guard !Task.isCancelled else { return }
        }
        // Compared, written and swept off the main thread. Nil: not written.
        let previous = written, final = snap
        let wrote = await Task.detached(priority: .utility) { () -> Bool? in
            guard final != (previous ?? AiringSnapshot.read(from: dir)) else { return false }
            do { try final.write(to: dir) } catch {
                dlog("tracking", "Airing widget snapshot not written: \(error.localizedDescription)")
                return nil
            }
            // Posters no show uses any more.
            let keep = Set(final.items.compactMap(\.picture))
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".jpg") && !keep.contains(f) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
            return true
        }.value
        guard let wrote else { return }
        written = snap
        guard wrote else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: AiringSnapshot.widgetKind)
        dlog("tracking", "Airing widget: \(snap.items.count) show(s)")
    }

    /// The poster's file name next to the snapshot, named by its address.
    private static func picture(_ poster: String?, in dir: URL) async -> String? {
        guard let poster, let url = URL(string: IMDbSource.sized(poster, width: 300) ?? poster) else { return nil }
        let name = hash(poster) + ".jpg"
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        guard let img = await ImageCache.shared.image(url, maxPixel: AiringSnapshot.picturePixels) else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            guard let jpeg = img.jpegData(compressionQuality: 0.8),
                  (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
            return name
        }.value
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
