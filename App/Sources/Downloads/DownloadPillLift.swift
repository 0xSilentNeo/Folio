import SwiftUI

/// How far the downloads pill rises above its usual place (1.27.0): over
/// Discover's filter bar while Discover's own page shows. The pill floats over
/// every tab at the same height as that bar, so it covered Movies/Series.
@MainActor
final class DownloadPillLift: ObservableObject {
    static let shared = DownloadPillLift()

    /// Discover's filter bar's height (with its padding).
    var discoverBar: CGFloat = 0 {
        didSet { if discoverShown, abs(discoverBar - oldValue) > 0.5 { objectWillChange.send() } }
    }
    /// Discover's page is on screen (not another tab, nor a page pushed over it).
    var discoverShown = false {
        didSet { if discoverShown != oldValue { objectWillChange.send() } }
    }

    var lift: CGFloat { discoverShown ? discoverBar : 0 }
}
