import Foundation
import Observation
import PaqoCore

/// Automatic backups into a folder the owner picks (iCloud Drive, OneDrive, On My
/// iPhone…), plus manual export and import.
///
/// Only the run that changed is ever written; nothing in the backup is erased (a
/// deleted run's files move to `deleted/`). Writes that fail are remembered and
/// retried with the next save.
@MainActor
@Observable
final class BackupService {
    private(set) var folderName: String?
    private(set) var lastBackup: Date?
    private(set) var problem: String?
    private(set) var isWorking = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var chain: Task<Void, Never>?

    init() {
        lastBackup = defaults.object(forKey: SettingsKey.lastBackupDate) as? Date
        if let url = resolveFolder(reportProblems: false) {
            folderName = url.lastPathComponent
        }
    }

    var isEnabled: Bool { defaults.data(forKey: SettingsKey.backupBookmark) != nil }

    // MARK: - Folder

    /// Remembers the folder and backs up every run into it.
    func chooseFolder(_ url: URL, library: RunLibrary) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: SettingsKey.backupBookmark)
            folderName = url.lastPathComponent
            problem = nil
            pendingSaves = Set(library.summaries.map(\.id)).union(pendingSaves)
            runPending(library: library)
        } catch {
            problem = "Paqo couldn't keep access to that folder. Try another one."
        }
    }

    func forgetFolder() {
        defaults.removeObject(forKey: SettingsKey.backupBookmark)
        pendingSaves = []
        pendingDeletes = []
        folderName = nil
        problem = nil
    }

    // MARK: - Changes

    func didSave(_ runs: [Run], library: RunLibrary) {
        guard isEnabled else { return }
        pendingSaves.formUnion(runs.map(\.id))
        runPending(library: library)
    }

    func didDelete(_ id: UUID, library: RunLibrary) {
        guard isEnabled else { return }
        pendingSaves.remove(id)
        pendingDeletes.insert(id)
        runPending(library: library)
    }

    func retryPending(library: RunLibrary) {
        guard isEnabled, !pendingSaves.isEmpty || !pendingDeletes.isEmpty else { return }
        runPending(library: library)
    }

    private func runPending(library: RunLibrary) {
        guard let folder = resolveFolder(reportProblems: true) else { return }
        let saves = pendingSaves.sorted { $0.uuidString < $1.uuidString }
        let deletes = pendingDeletes.sorted { $0.uuidString < $1.uuidString }
        let runs = saves.compactMap { library.loadRun(id: $0) }
        // Runs that no longer exist locally can't be backed up; drop them.
        let missing = Set(saves).subtracting(runs.map(\.id))
        pendingSaves.subtract(missing)
        guard !runs.isEmpty || !deletes.isEmpty else { return }

        let unit = defaults.distanceUnit
        let timeZone = TimeZone.current
        let previous = chain
        isWorking = true
        chain = Task { [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .utility) {
                BackupService.write(folder: folder, runs: runs, deletions: deletes, unit: unit, timeZone: timeZone)
            }.value
            self?.finish(result, saved: runs.map(\.id), deleted: deletes)
        }
    }

    private func finish(_ result: WriteResult, saved: [UUID], deleted: [UUID]) {
        pendingSaves.subtract(Set(saved).subtracting(result.failedSaves))
        pendingDeletes.subtract(Set(deleted).subtracting(result.failedDeletes))
        if let message = result.error {
            let count = result.failedSaves.count + result.failedDeletes.count
            problem = "Couldn't back up \(count) run\(count == 1 ? "" : "s"): \(message). Paqo will try again after your next run."
        } else {
            problem = nil
            lastBackup = Date()
            defaults.set(lastBackup, forKey: SettingsKey.lastBackupDate)
        }
        isWorking = false
    }

    struct WriteResult: Sendable {
        var failedSaves: [UUID] = []
        var failedDeletes: [UUID] = []
        var error: String?
    }

    nonisolated static func write(folder: URL, runs: [Run], deletions: [UUID], unit: DistanceUnit, timeZone: TimeZone) -> WriteResult {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        var result = WriteResult(failedSaves: runs.map(\.id), failedDeletes: deletions, error: nil)
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinatorError) { url in
            let writer = BackupWriter(root: url)
            result.failedSaves = []
            result.failedDeletes = []
            for run in runs {
                do { try writer.save(run, unit: unit, timeZone: timeZone) } catch {
                    result.failedSaves.append(run.id)
                    result.error = error.localizedDescription
                }
            }
            for id in deletions {
                do { try writer.delete(runID: id, unit: unit, timeZone: timeZone) } catch {
                    result.failedDeletes.append(id)
                    result.error = error.localizedDescription
                }
            }
        }
        if let coordinatorError { result.error = coordinatorError.localizedDescription }
        return result
    }

    // MARK: - Export and import

    /// Every run as one zip (CSV, JSON, GPX and a README), ready for the share sheet.
    func exportAll(library: RunLibrary) async throws -> URL {
        let runs = library.allRuns()
        let unit = defaults.distanceUnit
        let timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Paqo Backup \(formatter.string(from: Date())).zip")
        try? FileManager.default.removeItem(at: url)
        try await Task.detached(priority: .userInitiated) {
            try BackupWriter.exportArchive(runs: runs, unit: unit, timeZone: timeZone, to: url, folderName: BackupWriter.folderName)
        }.value
        return url
    }

    /// Imports runs from picked folders, zips or JSON files. Returns a message for the owner.
    func importRuns(from urls: [URL], library: RunLibrary) async -> String {
        let batch = await Task.detached(priority: .userInitiated) { () -> ImportBatch in
            let accessing = urls.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (url, didAccess) in zip(urls, accessing) where didAccess { url.stopAccessingSecurityScopedResource() }
            }
            return BackupImporter.runs(from: urls)
        }.value
        let result = library.importRuns(batch.runs)
        var lines: [String] = []
        if result.imported == 0 && result.skipped == 0 {
            lines.append("No runs found.")
        } else {
            var text = "Imported \(result.imported) run\(result.imported == 1 ? "" : "s")"
            if result.skipped > 0 {
                text += ", \(result.skipped) \(result.skipped == 1 ? "was" : "were") already here"
            }
            lines.append(text + ".")
        }
        lines += batch.problems.prefix(3)
        if batch.problems.count > 3 { lines.append("…and \(batch.problems.count - 3) more files Paqo couldn't read.") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func resolveFolder(reportProblems: Bool) -> URL? {
        guard let data = defaults.data(forKey: SettingsKey.backupBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            if reportProblems { problem = "Paqo can't reach the backup folder. Choose it again." }
            return nil
        }
        if stale {
            let accessing = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: SettingsKey.backupBookmark)
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    private var pendingSaves: Set<UUID> {
        get { ids(SettingsKey.pendingBackupIDs) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: SettingsKey.pendingBackupIDs) }
    }

    private var pendingDeletes: Set<UUID> {
        get { ids(SettingsKey.pendingDeleteIDs) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: SettingsKey.pendingDeleteIDs) }
    }

    private func ids(_ key: String) -> Set<UUID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }
}
