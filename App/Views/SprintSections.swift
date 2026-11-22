import Charts
import PaqoCore
import SwiftUI

private func speedText(_ mps: Double, _ unit: DistanceUnit) -> String {
    "\(Format.speed(mps, unit: unit)) \(unit.speedAbbreviation)"
}

private func percentText(_ fraction: Double) -> String {
    let value = Int((fraction * 100).rounded())
    return value > 0 ? "+\(value)%" : "\(value)%"
}

// MARK: - Run-level sprint numbers

/// Every sprint number for the run, two to a row.
struct SprintStatsGrid: View {
    let stats: SprintStats
    let unit: DistanceUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sprint stats")
            Card {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                    GridRow {
                        StatBlock(value: "\(stats.sprintCount)", label: stats.sprintCount == 1 ? "Sprint" : "Sprints", size: 28)
                        StatBlock(
                            value: Format.duration(stats.totalSprintTime),
                            label: "Sprinting · \(Int((stats.sprintShare * 100).rounded()))% of run",
                            size: 28
                        )
                    }
                    GridRow {
                        StatBlock(value: Format.duration(stats.averageSprintTime), label: "Avg sprint time", size: 20)
                        StatBlock(value: Format.distance(stats.averageSprintDistance, unit: unit), unit: unit.abbreviation, label: "Avg sprint distance", size: 20)
                    }
                    GridRow {
                        StatBlock(value: Format.speed(stats.averageSprintSpeed, unit: unit), unit: unit.speedAbbreviation, label: "Avg sprint speed", size: 20)
                        StatBlock(value: Format.speed(stats.peakSpeed, unit: unit), unit: unit.speedAbbreviation, label: "Peak speed", size: 20)
                    }
                    GridRow {
                        StatBlock(value: Format.speed(stats.fastestSprintSpeed, unit: unit), unit: unit.speedAbbreviation, label: "Fastest sprint", size: 20)
                        StatBlock(value: Format.speed(stats.slowestSprintSpeed, unit: unit), unit: unit.speedAbbreviation, label: "Slowest sprint", size: 20)
                    }
                    GridRow {
                        StatBlock(value: stats.averageRest.map(Format.duration) ?? "—", label: "Avg rest", size: 20)
                        StatBlock(value: stats.workRestRatio.map { $0 > 0 ? "1 : \(Format.fixed(1 / $0, decimals: 1))" : "—" } ?? "—", label: "Sprint : rest", size: 20)
                    }
                    GridRow {
                        StatBlock(value: stats.fade.map(percentText) ?? "—", label: "Fade", size: 20)
                        StatBlock(value: stats.averageSprintCadence.map { "\(Int($0.rounded()))" } ?? "—", unit: stats.averageSprintCadence == nil ? nil : "spm", label: "Sprint cadence", size: 20)
                    }
                    GridRow {
                        StatBlock(value: stats.averageTimeToPeak.map { "\(Format.fixed($0, decimals: 1))" } ?? "—", unit: stats.averageTimeToPeak == nil ? nil : "s", label: "Avg time to peak", size: 20)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }
}

// MARK: - Fade chart

/// Average speed of each sprint (bars) with its peak (dots): where you slow down.
struct SprintFadeChart: View {
    let details: [SprintDetail]
    let unit: DistanceUnit
    var fade: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sprint by sprint")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        legend(color: Theme.accent, text: "Avg speed")
                        legend(color: Theme.textPrimary, text: "Peak")
                        Spacer()
                        if let fade {
                            Text("Fade \(percentText(fade))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(fade < -0.05 ? Theme.danger : Theme.textSecondary)
                        }
                    }
                    Chart {
                        ForEach(details) { detail in
                            BarMark(
                                x: .value("Sprint", "\(detail.number)"),
                                y: .value("Avg speed", unit.speed(fromMetersPerSecond: detail.averageSpeed))
                            )
                            .foregroundStyle(Theme.accent.gradient)
                            .cornerRadius(4)
                            PointMark(
                                x: .value("Sprint", "\(detail.number)"),
                                y: .value("Peak", unit.speed(fromMetersPerSecond: detail.peakSpeed))
                            )
                            .foregroundStyle(Theme.textPrimary)
                            .symbolSize(28)
                        }
                    }
                    .chartYAxisLabel(unit.speedAbbreviation)
                    .chartXAxisLabel("Sprint")
                    .frame(height: 180)
                }
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Sprint table

/// One row per sprint: distance, time, average and peak speed, then the details.
struct SprintTable: View {
    let details: [SprintDetail]
    let unit: DistanceUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sprints")
            Card {
                VStack(spacing: 0) {
                    HStack {
                        Text("#").frame(width: 26, alignment: .leading)
                        Text("Dist").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Time").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Avg").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Peak").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(Theme.label)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 6)

                    ForEach(details) { detail in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(detail.number)")
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 26, alignment: .leading)
                                Text(Format.distance(detail.segment.distance, unit: unit))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Format.duration(detail.segment.duration))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Format.speed(detail.averageSpeed, unit: unit))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Text(Format.speed(detail.peakSpeed, unit: unit))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.system(size: 16, weight: .semibold).monospacedDigit())
                            Text(detailLine(detail))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.leading, 26)
                        }
                        .padding(.vertical, 10)
                        if detail.id != details.last?.id {
                            Divider().overlay(Theme.hairline)
                        }
                    }

                    Text("Distance in \(unit.abbreviation), speed in \(unit.speedAbbreviation)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func detailLine(_ d: SprintDetail) -> String {
        var parts = ["peak at \(Format.fixed(d.timeToPeak, decimals: 0)) s"]
        if let cadence = d.averageCadence { parts.append("\(Int(cadence.rounded())) spm") }
        if d.climb >= 0.5 { parts.append("+\(Format.elevation(d.climb, unit: unit)) \(unit.elevationAbbreviation)") }
        if let fade = d.inSprintFade { parts.append("fade \(percentText(fade))") }
        if let rest = d.restAfter {
            parts.append("then walked \(Format.duration(rest.duration))")
        }
        return parts.joined(separator: " · ")
    }
}
