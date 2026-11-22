import Charts
import PaqoCore
import SwiftUI

/// How the owner's running and sprinting change over weeks and months.
struct TrendsView: View {
    @Environment(RunLibrary.self) private var library
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault
    @State private var range: TrendRange = .threeMonths

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases) { range in
                            Text(range.shortName).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)

                    let now = Date()
                    ForEach(TrendMetric.allCases) { metric in
                        TrendCard(
                            series: TrendCalculator.series(metric, range: range, summaries: library.summaries, now: now, calendar: .current),
                            unit: unit
                        )
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Trends")
            .overlay {
                if library.summaries.isEmpty {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Your sprint speed, rest and more will show up here once you've run.")
                    )
                }
            }
        }
    }
}

/// One metric: the number for the range, how it compares with the range before,
/// and a chart by week or month.
struct TrendCard: View {
    let series: TrendSeries
    let unit: DistanceUnit

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(Theme.label)
                    .foregroundStyle(Theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(series.headline.map(format) ?? "—")
                        .font(Theme.number(30))
                        .foregroundStyle(Theme.textPrimary)
                    if let change = changeText {
                        Text(change.text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(change.better ? Theme.accent : Theme.textSecondary)
                    }
                }
                chart
                    .frame(height: 120)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        let points = series.buckets.compactMap { bucket in bucket.value.map { (bucket.start, chartValue($0)) } }
        let calendarUnit: Calendar.Component = series.range == .fourWeeks || series.range == .threeMonths ? .weekOfYear : .month
        if points.isEmpty {
            Text("No data in this range yet")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if series.metric == .distance || series.metric == .runCount {
            Chart(points, id: \.0) { point in
                BarMark(x: .value("Period", point.0, unit: calendarUnit), y: .value(title, point.1))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(3)
            }
        } else {
            Chart(points, id: \.0) { point in
                LineMark(x: .value("Period", point.0, unit: calendarUnit), y: .value(title, point.1))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Period", point.0, unit: calendarUnit), y: .value(title, point.1))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(20)
            }
        }
    }

    private var title: String {
        switch series.metric {
        case .distance: return "Distance"
        case .runCount: return "Runs"
        case .averageSprintSpeed: return "Avg sprint speed"
        case .peakSpeed: return "Peak speed"
        case .sprintsPerRun: return "Sprints per run"
        case .averageSprintTime: return "Avg sprint time"
        case .averageSprintDistance: return "Avg sprint distance"
        case .averageRest: return "Avg rest between sprints"
        case .workRestRatio: return "Sprint : rest"
        case .sprintShare: return "Time spent sprinting"
        case .fade: return "Fade"
        case .sprintCadence: return "Sprint cadence"
        }
    }

    private func format(_ value: Double) -> String {
        switch series.metric {
        case .distance: return "\(Format.distance(value, unit: unit)) \(unit.abbreviation)"
        case .runCount: return "\(Int(value.rounded()))"
        case .averageSprintSpeed, .peakSpeed: return "\(Format.speed(value, unit: unit)) \(unit.speedAbbreviation)"
        case .sprintsPerRun: return Format.fixed(value, decimals: 1)
        case .averageSprintTime, .averageRest: return Format.duration(value)
        case .averageSprintDistance: return "\(Format.distance(value, unit: unit, decimals: 2)) \(unit.abbreviation)"
        case .workRestRatio: return value > 0 ? "1 : \(Format.fixed(1 / value, decimals: 1))" : "—"
        case .sprintShare: return "\(Int((value * 100).rounded()))%"
        case .fade:
            let percent = Int((value * 100).rounded())
            return percent > 0 ? "+\(percent)%" : "\(percent)%"
        case .sprintCadence: return "\(Int(value.rounded())) spm"
        }
    }

    /// The value as charted, in the owner's units.
    private func chartValue(_ value: Double) -> Double {
        switch series.metric {
        case .distance, .averageSprintDistance: return unit.distance(fromMeters: value)
        case .averageSprintSpeed, .peakSpeed: return unit.speed(fromMetersPerSecond: value)
        case .sprintShare, .fade: return value * 100
        default: return value
        }
    }

    private var changeText: (text: String, better: Bool)? {
        guard let now = series.headline, let before = series.previous, now != before else { return nil }
        let up = now > before
        let better = series.metric.higherIsBetter ? up : !up
        return ("\(up ? "▲" : "▼") from \(format(before))", better)
    }
}
