import AppIntents
import SwiftUI
import WidgetKit

/// The Resume control (1.24.0, iOS 18): in Control Center, on the Lock
/// Screen's buttons or the Action button, one tap plays what you watched
/// last from its saved place (ResumeLastIntent, run in Folio).
@available(iOSApplicationExtension 18.0, *)
struct ResumeControl: ControlWidget {
    static let kind = "dev.silentneo.folio.resume"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { title in
            ControlWidgetButton(action: ResumeLastIntent()) {
                Label(title ?? "Resume", systemImage: "play.fill")
            }
        }
        .displayName("Resume")
        .description("Plays what you watched last in Folio.")
    }

    /// The title watched last, from Continue Watching's snapshot.
    struct Provider: ControlValueProvider {
        var previewValue: String? { nil }

        func currentValue() async throws -> String? {
            ContinueSnapshot.read(from: WidgetStore.continueWatching())?.items.first?.title
        }
    }
}
