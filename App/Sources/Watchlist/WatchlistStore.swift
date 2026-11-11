import Foundation
import Combine

/// Titles saved to watch later (1.26.0), newest first, in
/// Application Support/watchlist.json. Discover shows them in a row and on
/// their own page; a title page and a long press on a tile add and remove.
@MainActor
final class WatchlistStore: ObservableObject {
    static let shared = WatchlistStore()

    @Published private(set) var items: [WatchlistItem] = []
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
        ids = Set(items.map(\.id))
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
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        ids.remove(id)
        save()
        dlog("watchlist", "removed \(item.name) (\(item.id)); \(items.count) saved")
        changes.send((item, false))
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
