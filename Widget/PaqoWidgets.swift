import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct PaqoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RunLiveActivity()
    }
}

/// Lock screen + Dynamic Island for a run in progress.
struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            LockScreenRunView(state: context.state)
                .activityBackgroundTint(Theme.background)
                .activitySystemActionForegroundColor(Theme.accent)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(state.distance)
                                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            Text(state.unit)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text("DISTANCE").font(Theme.label).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(state.pace)
                                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            Text(state.paceUnit)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text("PACE").font(Theme.label).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            RunTimerText(state: state)
                                .font(.system(size: 30, weight: .bold).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                            SegmentLabel(state: state)
                        }
                        Spacer()
                        PauseResumeButton(isPaused: state.isPaused)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: state.isSprinting ? "figure.run" : "figure.walk")
                    .foregroundStyle(state.isPaused ? Theme.textSecondary : (state.isSprinting ? Theme.accent : Theme.walk))
            } compactTrailing: {
                RunTimerText(state: state)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: state.isPaused ? "pause.fill" : "figure.run")
                    .foregroundStyle(Theme.accent)
            }
            .keylineTint(Theme.accent)
        }
    }
}

struct LockScreenRunView: View {
    let state: RunActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("paqo")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                SegmentLabel(state: state)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    RunTimerText(state: state)
                        .font(.system(size: 38, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Text("TIME").font(Theme.label).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                PauseResumeButton(isPaused: state.isPaused)
            }
            HStack(spacing: 28) {
                stat(state.distance, unit: state.unit, label: "DISTANCE")
                stat(state.pace, unit: state.paceUnit, label: "PACE")
                Spacer()
            }
        }
        .padding(16)
    }

    private func stat(_ value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text(unit)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(label).font(Theme.label).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Counts up on its own while running; frozen while paused.
struct RunTimerText: View {
    let state: RunActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(state.movingText)
        } else {
            Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
        }
    }
}

struct SegmentLabel: View {
    let state: RunActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(state.isPaused ? "Paused" : state.segment)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.18), in: Capsule())
    }

    private var color: Color {
        if state.isPaused { return Theme.textSecondary }
        return state.isSprinting ? Theme.accent : Theme.walk
    }
}

struct PauseResumeButton: View {
    let isPaused: Bool

    var body: some View {
        Button(intent: ToggleRunPauseIntent()) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 52, height: 52)
                .background(Theme.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume run" : "Pause run")
    }
}
