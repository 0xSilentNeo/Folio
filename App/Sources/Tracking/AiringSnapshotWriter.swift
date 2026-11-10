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
                                       episodes: eps.map { AiringSnapshot.Episode(label: $0.label, title: $0.title, airDate: $0.airDate!, day: $0.day) })
        }
        let sorted = items.sorted { ($0.headline(at: now)?.airDate ?? .distantFuture) < ($1.headline(at: now)?.airDate ?? .distantFuture) }
        var snap = AiringSnapshot(items: Array(sorted.prefix(AiringSnapshot.limit)))
        // 1.24.0: how many are tracked, and what came out in the last week
        // (the Out now widget), newest first.
        snap.tracked = shows.count
        let week = now.addingTimeInterval(-7 * 86400)
        snap.recent = Array(shows.flatMap { s in
            s.schedule.filter { $0.airDate! > week && $0.airDate! <= now }.map {
                AiringSnapshot.Recent(showID: s.id, show: s.name, label: $0.label, title: $0.title, airDate: $0.airDate!,
                                      season: $0.season, number: $0.number)
            }
        }.sorted { $0.airDate > $1.airDate }.prefix(6))
        return snap
    }

    /// Where each recent episode is, if Folio has it: the library or a
    /// server's saved library (EpisodeFinder; no network).
    static func locate(_ snap: inout AiringSnapshot, shows: [TrackedShow]) async {
        guard let recent = snap.recent, !recent.isEmpty else { return }
        let files = await ContinueQueue.libraryFiles()
        for server in ServerStore.shared.servers { await LibraryIndexStore.shared.load(server) }
        snap.recent = recent.map { r in
            var r = r
            if let n = r.number, let show = shows.first(where: { $0.id == r.showID }) {
                r.available = EpisodeFinder.find(show, season: r.season, episode: n, libraryFiles: files)?.place
            }
            return r
        }
    }

    private static func write(_ shows: [TrackedShow]) async {
        guard let dir = WidgetStore.airing(create: true) else {
            if !toldNoGroup {
                toldNoGroup = true
                dlog("tracking", "no App Group container and no Keychain group: the Airing widget shows Open Folio")
            }
            return
        }
        var snap = snapshot(shows, now: Date())
        await locate(&snap, shows: shows)
        let posters = Dictionary(shows.map { ($0.id, $0.poster) }, uniquingKeysWith: { a, _ in a })
        for i in snap.items.indices {
            snap.items[i].picture = await picture(posters[snap.items[i].id] ?? nil, in: dir)
            guard !Task.isCancelled else { return }
        }
        if var recent = snap.recent {
            for i in recent.indices {
                recent[i].picture = await picture(posters[recent[i].showID] ?? nil, in: dir)
                guard !Task.isCancelled else { return }
            }
            snap.recent = recent
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
            let keep = Set(final.items.compactMap(\.picture) + (final.recent ?? []).compactMap(\.picture))
            for f in dir.names() where f.hasSuffix(".jpg") && !keep.contains(f) { dir.remove(f) }
            return true
        }.value
        guard let wrote else { return }
        written = snap
        guard wrote else { return }
        for kind in WidgetKind.airingKinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        dlog("tracking", "Airing widget: \(snap.items.count) show(s)\(dir.isKeychain ? " (Keychain)" : "")")
    }

    /// The poster's file name next to the snapshot, named by its address.
    private static func picture(_ poster: String?, in dir: WidgetStore) async -> String? {
        guard let poster, let url = URL(string: largePoster(poster)) else { return nil }
        // The size in the name: posters kept smaller before are fetched again
        // (and swept as no show uses them).
        let name = hash(poster) + "-\(Int(AiringSnapshot.picturePixels)).jpg"
        if dir.exists(name) { return name }
        guard let img = await ImageCache.shared.image(url, maxPixel: AiringSnapshot.picturePixels) else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            guard let jpeg = img.jpegData(compressionQuality: 0.8), (try? dir.write(jpeg, name)) != nil else { return nil }
            return name
        }.value
    }

    /// The poster at a size the widget can fill a small widget with
    /// (1.28.4). Tracked shows keep TVmaze's medium poster (210×295) or
    /// AniList's large cover (about 230 wide), stretched over the Airing Day
    /// widget; each service's full size instead, scaled down on the way in.
    static func largePoster(_ poster: String) -> String {
        if poster.contains("._V1_") { return IMDbSource.sized(poster, width: 400) ?? poster }
        if poster.contains("tvmaze.com") {
            return poster.replacingOccurrences(of: "/medium_portrait/", with: "/original_untouched/")
        }
        if poster.contains("anilist.co") {
            return poster.replacingOccurrences(of: "/cover/large/", with: "/cover/extraLarge/")
                .replacingOccurrences(of: "/cover/medium/", with: "/cover/extraLarge/")
        }
        return poster
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
