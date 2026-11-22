import Foundation
import XCTest
@testable import PaqoCore

final class SessionTests: XCTestCase {
    func intervalTrace() -> TraceBuilder {
        var trace = TraceBuilder()
        for (seconds, speed) in [(40, 1.4), (20, 4.0), (40, 1.4), (20, 4.0), (30, 1.4)] {
            trace.move(seconds: seconds, speed: speed)
        }
        return trace
    }

    func meta(id: UUID = UUID(), start: Date = t0) -> SensorLogMeta {
        SensorLogMeta(runID: id, appVersion: "1.1.0", engineVersion: RunEngine.version, deviceModel: "test", startDate: start, config: .init())
    }

    /// Records a trace live through a recorder with an in-memory log.
    func recordLive(_ trace: TraceBuilder, meta: SensorLogMeta) -> (run: Run, files: [String: String]) {
        let sink = MemoryLogSink(meta: meta)
        let recorder = SessionRecorder(engine: RunEngine(id: meta.runID, config: meta.config ?? .init()), sink: sink)
        for event in trace.events() { recorder.record(event) }
        let run = recorder.finish(at: trace.time, calendar: utcCalendar())
        return (run, sink.files)
    }

    func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paqo-logs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testReplayReproducesLiveRunExactly() throws {
        let m = meta()
        let live = recordLive(intervalTrace(), meta: m)
        XCTAssertEqual(live.run.sprints.count, 2)
        let log = try SensorLogCodec.decode(files: live.files)
        let replayed = SessionReplayer.replay(log, config: log.meta.config ?? .init(), calendar: utcCalendar())
        XCTAssertEqual(replayed, live.run)
    }

    func testReprocessWithNewConfigKeepsIdentity() throws {
        let m = meta()
        var (original, files) = recordLive(intervalTrace(), meta: m)
        original.name = "Hill reps"
        original.savedToHealth = true
        var config = RunEngine.Configuration()
        config.resegmenter.switchPenalty = 1000
        let redone = Reprocessor.reprocess(original, log: try SensorLogCodec.decode(files: files), config: config)
        XCTAssertEqual(redone.id, original.id)
        XCTAssertEqual(redone.name, "Hill reps")
        XCTAssertTrue(redone.savedToHealth)
        XCTAssertEqual(redone.startDate, original.startDate)
        XCTAssertEqual(redone.segments.count, 1)
    }

    func testReplayOfCrashedLogIgnoresPartialLine() throws {
        let m = meta()
        let trace = intervalTrace()
        var files = recordLive(trace, meta: m).files
        // The app died: no finish row, and a half-written GPS line.
        files["events.csv"] = files["events.csv"]!
            .split(separator: "\n").filter { !$0.hasSuffix(",finish") }.joined(separator: "\n") + "\n"
        files["gps.csv"]! += "123,17"
        let log = try SensorLogCodec.decode(files: files)
        let replayed = SessionReplayer.replay(log, config: .init(), calendar: utcCalendar())

        var engine = RunEngine(id: m.runID)
        for event in trace.events() { engine.apply(SensorLogCodec.normalize(event)) }
        XCTAssertEqual(replayed.endDate, engine.lastActivityDate)
        XCTAssertEqual(replayed.sprints.count, 2)
    }

    func testWriterFilesDecodeToSameEvents() throws {
        let store = try SensorLogStore(directory: tempDirectory())
        let m = meta()
        let events = intervalTrace().events()
        let writer = try store.makeWriter(meta: m)
        for (seq, event) in events.enumerated() { writer.write(SensorLogCodec.normalize(event), seq: seq) }
        writer.close()
        XCTAssertTrue(store.hasLog(for: m.runID))
        let log = try store.load(runID: m.runID)
        XCTAssertEqual(log.meta, m)
        XCTAssertEqual(log.events, events.map(SensorLogCodec.normalize))
    }

    func testPruneKeepsNewestTwenty() throws {
        func makeStore() throws -> (SensorLogStore, [UUID]) {
            let store = try SensorLogStore(directory: tempDirectory())
            var ids: [UUID] = []
            for i in 0..<23 {
                let m = meta(start: t0.addingTimeInterval(Double(i) * 3600))
                try store.makeWriter(meta: m).close()
                ids.append(m.runID)
            }
            return (store, ids)
        }

        let (store, ids) = try makeStore()
        store.prune(keep: 20, protecting: nil)
        XCTAssertEqual(Set(store.runIDs()), Set(ids.suffix(20)))

        let (store2, ids2) = try makeStore()
        store2.prune(keep: 20, protecting: ids2[0])
        XCTAssertEqual(Set(store2.runIDs()), Set(ids2.suffix(20) + [ids2[0]]))
        XCTAssertGreaterThan(store2.totalBytes(), 0)
    }

    func testArchiveIsReadableZip() throws {
        let store = try SensorLogStore(directory: tempDirectory())
        let m = meta()
        let writer = try store.makeWriter(meta: m)
        for (seq, event) in intervalTrace().events().prefix(50).enumerated() { writer.write(event, seq: seq) }
        writer.close()
        let zip = tempDirectory().appendingPathComponent("log.zip")
        try store.archive(runID: m.runID, to: zip)
        let names = try ZipReader.entries(of: Data(contentsOf: zip)).map { ($0.path as NSString).lastPathComponent }
        XCTAssertEqual(Set(names), Set(["meta.json"] + SensorLogCodec.fileNames))
    }

    // MARK: - Replay tool

    func testOverridesApply() throws {
        var config = RunEngine.Configuration()
        try ConfigOverrides.apply(["sprintCadence=150", "switchPenalty=3", "maxConsecutiveRejections=5"], to: &config)
        XCTAssertEqual(config.classifier.sprintCadence, 150)
        XCTAssertEqual(config.resegmenter.switchPenalty, 3)
        XCTAssertEqual(config.filter.maxConsecutiveRejections, 5)
    }

    func testUnknownOverrideThrows() {
        var config = RunEngine.Configuration()
        XCTAssertThrowsError(try ConfigOverrides.apply(["sprintness=9"], to: &config))
        XCTAssertThrowsError(try ConfigOverrides.apply(["sprintCadence=fast"], to: &config))
    }

    func testReportListsEverySegment() {
        let run = recordLive(intervalTrace(), meta: meta()).run
        let lines = ReplayReport.text(for: run).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines[0].contains("\(run.sprints.count) sprints"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("  ") }.count, run.segments.count)
        XCTAssertNoThrow(try ReplayReport.json(for: run))
    }

    /// Writes a generated log for trying `swift run paqo-replay ../private/sample-log`.
    /// Only runs when PAQO_WRITE_SAMPLE is set.
    func testWriteSampleLogForCLI() throws {
        guard ProcessInfo.processInfo.environment["PAQO_WRITE_SAMPLE"] != nil else { return }
        let files = recordLive(intervalTrace(), meta: meta()).files
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = repo.appendingPathComponent("private/sample-log", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
    }
}
