import Foundation

/// Saves runs on the device as JSON:
///
///     <directory>/index.json          summaries of every run (fast to load)
///     <directory>/runs/<id>.json      full run with route
///     <directory>/in-progress.json    autosave of the run being recorded
///     <directory>/heatmap.json        simplified routes of every run (rebuildable)
///
/// Not thread-safe; use from one actor (the app uses it on the main actor).
public final class RunStore {
    public let directory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        encoder = JSONEncoder()
        try fileManager.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
    }

    /// Application Support/Paqo on iOS and macOS.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Paqo", isDirectory: true)
    }

    var runsDirectory: URL { directory.appendingPathComponent("runs", isDirectory: true) }
    var indexURL: URL { directory.appendingPathComponent("index.json") }
    var inProgressURL: URL { directory.appendingPathComponent("in-progress.json") }
    var heatmapURL: URL { directory.appendingPathComponent("heatmap.json") }
    func runURL(_ id: UUID) -> URL { runsDirectory.appendingPathComponent("\(id.uuidString).json") }

    // MARK: - Runs

    /// All summaries, newest first. Rebuilds the index from run files if it is missing
    /// or unreadable.
    public func loadSummaries() throws -> [RunSummary] {
        if let data = try? Data(contentsOf: indexURL),
           let summaries = try? decoder.decode([RunSummary].self, from: data) {
            return summaries.sorted { $0.startDate > $1.startDate }
        }
        return try rebuildIndex()
    }

    @discardableResult
    public func save(_ run: Run) throws -> RunSummary {
        try write(run, to: runURL(run.id))
        let summary = RunSummary(run: run)
        var summaries = (try? loadSummaries()) ?? []
        summaries.removeAll { $0.id == run.id }
        summaries.append(summary)
        try writeIndex(summaries)
        updateHeatmapCache { routes in
            routes.removeAll { $0.id == run.id }
            routes.append(HeatmapBuilder.route(for: run))
        }
        return summary
    }

    public func loadRun(id: UUID) throws -> Run {
        let data = try Data(contentsOf: runURL(id))
        return try decoder.decode(Run.self, from: data)
    }

    public func delete(id: UUID) throws {
        let url = runURL(id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        var summaries = (try? loadSummaries()) ?? []
        summaries.removeAll { $0.id == id }
        try writeIndex(summaries)
        updateHeatmapCache { routes in routes.removeAll { $0.id == id } }
    }

    // MARK: - Heatmap

    /// Every run's simplified route, oldest first. Fills in runs missing from the
    /// cache (old runs, or a deleted cache) and drops runs that no longer exist.
    public func loadHeatmapRoutes() throws -> [HeatmapRoute] {
        var routes = cachedHeatmap() ?? []
        let summaries = try loadSummaries()
        let ids = Set(summaries.map(\.id))
        var changed = routes.contains { !ids.contains($0.id) }
        routes.removeAll { !ids.contains($0.id) }
        let cached = Set(routes.map(\.id))
        for summary in summaries where !cached.contains(summary.id) {
            guard let run = try? loadRun(id: summary.id) else { continue }
            routes.append(HeatmapBuilder.route(for: run))
            changed = true
        }
        if changed || !fileManager.fileExists(atPath: heatmapURL.path) {
            try? write(routes, to: heatmapURL)
        }
        return routes.sorted { $0.startDate < $1.startDate }
    }

    func cachedHeatmap() -> [HeatmapRoute]? {
        guard let data = try? Data(contentsOf: heatmapURL) else { return nil }
        return try? decoder.decode([HeatmapRoute].self, from: data)
    }

    /// Keeps an existing cache in step; a missing cache is built when first needed.
    func updateHeatmapCache(_ change: (inout [HeatmapRoute]) -> Void) {
        guard var routes = cachedHeatmap() else { return }
        change(&routes)
        try? write(routes, to: heatmapURL)
    }

    @discardableResult
    public func rebuildIndex() throws -> [RunSummary] {
        let files = (try? fileManager.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        var summaries: [RunSummary] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let run = try? decoder.decode(Run.self, from: data) else { continue }
            summaries.append(RunSummary(run: run))
        }
        try writeIndex(summaries)
        return summaries.sorted { $0.startDate > $1.startDate }
    }

    // MARK: - In-progress autosave

    public func saveInProgress(_ engine: RunEngine) throws {
        try write(engine, to: inProgressURL)
    }

    public func loadInProgress() -> RunEngine? {
        guard let data = try? Data(contentsOf: inProgressURL) else { return nil }
        return try? decoder.decode(RunEngine.self, from: data)
    }

    public func clearInProgress() {
        try? fileManager.removeItem(at: inProgressURL)
    }

    // MARK: - Helpers

    private func writeIndex(_ summaries: [RunSummary]) throws {
        try write(summaries.sorted { $0.startDate > $1.startDate }, to: indexURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
