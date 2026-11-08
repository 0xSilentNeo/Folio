import Foundation

/// The "Airing now" row's lists, one per pill, kept while Discover is open:
/// switching pills is instant and nothing is fetched twice.
@MainActor
final class AiringNowRowModel: ObservableObject {
    @Published private(set) var lists: [AiringCatalog.Kind: [AiringCatalog.Entry]] = [:]
    @Published private(set) var loading: Set<AiringCatalog.Kind> = []
    private var fetched: Set<AiringCatalog.Kind> = []

    func show(_ kind: AiringCatalog.Kind, force: Bool = false) {
        if lists[kind] == nil, let hit = AiringCatalog.cached(kind) {
            lists[kind] = hit.entries
            if hit.fresh && !force { fetched.insert(kind) }
        }
        guard force || !fetched.contains(kind), !loading.contains(kind) else { return }
        fetched.insert(kind)
        loading.insert(kind)
        Task {
            let fresh = await AiringCatalog.load(kind)
            if !fresh.isEmpty || lists[kind] == nil { lists[kind] = fresh }
            loading.remove(kind)
        }
    }
}
