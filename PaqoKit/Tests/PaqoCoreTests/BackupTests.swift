import Foundation
import XCTest
@testable import PaqoCore

final class BackupTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("paqo-backup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var backup: URL { root.appendingPathComponent("Paqo Backup") }

    func csvRows(_ name: String) throws -> [[String]] {
        CSV.parse(String(decoding: try Data(contentsOf: backup.appendingPathComponent(name)), as: UTF8.self))
    }

    func files(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backup.appendingPathComponent(folder).path)) ?? []).sorted()
    }

    func run(_ day: Int, name: String = "Intervals") -> Run {
        var run = threeSprintRun(start: t0.addingTimeInterval(Double(day) * 86_400))
        run.name = name
        return run
    }

    func testSaveWritesLayout() throws {
        let a = run(0)
        try BackupWriter(root: root).save(a, unit: .miles, timeZone: utc)
        let base = BackupWriter.baseName(for: a, timeZone: utc)
        XCTAssertTrue(base.hasSuffix(String(a.id.uuidString.prefix(8)).lowercased()))
        XCTAssertEqual(files(in: "runs"), [base + ".gpx", base + ".json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("README.txt").path))
        XCTAssertEqual(try csvRows("runs.csv").count, 2)
        XCTAssertEqual(try csvRows("sprints.csv").count, 4)
        XCTAssertEqual(try csvRows("runs.csv")[0], BackupCSV.runsHeader(unit: .miles))
    }

    func testFreshAppCannotShrinkBackup() throws {
        try BackupWriter(root: root).save(run(0), unit: .miles, timeZone: utc)
        try BackupWriter(root: root).save(run(1), unit: .miles, timeZone: utc)
        // A reinstalled, empty Paqo saves its first run into the same folder.
        try BackupWriter(root: root).save(run(2), unit: .miles, timeZone: utc)
        XCTAssertEqual(try csvRows("runs.csv").count, 4)
        XCTAssertEqual(files(in: "runs").filter { $0.hasSuffix(".json") }.count, 3)
    }

    func testRenameReplacesFilesAndRow() throws {
        var a = run(0)
        let writer = BackupWriter(root: root)
        try writer.save(a, unit: .miles, timeZone: utc)
        try writer.save(run(1), unit: .miles, timeZone: utc)
        a.name = "Hill sprints"
        try writer.save(a, unit: .miles, timeZone: utc)
        let rows = try csvRows("runs.csv").dropFirst().filter { $0[0] == a.id.uuidString }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?[1], "Hill sprints")
        XCTAssertEqual(files(in: "runs").filter { $0.contains(String(a.id.uuidString.prefix(8)).lowercased()) }.count, 2)
    }

    func testDeleteMovesToDeletedFolder() throws {
        let a = run(0), b = run(1)
        let writer = BackupWriter(root: root)
        try writer.save(a, unit: .miles, timeZone: utc)
        try writer.save(b, unit: .miles, timeZone: utc)
        try writer.delete(runID: a.id)
        let base = BackupWriter.baseName(for: a, timeZone: utc)
        XCTAssertFalse(files(in: "runs").contains(base + ".json"))
        XCTAssertEqual(files(in: "deleted"), [base + ".gpx", base + ".json"])
        XCTAssertEqual(try csvRows("runs.csv").dropFirst().map { $0[0] }, [b.id.uuidString])
        XCTAssertFalse(try csvRows("sprints.csv").dropFirst().contains { $0[0] == a.id.uuidString })
    }

    func testUnitSwitchRebuildsCSVFromFolderJSON() throws {
        let writer = BackupWriter(root: root)
        try writer.save(run(0), unit: .miles, timeZone: utc)
        try writer.save(run(1), unit: .miles, timeZone: utc)
        try writer.save(run(2), unit: .kilometers, timeZone: utc)
        let rows = try csvRows("runs.csv")
        XCTAssertTrue(rows[0].contains("distance_km"))
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(try csvRows("sprints.csv")[0].contains("distance_km"))
    }

    func testCorruptCSVIsRebuiltFromFolderJSON() throws {
        let writer = BackupWriter(root: root)
        try writer.save(run(0), unit: .miles, timeZone: utc)
        try writer.save(run(1), unit: .miles, timeZone: utc)
        try Data("garbage\u{0}\"unterminated".utf8).write(to: backup.appendingPathComponent("runs.csv"))
        try writer.save(run(2), unit: .miles, timeZone: utc)
        let rows = try csvRows("runs.csv")
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.count == BackupCSV.runsHeader(unit: .miles).count })
    }

    func testArchiveAndImportRoundTrip() throws {
        let runs = [run(0), run(1, name: "Long, slow"), run(2)]
        let zip = root.appendingPathComponent("Paqo Backup 2026-11-22.zip")
        try BackupWriter.exportArchive(runs: runs, unit: .miles, timeZone: utc, to: zip, folderName: "Paqo Backup")
        let batch = BackupImporter.runs(from: [zip])
        XCTAssertEqual(batch.problems, [])
        XCTAssertEqual(batch.runs.map(\.id), runs.map(\.id))
        XCTAssertEqual(batch.runs[1].name, "Long, slow")
        XCTAssertEqual(batch.runs[1].distance, runs[1].distance)
        XCTAssertEqual(batch.runs[1].track.count, runs[1].track.count)

        let store = try RunStore(directory: root.appendingPathComponent("store"))
        try store.save(runs[0])
        let result = try store.importRuns(batch.runs)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(try store.loadSummaries().count, 3)
        XCTAssertEqual(try store.loadHeatmapRoutes().count, 3)
    }

    func testImporterSkipsDeletedFolderAndReportsJunk() throws {
        let writer = BackupWriter(root: root)
        let a = run(0)
        try writer.save(a, unit: .miles, timeZone: utc)
        try writer.delete(runID: a.id)
        try Data("{\"shopping\": [\"milk\"]}".utf8).write(to: backup.appendingPathComponent("notes.json"))

        let batch = BackupImporter.runs(from: [backup])
        XCTAssertEqual(batch.runs.count, 0)
        XCTAssertEqual(batch.problems.count, 1)
        XCTAssertTrue(batch.problems[0].contains("notes.json"))

        // Picking the deleted folder itself does import from it.
        XCTAssertEqual(BackupImporter.runs(from: [backup.appendingPathComponent("deleted")]).runs.map(\.id), [a.id])
    }

    func testCompressedZipExplainsWhatToDo() throws {
        let zip = root.appendingPathComponent("compressed.zip")
        // Same minimal deflate archive as ZipTests.testRejectsCompressedEntries, named .json.
        var data = Data()
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let name = Data("a.json".utf8)
        le32(0x0403_4B50); le16(20); le16(0); le16(8); le16(0); le16(0); le32(0); le32(2); le32(1)
        le16(UInt16(name.count)); le16(0); data.append(name); data.append(contentsOf: [3, 0])
        let central = UInt32(data.count)
        le32(0x0201_4B50); le16(20); le16(20); le16(0); le16(8); le16(0); le16(0); le32(0); le32(2); le32(1)
        le16(UInt16(name.count)); le16(0); le16(0); le16(0); le16(0); le32(0); le32(0); data.append(name)
        let size = UInt32(data.count) - central
        le32(0x0605_4B50); le16(0); le16(0); le16(1); le16(1); le32(size); le32(central); le16(0)
        try data.write(to: zip)

        let batch = BackupImporter.runs(from: [zip])
        XCTAssertEqual(batch.runs.count, 0)
        XCTAssertTrue(batch.problems.first?.contains("Unzip it in the Files app") ?? false)
    }
}
