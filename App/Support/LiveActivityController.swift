import ActivityKit
import Foundation

/// Starts, updates and ends the lock screen / Dynamic Island Live Activity.
@MainActor
final class LiveActivityController {
    private var activity: Activity<RunActivityAttributes>?
    private var lastUpdate = Date.distantPast

    /// Updates are throttled to one every `minimumInterval` seconds unless forced; the
    /// timer ticks on its own in the widget, so this only refreshes distance and pace.
    var minimumInterval: TimeInterval = 5

    func start(startDate: Date, state: RunActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: RunActivityAttributes(startDate: startDate),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastUpdate = Date()
        } catch {
            activity = nil
        }
    }

    func update(state: RunActivityAttributes.ContentState, force: Bool) {
        guard let activity else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdate) >= minimumInterval else { return }
        lastUpdate = now
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await activity.update(content)
        }
    }

    func end(state: RunActivityAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    /// Ends activities left over from a previous launch (e.g. after a crash).
    func endStaleActivities() {
        let stale = Activity<RunActivityAttributes>.activities
        guard !stale.isEmpty else { return }
        Task {
            for activity in stale {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
