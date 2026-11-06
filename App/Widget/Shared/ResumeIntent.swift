import AppIntents
import Foundation

// The Resume control (1.24.0, iOS 18): Control Center, the Lock Screen's
// buttons and the Action button. Built into both the app and the widget,
// as Apple requires for a control that opens its app ("Creating controls
// to perform actions across the system": an OpenIntent whose target
// membership is both). iOS brings Folio to the front and runs perform()
// there, which plays what you watched last from its saved place.

enum ResumeTarget: String, AppEnum {
    case lastWatched

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Folio"
    static let caseDisplayRepresentations: [ResumeTarget: DisplayRepresentation] = [.lastWatched: "What you watched last"]
}

struct ResumeLastIntent: OpenIntent {
    static let title: LocalizedStringResource = "Resume in Folio"
    static let description: IntentDescription? = IntentDescription("Plays what you watched last in Folio, from where you stopped.")
    static let isDiscoverable = false

    @Parameter(title: "What")
    var target: ResumeTarget

    init() { target = .lastWatched }

    @MainActor
    func perform() async throws -> some IntentResult {
        ResumeHook.run?()
        return .result()
    }
}

/// What the app does for the control (set at launch; nil in the widget's process).
enum ResumeHook {
    @MainActor static var run: (() -> Void)?
}
