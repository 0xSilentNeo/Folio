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
    /// Files paused since Folio started (1.30.4): the pill stays for them,
    /// its button Resume all. After Pause all (or iOS's stop button) it went,
    /// with no way back but the Downloads screen.
    var paused = 0

    /// The pill shows.
    var shown: Bool { hasWork || paused > 0 }
    /// Its button resumes (nothing downloading, something paused); else it pauses.
    var resumes: Bool { active == 0 && paused > 0 }

    @MainActor static func now() -> DownloadPillSnapshot {
        let d = DownloadManager.shared
        return DownloadPillSnapshot(hasWork: d.hasWork, active: d.active.count, speed: d.speed, history: d.speedHistory,
                                    paused: d.items.filter { $0.state == .paused && d.pausedThisRun.contains($0.id) }.count)
    }
}
