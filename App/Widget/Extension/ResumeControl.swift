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
@available(iOSApplicationExtension 18.0, *)
struct ResumeControl: ControlWidget {
    static let kind = "dev.silentneo.folio.resume"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ResumeLastIntent()) {
                Label("Resume", systemImage: "play.fill")
            }
        }
        .displayName("Resume")
        .description("Plays what you watched last in Folio.")
    }
}
