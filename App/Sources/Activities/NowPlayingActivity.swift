import ActivityKit
import Foundation

/// What's left of the now-playing Live Activity (1.22.0 to 1.22.7). Since
/// 1.22.7 Control Center and the Lock Screen show what Folio plays (Now
/// Playing), so 1.23.0 took the activity out. One left on the Lock Screen
/// by an older version goes at launch.
@MainActor
enum NowPlayingActivity {
    static func endLeftovers() {
        let left = Activity<NowPlayingActivityAttributes>.activities
        guard !left.isEmpty else { return }
        dlog("activity", "now playing: ending \(left.count) activity left by an older version")
        Task { for a in left { await a.end(nil, dismissalPolicy: .immediate) } }
    }
}
