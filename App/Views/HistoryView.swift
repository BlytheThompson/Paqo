import Charts
import PaqoCore
import SwiftUI

struct HistoryView: View {
    @Environment(RunLibrary.self) private var library
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault
    @State private var period: PeriodKind = .week

    private struct MonthGroup: Identifiable {
        let id: Date
        let title: String
        let runs: [RunSummary]
    }

    enum Mode: Hashable {
        case list, map
    }

    @State private var mode: Mode = .list

    var body: some View {
        NavigationStack {
            Group {
                if mode == .map {
                    HeatmapView()
                } else {
                    runList
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $mode) {
                        Image(systemName: "list.bullet").tag(Mode.list)
                        Image(systemName: "map").tag(Mode.map)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .accessibilityLabel("List or map")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                RunDetailLoader(id: id)
            }
        }
    }

    private var runList: some View {
        List {
            Section {
                TotalsCard(period: $period, unit: unit)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ForEach(monthGroups) { group in
                Section {
                    ForEach(group.runs) { summary in
                        NavigationLink(value: summary.id) {
                            RunRow(summary: summary, unit: unit)
                        }
                        .listRowBackground(Theme.surface)
                        .swipeActions {
                            Button(role: .destructive) {
                                library.delete(id: summary.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                        .font(Theme.label)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if library.summaries.isEmpty {
                ContentUnavailableView(
                    "No runs yet",
                    systemImage: "figure.run",
                    description: Text("Tap Start on the Run tab. Your runs will show up here.")
                )
            }
        }
    }

    private var monthGroups: [MonthGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: library.summaries) { summary in
            calendar.dateInterval(of: .month, for: summary.startDate)?.start ?? summary.startDate
        }
        return grouped.keys.sorted(by: >).map { month in
            MonthGroup(
                id: month,
                title: month.formatted(.dateTime.month(.wide).year()),
                runs: (grouped[month] ?? []).sorted { $0.startDate > $1.startDate }
            )
        }
    }
}

struct RunRow: View {
    let summary: RunSummary
    let unit: DistanceUnit

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.name)
                    .font(.headline)
                Text(summary.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Format.distance(summary.distance, unit: unit)) \(unit.abbreviation)")
                    .font(Theme.number(17))
                HStack(spacing: 6) {
                    Text(Format.duration(summary.movingTime))
                    if summary.sprintCount > 0 {
                        Text("· \(summary.sprintCount) \(summary.sprintCount == 1 ? "sprint" : "sprints")")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Week / month / year totals with a small bar chart of recent periods.
struct TotalsCard: View {
    @Binding var period: PeriodKind
    let unit: DistanceUnit
    @Environment(RunLibrary.self) private var library

    var body: some View {
        let totals = library.totals(period, count: barCount)
        let current = totals.last
        VStack(alignment: .leading, spacing: 16) {
            Picker("Period", selection: $period) {
                ForEach(PeriodKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                StatBlock(value: Format.distance(current?.distance ?? 0, unit: unit), unit: unit.abbreviation, label: "This \(period.displayName.lowercased())", size: 36)
                StatBlock(value: "\(current?.runCount ?? 0)", label: "Runs", size: 22)
                StatBlock(value: Format.duration(current?.movingTime ?? 0), label: "Time", size: 22)
            }

            Chart(totals) { total in
                BarMark(
                    x: .value("Period", label(for: total.start)),
                    y: .value("Distance", unit.distance(fromMeters: total.distance))
                )
                .foregroundStyle(total.id == current?.id ? Theme.accent : Theme.accent.opacity(0.3))
                .cornerRadius(4)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(height: 110)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var barCount: Int {
        switch period {
        case .week: return 8
        case .month: return 6
        case .year: return 4
        }
    }

    private func label(for date: Date) -> String {
        switch period {
        case .week: return date.formatted(.dateTime.month(.defaultDigits).day())
        case .month: return date.formatted(.dateTime.month(.abbreviated))
        case .year: return date.formatted(.dateTime.year())
        }
    }
}

/// Loads a full run (with route) for its summary screen.
struct RunDetailLoader: View {
    let id: UUID
    @Environment(RunLibrary.self) private var library
    @State private var run: Run?
    @State private var loaded = false

    var body: some View {
        Group {
            if let run {
                RunSummaryView(run: run)
            } else if loaded {
                ContentUnavailableView("Run not found", systemImage: "questionmark.circle")
            } else {
                ProgressView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: id) {
            run = library.loadRun(id: id)
            loaded = true
        }
    }
}
