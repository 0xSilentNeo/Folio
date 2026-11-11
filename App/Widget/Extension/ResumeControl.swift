import AppIntents
import SwiftUI
import WidgetKit

/// The Resume control (1.24.0, iOS 18): in Control Center, on the Lock
/// Screen's buttons or the Action button, one tap plays what you watched
/// last from its saved place (ResumeLastIntent, run in Folio).
///
/// 1.24.1: the user's controls gallery and Control Center showed an empty
/// circle until the control was made bigger. 1.24.0 fed the label from a
/// value provider whose preview value was nil (an empty String?), the one
/// way it differed from Apple's own button control ("Creating controls to
/// perform actions across the system": StaticControlConfiguration(kind:)
/// with a ControlWidgetButton and a Label with a symbol). It's that form
/// now: the label and the symbol are fixed, nothing to fetch first.
///
/// 1.28.4 (the user, 10 Nov: still an empty circle, "Resume" only when
/// made bigger, and a tap did nothing; the log never saw it run): the
/// action is iOS's own OpenURLIntent with folio://resume, which Folio plays
/// from (FolioApp.handle). The control no longer hangs on Folio's own
/// intent being matched to the app, which a re-signed install evidently
/// didn't manage. Shortcuts and the Action button keep ResumeLastIntent.
///
/// 1.28.6 (still blank and dead in 1.28.5): the action is ResumeControlIntent,
/// which opens Folio and hands folio://resume on from inside it; a new
/// kind; and Folio asks iOS to reload its controls at each launch.
@available(iOSApplicationExtension 18.0, *)
struct ResumeControl: ControlWidget {
    /// A new kind (1.28.6), so iOS takes it for a new control: one placed
    /// under an earlier build could stay a blank that's never drawn again.
    static let kind = "dev.silentneo.folio.resume2"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            // For the log (1.28.5): whether iOS asks Folio to draw it at all.
            let _ = KeychainShare.controlDrawn()
            ControlWidgetButton(action: ResumeControlIntent()) {
                Label("Resume", systemImage: "play.fill")
            }
        }
        // Not the label's word (1.28.6): if a control still shows only
        // "Resume in Folio", iOS drew its placeholder, not this button.
        .displayName("Resume in Folio")
        .description("Plays what you watched last in Folio.")
    }
}
