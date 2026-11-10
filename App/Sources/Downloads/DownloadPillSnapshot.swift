import Foundation

/// What the downloads pill shows, read from the manager at most twice a
/// second (1.28.2). The pill watched the manager itself, which announces
/// each piece's progress, many times a second: 5–20 redraws a second of a
/// pill whose numbers change once.
struct DownloadPillSnapshot: Equatable {
    var hasWork = false
    var active = 0
    var speed: Double = 0
    var history: [Double] = []

    @MainActor static func now() -> DownloadPillSnapshot {
        let d = DownloadManager.shared
        return DownloadPillSnapshot(hasWork: d.hasWork, active: d.active.count, speed: d.speed, history: d.speedHistory)
    }
}
