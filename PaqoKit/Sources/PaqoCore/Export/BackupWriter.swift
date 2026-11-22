import Foundation

/// Mirrors runs into a backup folder the owner picked (for example in iCloud Drive or
/// OneDrive), in the layout described in README.txt:
///
///     <root>/Paqo Backup/README.txt
///     <root>/Paqo Backup/runs.csv
///     <root>/Paqo Backup/sprints.csv
///     <root>/Paqo Backup/runs/<base>.json and .gpx
///     <root>/Paqo Backup/deleted/
///
/// It only ever touches the run that changed, so a freshly reinstalled, empty Paqo
/// can't shrink or wipe an existing backup. Nothing is ever erased: a deleted run's
/// files move to `deleted/`. When a CSV no longer matches (unit switched, file
/// damaged) it is rebuilt from the JSON files in the folder, never from the app.
public enum BackupError: Error, Equatable {
    /// The file is in the cloud but not on this phone yet; try again later.
    case notDownloaded(String)
    /// The file is there but couldn't be read.
    case unreadable(String)
}

public struct BackupWriter: Sendable {
    public static let folderName = "Paqo Backup"
    public let root: URL
    /// The "Paqo Backup" folder itself. If the owner picked that folder (say after a
    /// reinstall), it is used as-is instead of nesting a new one inside it.
    let base: URL

    public init(root: URL) {
        self.root = root
        let pickedBackupItself = root.lastPathComponent == Self.folderName
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.csv").path)
        base = pickedBackupItself ? root : root.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    var runsFolder: URL { base.appendingPathComponent("runs", isDirectory: true) }
    var deletedFolder: URL { base.appendingPathComponent("deleted", isDirectory: true) }

    /// "2026-11-22-0712-1a2b3c4d": local start time plus the start of the id. Stable
    /// across renames; never contains the run's name.
    public static func baseName(for run: Run, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: run.startDate) + "-" + idSuffix(run.id)
    }

    static func idSuffix(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    // MARK: - Mirror

    public func save(_ run: Run, unit: DistanceUnit, timeZone: TimeZone) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runsFolder, withIntermediateDirectories: true)
        let name = Self.baseName(for: run, timeZone: timeZone)
        for file in filesForRun(run.id, in: runsFolder) where !file.lastPathComponent.hasPrefix(name + ".") {
            try? fm.removeItem(at: file)
        }
        try RunJSON.encode(run).write(to: runsFolder.appendingPathComponent(name + ".json"), options: .atomic)
        try Data(GPX.document(for: run).utf8).write(to: runsFolder.appendingPathComponent(name + ".gpx"), options: .atomic)

