import Foundation
import Observation
import PaqoCore

/// The user's saved runs, totals and records.
@MainActor
@Observable
final class RunLibrary {
    private(set) var summaries: [RunSummary] = []
    private(set) var records = PersonalRecords()

    let store: RunStore?
    /// Raw sensor logs, one folder per run (kept for the most recent runs).
    let logs: SensorLogStore?

    /// How many sensor logs to keep.
    static let sensorLogLimit = 20

    init() {
        store = try? RunStore(directory: RunStore.defaultDirectory())
        logs = try? SensorLogStore(directory: RunStore.defaultDirectory().appendingPathComponent("sensor-logs", isDirectory: true))
        reload()
    }

    func reload() {
        summaries = (try? store?.loadSummaries()) ?? []
        records = PersonalRecords.compute(from: summaries, now: Date(), calendar: .current)
    }

    @discardableResult
    func save(_ run: Run) -> RunSummary? {
        let summary = try? store?.save(run)
        reload()
        return summary
    }

    func loadRun(id: UUID) -> Run? {
        try? store?.loadRun(id: id)
    }

    func delete(id: UUID) {
        try? store?.delete(id: id)
        logs?.delete(runID: id)
        reload()
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var run = loadRun(id: id) else { return }
        run.name = trimmed
        save(run)
    }

    func totals(_ period: PeriodKind, count: Int) -> [PeriodTotal] {
        Stats.totals(for: summaries, period: period, count: count, now: Date(), calendar: .current)
    }

    func summary(id: UUID) -> RunSummary? {
        summaries.first { $0.id == id }
    }
}
