import SwiftUI

/// The watched actions of a menu (title page, episode rows, Home's titles,
/// WebDAV files), from the same history the eye marks read:
/// "Mark … as watched" only when at least one item isn't watched, and
/// "Mark … as unwatched" only when at least one is. Built when the menu
/// opens, so it's right straight after any change.
struct WatchedMenuItems: View {
    enum Scope {
        /// One file: "Mark as watched".
        case one
        /// The page's own episode among others: "Mark this episode as watched".
        case thisEpisode
        /// All of a title's episodes: "Mark all as watched".
        case all
    }

    let keys: [String]
    var scope: Scope = .one
    /// The history item for a key that was never played (to mark it watched).
    let item: (String) -> MediaItem

    init(keys: [String], scope: Scope = .one, item: @escaping (String) -> MediaItem) {
        self.keys = keys
        self.scope = scope
        self.item = item
    }

    /// Library files.
    init(files: [URL], scope: Scope = .one) {
        self.init(keys: files.map(\.path), scope: scope, item: HistoryStore.libraryItem)
    }

    /// Which of the two actions show when `watched` of `total` items are watched.
    static func offers(watched: Int, total: Int) -> (markWatched: Bool, markUnwatched: Bool) {
        (watched < total, watched > 0)
    }

    var body: some View {
        let history = HistoryStore.shared
        let offers = Self.offers(watched: keys.filter { history.isWatched(key: $0) }.count, total: keys.count)
        if offers.markWatched {
            Button { history.setWatched(keys, true, item: item) } label: { Label(title(watched: true), systemImage: "eye") }
        }
        if offers.markUnwatched {
            Button { history.setWatched(keys, false, item: item) } label: { Label(title(watched: false), systemImage: "eye.slash") }
        }
    }

    private func title(watched: Bool) -> String {
        let state = watched ? "watched" : "unwatched"
        switch scope {
        case .one: return "Mark as \(state)"
        case .thisEpisode: return "Mark this episode as \(state)"
        case .all: return "Mark all as \(state)"
        }
    }
}
