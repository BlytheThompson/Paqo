import ActivityKit
import Foundation

/// Data for the lock screen / Dynamic Island Live Activity.
/// Values arrive pre-formatted so the widget needs no tracking code.
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPaused: Bool
        /// While running, `Date.now - movingTime`; the widget counts up from here on its own.
        var timerStart: Date
        /// Frozen moving time shown while paused, e.g. "24:31".
        var movingText: String
        /// e.g. "3.12"
        var distance: String
        /// "mi" or "km"
        var unit: String
        /// e.g. "9:57"
        var pace: String
        /// "/mi" or "/km"
        var paceUnit: String
        /// "Sprint 4", "Walk 3", "Starting"
        var segment: String
        var isSprinting: Bool
    }

    var startDate: Date
}
