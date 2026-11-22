import PaqoCore
import SwiftUI

struct RecordsView: View {
    @Environment(RunLibrary.self) private var library
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault

    var body: some View {
        let records = library.records
        NavigationStack {
            List {
                Section(header: header("Fastest")) {
                    ForEach(EffortDistance.standard) { effort in
                        let entry = records.fastest.first { $0.distance == effort }?.entry
                        RecordRow(
                            title: effort.label,
                            value: entry.map { Format.duration($0.value) },
                            detail: entry.map { "\(Format.pace(secondsPerMeter: $0.value / effort.meters, unit: unit)) \(unit.paceSuffix)" },
                            entry: entry
                        )
                    }
                }

                Section(header: header("Distance")) {
                    RecordRow(
                        title: "Longest run",
                        value: records.longestDistance.map { "\(Format.distance($0.value, unit: unit)) \(unit.abbreviation)" },
                        entry: records.longestDistance
                    )
                    RecordRow(
                        title: "Longest time",
                        value: records.longestDuration.map { Format.duration($0.value) },
                        entry: records.longestDuration
                    )
                }

                Section(header: header("Sprints")) {
                    RecordRow(
                        title: "Top speed",
                        value: records.topSpeed.map { "\(Format.speed($0.value, unit: unit)) \(unit.speedAbbreviation)" },
                        entry: records.topSpeed
                    )
                    RecordRow(
                        title: "Fastest sprint (avg)",
                        value: records.fastestSprint.map { "\(Format.speed($0.value, unit: unit)) \(unit.speedAbbreviation)" },
                        detail: records.fastestSprint == nil ? nil : "Sprints of 10 s or more",
                        entry: records.fastestSprint
                    )
                    RecordRow(
                        title: "Longest sprint",
                        value: records.longestSprintDistance.map { "\(Format.distance($0.value, unit: unit)) \(unit.abbreviation)" },
                        entry: records.longestSprintDistance
                    )
                    RecordRow(
                        title: "Longest sprint time",
                        value: records.longestSprintDuration.map { Format.duration($0.value) },
                        entry: records.longestSprintDuration
                    )
                    RecordRow(
                        title: "Most sprints in a run",
                        value: records.mostSprints.map { "\(Int($0.value))" },
                        entry: records.mostSprints
                    )
                }

                Section(header: header("Streaks")) {
                    RecordRow(
                        title: "Current streak",
                        value: records.isEmpty ? nil : weeks(records.currentWeekStreak),
                        entry: nil
                    )
                    RecordRow(
                        title: "Longest streak",
                        value: records.isEmpty ? nil : weeks(records.longestWeekStreak),
                        entry: nil
                    )
                    RecordRow(
                        title: "Biggest week",
                        value: records.biggestWeek.map { "\(Format.distance($0.value, unit: unit)) \(unit.abbreviation)" },
                        detail: records.biggestWeek.map { "Week of \($0.date.formatted(.dateTime.month(.abbreviated).day()))" },
                        entry: nil
                    )
                    RecordRow(
                        title: "Biggest month",
                        value: records.biggestMonth.map { "\(Format.distance($0.value, unit: unit)) \(unit.abbreviation)" },
                        detail: records.biggestMonth.map { $0.date.formatted(.dateTime.month(.wide).year()) },
                        entry: nil
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Records")
            .navigationDestination(for: UUID.self) { id in
                RunDetailLoader(id: id)
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Theme.label)
            .foregroundStyle(Theme.textSecondary)
    }

    private func weeks(_ count: Int) -> String {
        count == 1 ? "1 week" : "\(count) weeks"
    }
}

struct RecordRow: View {
    let title: String
    let value: String?
    var detail: String? = nil
    let entry: RecordEntry?

    var body: some View {
        if let runID = entry?.runID {
            NavigationLink(value: runID) { content }
                .listRowBackground(Theme.surface)
        } else {
            content
                .listRowBackground(Theme.surface)
        }
    }

    private var content: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let date = entry?.date, entry?.runID != nil {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else if let detail, entry == nil {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(value ?? "—")
                    .font(Theme.number(17))
                    .foregroundStyle(value == nil ? Theme.textSecondary : Theme.textPrimary)
                if let detail, entry != nil {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
