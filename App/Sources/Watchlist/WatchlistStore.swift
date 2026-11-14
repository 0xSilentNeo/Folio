import Foundation
import Combine

/// Titles saved to watch later (1.26.0), newest first, in
/// Application Support/watchlist.json. Discover shows them in a row and on
/// their own page; a title page and a long press on a tile add and remove.
@MainActor
final class WatchlistStore: ObservableObject {
    static let shared = WatchlistStore()

    @Published private(set) var items: [WatchlistItem] = []
    /// Every id a saved title answers to: its own and the one it was saved under before (`altID`).
    private var ids: Set<String> = []

    /// Told when a title is added or removed (the sync services' watchlists).
    let changes = PassthroughSubject<(item: WatchlistItem, added: Bool), Never>()

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watchlist.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let whole = try? decoder.decode([WatchlistItem].self, from: data) {
                items = whole
            } else {
                // 1.28.6: entry by entry, with a copy set aside (one entry
                // that didn't read emptied the list, and the next add wrote over it).
                items = decoder.decodeLossy(WatchlistItem.self, from: data) ?? []
                try? data.write(to: url.deletingLastPathComponent().appendingPathComponent("watchlist.unreadable.json"), options: .atomic)
                dlog("watchlist/error", "watchlist.json didn't read whole: \(items.count) kept, a copy set aside")
            }
        }
        ids = Self.allIDs(items)
    }

    nonisolated static func allIDs(_ items: [WatchlistItem]) -> Set<String> {
        Set(items.flatMap { [$0.id] + ($0.altID.map { [$0] } ?? []) })
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ meta: MetaItem) {
        if contains(meta.id) { remove(meta.id) } else { add(meta) }
    }

    func add(_ meta: MetaItem) {
        guard !contains(meta.id) else { return }
        let item = WatchlistItem(meta: meta)
        items.insert(item, at: 0)
        ids.insert(item.id)
        save()
        dlog("watchlist", "added \(item.name) (\(item.id)); \(items.count) saved")
        changes.send((item, true))
    }

    func remove(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id || $0.altID == id }) else { return }
        let item = items.remove(at: i)
        ids = Self.allIDs(items)
        save()
        dlog("watchlist", "removed \(item.name) (\(item.id)); \(items.count) saved")
        changes.send((item, false))
    }

    /// A title saved under a "tmdb:" or "anilist:" id, now that its page
    /// has found the IMDb id (1.30.4): kept under the IMDb id, the old one
    /// remembered. Its page showed an empty bookmark (the page's id is the
    /// IMDb one), a tap saved it twice, and the sync services never got it
    /// (they take IMDb ids).
    func migrate(from oldID: String, to imdbID: String) {
        guard let m = Self.migrating(items, from: oldID, to: imdbID) else { return }
        items = m.items
        ids = Self.allIDs(items)
        save()
        if let moved = m.moved {
            dlog("watchlist", "\(moved.name): \(oldID) is \(imdbID) now")
            changes.send((moved, true))
        } else {
            dlog("watchlist", "\(oldID) was saved as \(imdbID) too: one entry kept")
        }
    }

    /// The list with `oldID`'s entry under `imdbID`, and the entry moved;
    /// saved under both already, the IMDb one is kept (`moved` nil). Nil:
    /// nothing to change.
    nonisolated static func migrating(_ items: [WatchlistItem], from oldID: String, to imdbID: String) -> (items: [WatchlistItem], moved: WatchlistItem?)? {
        guard oldID != imdbID, imdbID.hasPrefix("tt"), let i = items.firstIndex(where: { $0.id == oldID }) else { return nil }
        var out = items
        if let j = out.firstIndex(where: { $0.id == imdbID }) {
            out[j].altID = oldID
            out.remove(at: i)
            return (out, nil)
        }
        out[i].id = imdbID
        out[i].altID = oldID
        return (out, out[i])
    }

    /// Titles from a sync service's watchlist that aren't here yet (no echo back to it).
    func merge(_ metas: [MetaItem]) {
        let new = metas.filter { !contains($0.id) }.map { WatchlistItem(meta: $0) }
        guard !new.isEmpty else { return }
        items += new
        ids.formUnion(new.map(\.id))
        save()
        dlog("watchlist", "\(new.count) title(s) from a sync service's watchlist")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        do { try data.write(to: url, options: .atomic) } catch { dlog("watchlist/error", "not saved: \(error.localizedDescription)") }
    }
}
