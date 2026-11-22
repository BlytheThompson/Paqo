import Foundation
import Observation
import PaqoCore

/// One run before and after re-processing from its sensor log.
struct ReprocessItem: Identifiable, Sendable {
    let id: UUID
    let before: RunSummary
    let after: Run
    let afterSummary: RunSummary
}

/// The user's saved runs, totals and records.
@MainActor
@Observable
final class RunLibrary {
    private(set) var summaries: [RunSummary] = []
    private(set) var records = PersonalRecords()

    let store: RunStore?
    /// Raw sensor logs, one folder per run (kept for the most recent runs).
    let logs: SensorLogStore?
    /// Automatic and manual backups.
    let backup = BackupService()

    /// How many sensor logs to keep.
    static let sensorLogLimit = 20

    init() {
        store = try? RunStore(directory: RunStore.defaultDirectory())
        logs = try? SensorLogStore(directory: RunStore.defaultDirectory().appendingPathComponent("sensor-logs", isDirectory: true))
        reload()
        backup.retryPending(library: self)
    }

    func reload() {
        summaries = (try? store?.loadSummaries()) ?? []
        records = PersonalRecords.compute(from: summaries, now: Date(), calendar: .current)
    }

    @discardableResult
    func save(_ run: Run) -> RunSummary? {
        let summary = try? store?.save(run)
        reload()
        backup.didSave([run], library: self)
        return summary
    }

    func loadRun(id: UUID) -> Run? {
        try? store?.loadRun(id: id)
    }

    func allRuns() -> [Run] {
        summaries.compactMap { loadRun(id: $0.id) }
    }

    func delete(id: UUID) {
        try? store?.delete(id: id)
        logs?.delete(runID: id)
        reload()
        backup.didDelete(id, library: self)
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var run = loadRun(id: id) else { return }
        run.name = trimmed
        save(run)
    }

    /// Adds runs that aren't here yet; runs with the same id are skipped.
    func importRuns(_ runs: [Run]) -> (imported: Int, skipped: Int) {
        guard let store else { return (0, runs.count) }
        let known = Set(summaries.map(\.id))
        let result = (try? store.importRuns(runs)) ?? (0, 0)
        reload()
        backup.didSave(runs.filter { !known.contains($0.id) }, library: self)
        return result
    }

    func totals(_ period: PeriodKind, count: Int) -> [PeriodTotal] {
        Stats.totals(for: summaries, period: period, count: count, now: Date(), calendar: .current)
    }

    func summary(id: UUID) -> RunSummary? {
        summaries.first { $0.id == id }
    }

    /// Every run's simplified route, built off the main thread (old runs fill the cache
    /// the first time).
    func heatmapRoutes() async -> [HeatmapRoute] {
        guard let directory = store?.directory else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? RunStore(directory: directory).loadHeatmapRoutes()) ?? []
        }.value
    }

    // MARK: - Sensor logs and re-processing

    func hasSensorLog(_ id: UUID) -> Bool {
        logs?.hasLog(for: id) ?? false
    }

    /// Runs that still have a sensor log but were measured by older detection settings.
    func reprocessCandidates() -> [UUID] {
        guard let logs else { return [] }
        let known = Set(summaries.map(\.id))
        return logs.runIDs().filter { id in
            guard known.contains(id), let run = loadRun(id: id) else { return false }
            return (run.engineVersion ?? 1) < RunEngine.version
        }
    }

    /// Re-runs each run through today's detection, without saving anything.
    func reprocessPreview(ids: [UUID]) async -> [ReprocessItem] {
        guard let logs else { return [] }
        var inputs: [(Run, SensorLog, RunSummary)] = []
        for id in ids {
            guard let run = loadRun(id: id), let log = try? logs.load(runID: id) else { continue }
            inputs.append((run, log, summary(id: id) ?? RunSummary(run: run)))
        }
        let work = inputs
        return await Task.detached(priority: .userInitiated) {
            work.map { run, log, before in
                let after = Reprocessor.reprocess(run, log: log)
                return ReprocessItem(id: run.id, before: before, after: after, afterSummary: RunSummary(run: after))
            }
        }.value
    }

    func applyReprocessed(_ runs: [Run]) {
        for run in runs { save(run) }
    }

    func sensorLogArchive(for id: UUID) -> URL? {
        guard let logs else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paqo-sensor-log-\(id.uuidString.prefix(8).lowercased()).zip")
        try? FileManager.default.removeItem(at: url)
        return (try? logs.archive(runID: id, to: url)) == nil ? nil : url
    }
}