        try merge(
            file: "runs.csv",
            header: BackupCSV.runsHeader(unit: unit),
            removing: run.id,
            adding: [BackupCSV.runRow(run, unit: unit, timeZone: timeZone)],
            unit: unit,
            timeZone: timeZone
        )
        try merge(
            file: "sprints.csv",
            header: BackupCSV.sprintsHeader(unit: unit),
            removing: run.id,
            adding: BackupCSV.sprintRows(run, unit: unit, timeZone: timeZone),
            unit: unit,
            timeZone: timeZone
        )
        try Data(BackupReadme.text(unit: unit).utf8).write(to: base.appendingPathComponent("README.txt"), options: .atomic)
    }

    public func delete(runID: UUID, unit: DistanceUnit = .miles, timeZone: TimeZone = .current) throws {
        let fm = FileManager.default
        let files = filesForRun(runID, in: runsFolder)
        if !files.isEmpty {
            try fm.createDirectory(at: deletedFolder, withIntermediateDirectories: true)
            for file in files {
                let target = deletedFolder.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: target)
                try fm.moveItem(at: file, to: target)
            }
        }
        // Keep whatever unit the CSVs already use.
        let currentUnit = existingUnit() ?? unit
        try merge(file: "runs.csv", header: BackupCSV.runsHeader(unit: currentUnit), removing: runID, adding: [], unit: currentUnit, timeZone: timeZone)
        try merge(file: "sprints.csv", header: BackupCSV.sprintsHeader(unit: currentUnit), removing: runID, adding: [], unit: currentUnit, timeZone: timeZone)
    }

    /// Rebuilds both CSVs from the JSON files in `runs/`. Throws rather than writing a
    /// shorter CSV when a run file is in the cloud but not downloaded, or unreadable.
    public func rebuildCSVs(unit: DistanceUnit, timeZone: TimeZone) throws {
        let runs = try jsonRuns()
        var runRows: [[String]] = []
        var sprintRows: [[String]] = []
        for run in runs {
            runRows.append(BackupCSV.runRow(run, unit: unit, timeZone: timeZone))
            sprintRows += BackupCSV.sprintRows(run, unit: unit, timeZone: timeZone)
        }
        try writeCSV("runs.csv", header: BackupCSV.runsHeader(unit: unit), rows: runRows)
        try writeCSV("sprints.csv", header: BackupCSV.sprintsHeader(unit: unit), rows: sprintRows)
    }

    // MARK: - Archive

    /// The same layout, zipped (stored, not compressed) for sharing.
    public static func exportArchive(runs: [Run], unit: DistanceUnit, timeZone: TimeZone, to zipURL: URL, folderName: String) throws {
        let writer = try ZipWriter(url: zipURL)
        let now = Date()
        let ordered = runs.sorted { $0.startDate < $1.startDate }
        var runRows: [[String]] = []
        var sprintRows: [[String]] = []
        for run in ordered {
            runRows.append(BackupCSV.runRow(run, unit: unit, timeZone: timeZone))
            sprintRows += BackupCSV.sprintRows(run, unit: unit, timeZone: timeZone)
        }
        let prefix = folderName + "/"
        try writer.add(path: prefix + "README.txt", data: Data(BackupReadme.text(unit: unit).utf8), modified: now)
        try writer.add(path: prefix + "runs.csv", data: csvData(header: BackupCSV.runsHeader(unit: unit), rows: runRows), modified: now)
        try writer.add(path: prefix + "sprints.csv", data: csvData(header: BackupCSV.sprintsHeader(unit: unit), rows: sprintRows), modified: now)
        for run in ordered {
            let name = baseName(for: run, timeZone: timeZone)
            try writer.add(path: prefix + "runs/" + name + ".json", data: RunJSON.encode(run), modified: run.startDate)
            try writer.add(path: prefix + "runs/" + name + ".gpx", data: Data(GPX.document(for: run).utf8), modified: run.startDate)
        }
        try writer.finish()
    }

    // MARK: - Helpers

    func filesForRun(_ id: UUID, in folder: URL) -> [URL] {
        let suffix = "-" + Self.idSuffix(id)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { url in
            let stem = url.deletingPathExtension().lastPathComponent
            return stem.hasSuffix(suffix) && (url.pathExtension == "json" || url.pathExtension == "gpx")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func jsonRuns() throws -> [Run] {
        let items = (try? FileManager.default.contentsOfDirectory(at: runsFolder, includingPropertiesForKeys: nil)) ?? []
        var runs: [Run] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            if let original = Self.evictedName(name), original.hasSuffix(".json") {
                throw BackupError.notDownloaded(original)
            }
            guard item.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: item) else { throw BackupError.unreadable(name) }
            // A file that isn't a Paqo run can't be listed anyway; skip it.
            if let run = try? RunJSON.decode(data) { runs.append(run) }
        }
        return runs.sorted { $0.startDate < $1.startDate }
    }

    /// Files in the backup that are in the cloud but not on this phone (their real
    /// names), so the app can ask for them to be downloaded before retrying.
    public func evictedItems() -> [URL] {
        [base, runsFolder].flatMap { folder -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.sorted().compactMap { Self.evictedName($0).map { folder.appendingPathComponent($0) } }
        }
    }

    /// iCloud leaves ".name.icloud" in place of a file it moved off the phone.
    static func evictedName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    func existingUnit() -> DistanceUnit? {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("runs.csv")),
              let header = CSV.parse(String(decoding: data, as: UTF8.self)).first else { return nil }
        if header == BackupCSV.runsHeader(unit: .miles) { return .miles }
        if header == BackupCSV.runsHeader(unit: .kilometers) { return .kilometers }
        return nil
    }

    func merge(file: String, header: [String], removing id: UUID, adding: [[String]], unit: DistanceUnit, timeZone: TimeZone) throws {
        let url = base.appendingPathComponent(file)
        let fm = FileManager.default
        var rows: [[String]] = []
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { throw BackupError.unreadable(file) }
            let parsed = CSV.parse(String(decoding: data, as: UTF8.self))
            let body = Array(parsed.dropFirst())
            guard parsed.first == header, body.allSatisfy({ $0.count == header.count }) else {
                // Doesn't match (unit switched or damaged): rebuild from the folder's JSON.
                try rebuildCSVs(unit: unit, timeZone: timeZone)
                return
            }
            rows = body
        } else if fm.fileExists(atPath: base.appendingPathComponent("." + file + ".icloud").path) {
            // In the cloud but not on this phone: wait rather than replace it with less.
            throw BackupError.notDownloaded(file)
        } else {
            // Missing (deleted or moved on the computer): rebuild from the folder's JSON.
            try rebuildCSVs(unit: unit, timeZone: timeZone)
            return
        }
        let idText = id.uuidString
        rows.removeAll { $0.first == idText }
        rows += adding
        // runs.csv sorts by UTC start; sprints.csv by local start, then sprint number.
        let sortColumn = file == "runs.csv" ? 3 : 2
        rows = rows.enumerated().sorted { a, b in
            let x = a.element[sortColumn], y = b.element[sortColumn]
            if x != y { return x < y }
            if file == "sprints.csv", let i = Int(a.element[3]), let j = Int(b.element[3]), i != j { return i < j }
            return a.offset < b.offset
        }.map(\.element)
        try writeCSV(file, header: header, rows: rows)
    }

    func writeCSV(_ file: String, header: [String], rows: [[String]]) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Self.csvData(header: header, rows: rows).write(to: base.appendingPathComponent(file), options: .atomic)
    }

    static func csvData(header: [String], rows: [[String]]) -> Data {
        var text = CSV.byteOrderMark + CSV.line(header)
        for row in rows { text += CSV.line(row) }
        return Data(text.utf8)
    }
}
