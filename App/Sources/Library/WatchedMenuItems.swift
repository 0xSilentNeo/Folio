import SwiftUI

/// The watched actions of a menu (title page, episode rows, WebDAV and
/// server files), from the same history the eye marks read:
/// "Mark … as watched" only when at least one item isn't watched, and
/// "Mark … as unwatched" only when at least one is.
///
/// It watches the history (1.24.1). Until then it only read it, and SwiftUI
/// keeps a menu's items from when they were last built: on 7 Nov in the lab
/// an episode marked watched from its menu still offered "Mark as watched"
/// (the title page's own badge already said Watched), and a watched show on
/// Home offered "Mark all as watched" (the user's 11:02 screenshot).
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
    @ObservedObject private var history = HistoryStore.shared
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
