import AppIntents
import Foundation

/// The pause/resume button on the lock screen and in the Dynamic Island.
/// As a `LiveActivityIntent` it runs inside the app's process, where the bridge
/// forwards it to the run controller.
struct ToggleRunPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Run"

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        RunIntentBridge.shared.toggle()
        return .result()
    }
}

/// Set by the app at launch. Nil inside the widget extension (never invoked there).
@MainActor
final class RunIntentBridge {
    static let shared = RunIntentBridge()
    var toggleHandler: (() -> Void)?

    func toggle() {
        toggleHandler?()
    }
}
