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
        guard let run = ResumeHook.run else {
            // 1.28.6: said, where it was a silent nothing.
            NSLog("Folio: Resume intent ran before the app set its hook")
            return .result()
        }
        run()
        return .result()
    }
}

/// The Resume control's action (1.28.6). 1.28.4 gave the control iOS's
/// OpenURLIntent with folio://resume directly; a link that isn't a
/// universal link is evidently dropped when it's a control's own action,
/// and a sideloaded install has no universal links. This is the form that
/// works for a custom scheme: Folio's own intent, in both targets, that
/// opens the app and hands the link on as its result.
@available(iOS 18.0, *)
struct ResumeControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume in Folio"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        // Run in Folio (as openAppWhenRun asks): plays now. The link after it
        // only brings Folio to the front ("front" does nothing else).
        if let run = ResumeHook.run {
            ResumeHook.tapped?()
            run()
            return .result(opensIntent: OpenURLIntent(URL(string: "folio://front")!))
        }
        // Run in the widget's process instead: Folio plays from the link.
        return .result(opensIntent: OpenURLIntent(URL(string: "folio://resume")!))
    }
}

/// What the app does for the control (set at launch; nil in the widget's process).
enum ResumeHook {
    @MainActor static var run: (() -> Void)?
    /// For the log: the control's intent ran in Folio.
    @MainActor static var tapped: (() -> Void)?
}
