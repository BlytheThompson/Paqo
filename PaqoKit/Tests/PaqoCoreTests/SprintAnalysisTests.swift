import Foundation
import XCTest
@testable import PaqoCore

/// Walk 60 s @1.5, sprint 20 @5, walk 40, sprint 20 @4.5, walk 40, sprint 20 @4, walk 60.
func threeSprintRun(id: UUID = UUID(), start: Date = t0) -> Run {
    let plan: [(Int, Double, SegmentKind)] = [
        (60, 1.5, .walk), (20, 5, .sprint), (40, 1.5, .walk), (20, 4.5, .sprint),
        (40, 1.5, .walk), (20, 4, .sprint), (60, 1.5, .walk),
    ]
    let track = straightTrack(segments: plan.map { ($0.0, $0.1) }, start: start)
    var segments: [RunSegment] = []
    var time = 0.0
    for (seconds, _, kind) in plan {
        let end = time + Double(seconds)
        segments.append(RunSegment(
            kind: kind,
            startTime: time,
            endTime: end,
            startDistance: TrackMath.distance(atActiveTime: time, in: track),
            endDistance: TrackMath.distance(atActiveTime: end, in: track),
            topSpeed: 0,
            averageCadence: kind == .sprint ? 170 : 110
        ))
        time = end
    }
    return Run(
        id: id,
        name: "Intervals",
        startDate: start,
        endDate: start.addingTimeInterval(time),
        distance: track.last!.distance,
        movingTime: time,
        track: track,
        segments: segments,
        engineVersion: 2
    )
}

final class SprintAnalysisTests: XCTestCase {
    func testDetailsPerSprint() {
        let details = SprintAnalyzer.details(for: threeSprintRun())
        XCTAssertEqual(details.map(\.number), [1, 2, 3])
        XCTAssertEqual(details[0].averageSpeed, 5, accuracy: 0.01)
        XCTAssertEqual(details[1].averageSpeed, 4.5, accuracy: 0.01)
        XCTAssertEqual(details[2].averageSpeed, 4, accuracy: 0.01)
        XCTAssertEqual(details.map { $0.restAfter?.duration ?? -1 }, [40, 40, 60])
        for detail in details {
            XCTAssertEqual(detail.climb, detail.segment.distance / 100, accuracy: 0.5)
            XCTAssertEqual(detail.peakSpeed, detail.averageSpeed, accuracy: 0.01)
            XCTAssertEqual(detail.averageCadence, 170)
            XCTAssertEqual(detail.inSprintFade ?? 1, 0, accuracy: 0.001)
        }
    }

    func testRunStats() {
        let stats = SprintAnalyzer.stats(for: threeSprintRun())
        XCTAssertEqual(stats.sprintCount, 3)
        XCTAssertEqual(stats.totalSprintTime, 60, accuracy: 0.001)
        XCTAssertEqual(stats.totalSprintDistance, 270, accuracy: 0.01)
        XCTAssertEqual(stats.sprintShare, 60.0 / 260, accuracy: 0.0001)
        XCTAssertEqual(stats.averageRest ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(stats.workRestRatio ?? 0, 60.0 / 80, accuracy: 0.0001)
        XCTAssertEqual(stats.fade ?? 0, -0.2, accuracy: 0.001)
        XCTAssertEqual(stats.fastestSprintSpeed, 5, accuracy: 0.01)
        XCTAssertEqual(stats.slowestSprintSpeed, 4, accuracy: 0.01)
        XCTAssertEqual(stats.fastestTenSecondSprintSpeed ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(stats.averageSprintSpeed, 4.5, accuracy: 0.01)
        XCTAssertEqual(stats.peakSpeed, 5, accuracy: 0.01)
        XCTAssertEqual(stats.averageSprintCadence ?? 0, 170, accuracy: 0.001)
    }

    func testFadeNeedsThreeSprints() {
        var run = threeSprintRun()
        run.segments = Array(run.segments.prefix(4)) // two sprints
        XCTAssertNil(SprintAnalyzer.stats(for: run).fade)
    }

    func testOldIndexRebuildsWithStats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paqo-store-\(UUID().uuidString)")
        let store = try RunStore(directory: directory)
        let run = threeSprintRun()
        try store.save(run)
        // Rewrite the index the way v1 wrote it: no sprintStats.
        var summaries = try JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL)) as! [[String: Any]]
        for i in summaries.indices { summaries[i].removeValue(forKey: "sprintStats") }
        try JSONSerialization.data(withJSONObject: summaries).write(to: store.indexURL)

        let loaded = try store.loadSummaries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].sprintStats.sprintCount, 3)
        XCTAssertEqual(loaded[0].topSpeed, 5, accuracy: 0.01)
    }

    func testFastestSprintRecord() {
        let slow = RunSummary(run: {
            var run = threeSprintRun()
            run.segments = run.segments.map { var s = $0; if s.kind == .sprint && s.startTime == 60 { s.kind = .walk }; return s }
            return run
        }())
        let fast = RunSummary(run: threeSprintRun(start: t0.addingTimeInterval(86_400)))
        let records = PersonalRecords.compute(from: [slow, fast], now: t0.addingTimeInterval(90_000), calendar: utcCalendar())
        XCTAssertEqual(records.fastestSprint?.value ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(records.fastestSprint?.runID, fast.id)
    }
}
