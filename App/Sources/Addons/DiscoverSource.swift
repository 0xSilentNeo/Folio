import Foundation

/// Where Discover's grid comes from (1.27.1): Cinemeta (the addon) or TMDB
/// (your key), in the order you set in Addons, and IMDb, built in, after
/// them. The first one set up is used; when it doesn't answer, the next.
/// IMDb's lists stop at 250 titles; Cinemeta's and TMDB's go on.
enum DiscoverSource: String, CaseIterable, Identifiable {
    case cinemeta, tmdb, imdb

    var id: String { rawValue }

    var name: String {
        switch self {
        case .cinemeta: "Cinemeta"
        case .tmdb: "TMDB"
        case .imdb: "IMDb"
        }
    }

    /// The two you can set up, comma-separated in your order ("tmdb,cinemeta").
    static let orderKey = "discoverSourceOrder"

    /// Your order of Cinemeta and TMDB, then IMDb.
    static func order(_ saved: String? = UserDefaults.standard.string(forKey: orderKey)) -> [DiscoverSource] {
        var list: [DiscoverSource] = []
        for s in (saved ?? "").split(separator: ",").compactMap({ DiscoverSource(rawValue: String($0)) }) where s != .imdb && !list.contains(s) {
            list.append(s)
        }
        for s in [DiscoverSource.cinemeta, .tmdb] where !list.contains(s) { list.append(s) }
        return list + [.imdb]
    }

    static func save(_ order: [DiscoverSource]) {
        UserDefaults.standard.set(order.filter { $0 != .imdb }.map(\.rawValue).joined(separator: ","), forKey: orderKey)
    }

    /// Set up: Cinemeta installed and switched on, a TMDB key; IMDb always.
    @MainActor var isReady: Bool {
        switch self {
        case .cinemeta: AddonStore.shared.cinemetaAddon != nil
        case .tmdb: TMDB.enabled
        case .imdb: true
        }
    }

    /// The sources to try, best first (IMDb last, always there).
    @MainActor static var chain: [DiscoverSource] { order().filter(\.isReady) }

    /// What Discover uses now.
    @MainActor static var current: DiscoverSource { chain.first ?? .imdb }
}
