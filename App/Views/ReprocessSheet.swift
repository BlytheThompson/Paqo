import PaqoCore
import SwiftUI

/// Re-runs runs through today's detection, shows before → after, and replaces them
/// only if the owner says so.
struct ReprocessSheet: View {
    @Environment(RunLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault

    let ids: [UUID]
    var onReplaced: ([Run]) -> Void = { _ in }

    @State private var items: [ReprocessItem]?

    var body: some View {
        NavigationStack {
            Group {
                if let items {
                    if items.isEmpty {
                        ContentUnavailableView("Nothing to re-process", systemImage: "waveform.path", description: Text("These runs no longer have sensor logs."))
                    } else {
                        list(items)
                    }
                } else {
                    ProgressView("Re-processing…")
                        .tint(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Re-process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ids.count == 1 ? "Replace" : "Replace all") {
                        let runs = (items ?? []).map(\.after)
                        library.applyReprocessed(runs)
                        onReplaced(runs)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(items?.isEmpty ?? true)
                }
            }
            .task {
                items = await library.reprocessPreview(ids: ids)
            }
        }
    }

    private func list(_ items: [ReprocessItem]) -> some View {
        List {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.before.name)
                        .font(.headline)
                    Text(item.before.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    change("Distance",
                           "\(Format.distance(item.before.distance, unit: unit)) \(unit.abbreviation)",
                           "\(Format.distance(item.afterSummary.distance, unit: unit)) \(unit.abbreviation)")
                    change("Sprints", "\(item.before.sprintCount)", "\(item.afterSummary.sprintCount)")
                    change("Peak speed",
                           "\(Format.speed(item.before.topSpeed, unit: unit)) \(unit.speedAbbreviation)",
                           "\(Format.speed(item.afterSummary.topSpeed, unit: unit)) \(unit.speedAbbreviation)")
                    change("Avg sprint speed",
                           "\(Format.speed(item.before.sprintStats.averageSprintSpeed, unit: unit)) \(unit.speedAbbreviation)",
                           "\(Format.speed(item.afterSummary.sprintStats.averageSprintSpeed, unit: unit)) \(unit.speedAbbreviation)")
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.surface)
            }
            Section {
            } footer: {
                Text("Apple Health keeps the original numbers. Your backup folder is updated.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func change(_ label: String, _ before: String, _ after: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(before)
                .foregroundStyle(Theme.textSecondary)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(after)
                .foregroundStyle(before == after ? Theme.textPrimary : Theme.accent)
                .fontWeight(.semibold)
        }
        .font(.subheadline.monospacedDigit())
    }
}
