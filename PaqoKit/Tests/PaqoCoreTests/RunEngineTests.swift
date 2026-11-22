import XCTest
@testable import PaqoCore

final class RunEngineTests: XCTestCase {
    /// The owner's style: sprint as long as possible, walk, repeat.
    func sprintWalkTrace() -> TraceBuilder {
        var trace = TraceBuilder()
        for _ in 0..<4 {
            trace.move(seconds: 45, speed: 5.5)  // sprint
            trace.move(seconds: 90, speed: 1.4)  // walk
        }
        return trace
    }

    func testDistanceAndTimeOfSprintWalkRun() {
        let trace = sprintWalkTrace()
        var engine = RunEngine()
        engine.start(at: t0)
        trace.feed(&engine)
        let run = engine.finish(at: trace.time)

        let expected = 4 * (45 * 5.5 + 90 * 1.4) // 1494 m
        XCTAssertEqual(run.distance, expected, accuracy: expected * 0.01)
        XCTAssertEqual(run.movingTime, 540, accuracy: 0.001)
        XCTAssertEqual(run.elapsedTime, 540, accuracy: 0.001)
        XCTAssertEqual(Double(run.track.count), 540, accuracy: 30)
    }

    func testDetectsEverySprint() {
        let trace = sprintWalkTrace()
        var engine = RunEngine()
        engine.start(at: t0)
        trace.feed(&engine)
        let run = engine.finish(at: trace.time)

        XCTAssertEqual(run.sprints.count, 4)
        XCTAssertEqual(run.walks.count, 4)
        XCTAssertEqual(run.segments.first?.kind, .sprint)
        for sprint in run.sprints {
            // Boundaries are back-dated, so each sprint is close to its true 45 s / 247 m.
            XCTAssertEqual(sprint.duration, 45, accuracy: 3)
            XCTAssertEqual(sprint.distance, 247.5, accuracy: 15)
            XCTAssertEqual(sprint.topSpeed, 5.5, accuracy: 0.01)
        }
        // Segments tile the run with no gaps.
        for (a, b) in zip(run.segments, run.segments.dropFirst()) {
            XCTAssertEqual(a.endTime, b.startTime, accuracy: 0.0001)
            XCTAssertEqual(a.endDistance, b.startDistance, accuracy: 0.0001)
        }
        XCTAssertEqual(run.segments.last?.endTime ?? 0, run.movingTime, accuracy: 0.001)
    }

    func testDetectsSprintsWhenActivitySensorLags() {
        var trace = sprintWalkTrace()
        // The coprocessor's activity typically arrives several seconds late.
        trace.motion = trace.motion.map {
            MotionActivitySample(timestamp: $0.timestamp.addingTimeInterval(8), kind: $0.kind, confidence: $0.confidence)
        }
        var engine = RunEngine()
        engine.start(at: t0)
        trace.feed(&engine)
        let run = engine.finish(at: trace.time)
        XCTAssertEqual(run.sprints.count, 4)
        for sprint in run.sprints {
            XCTAssertEqual(sprint.duration, 45, accuracy: 4)
        }
    }

    func testLiveSnapshotDuringSprint() {
        var trace = TraceBuilder()
        trace.move(seconds: 60, speed: 1.4)
        trace.move(seconds: 30, speed: 5.0)
        var engine = RunEngine()
        engine.start(at: t0)
        trace.feed(&engine)

        let snapshot = engine.snapshot(at: trace.time)
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.segmentKind, .sprint)
        XCTAssertEqual(snapshot.segmentNumber, 1)
        XCTAssertEqual(snapshot.sprintCount, 1)
        XCTAssertEqual(snapshot.currentSpeed ?? 0, 5.0, accuracy: 0.1)
        XCTAssertEqual(snapshot.currentPace ?? 0, 0.2, accuracy: 0.01)
        XCTAssertEqual(snapshot.segmentDuration, 30, accuracy: 4)
        XCTAssertEqual(snapshot.movingTime, 90, accuracy: 0.001)
        XCTAssertNotNil(snapshot.cadence)
    }

    func testPauseExcludesTimeAndMovement() {
        var engine = RunEngine()
        engine.start(at: t0)

        var trace = TraceBuilder()
        trace.move(seconds: 60, speed: 3)
        trace.feed(&engine)
        let distanceBeforePause = engine.distance
        engine.pause(at: trace.time)

        // While paused the runner crosses the street (100 m) — must not count.
        var moved = trace
        moved.fixes = []
        moved.pedometer = []
        moved.altitudes = []
        moved.motion = []
        moved.move(seconds: 120, speed: 100.0 / 120)
        moved.feed(&engine)
        XCTAssertEqual(engine.distance, distanceBeforePause)

        engine.resume(at: moved.time)
        var after = moved
        after.fixes = []
        after.pedometer = []
        after.altitudes = []
        after.motion = []
        after.move(seconds: 60, speed: 3)
        after.feed(&engine)

        let run = engine.finish(at: after.time)
        XCTAssertEqual(run.movingTime, 120, accuracy: 0.001)
        XCTAssertEqual(run.elapsedTime, 240, accuracy: 0.001)
        XCTAssertEqual(run.distance, 360, accuracy: 6)
        XCTAssertEqual(run.pauses.count, 1)
        XCTAssertTrue(run.track.contains { $0.startsNewLine }, "the line should break at the pause")
        XCTAssertEqual(RouteBuilder.pieces(track: run.track, segments: run.segments).count, 2)
    }

    func testRejectsInaccurateAndTeleportingFixes() {
        var engine = RunEngine()
        engine.start(at: t0)
        var trace = TraceBuilder()
        trace.move(seconds: 30, speed: 3)
        // Corrupt two fixes: one very inaccurate, one teleported 1 km away.
        trace.fixes[10].horizontalAccuracy = 80
        trace.fixes[20].latitude += 0.01
        trace.feed(&engine)
        let run = engine.finish(at: trace.time)
        XCTAssertEqual(run.distance, 90, accuracy: 4)
    }

    func testStandingStillDoesNotAddDistance() {
        var engine = RunEngine()
        engine.start(at: t0)
        var trace = TraceBuilder()
        trace.move(seconds: 20, speed: 3)
        let before = trace.fixes.count
        trace.move(seconds: 60, speed: 0)
        // GPS wanders ±4 m around the stop while the feet don't move.
        for i in before..<trace.fixes.count {
            let wobble = (i % 2 == 0 ? 4.0 : -4.0) / Geo.metersPerDegreeLatitude(at: trace.latitude)
            trace.fixes[i].latitude += wobble
            trace.fixes[i].speed = 0.2
        }
        trace.feed(&engine)
        let run = engine.finish(at: trace.time)
        XCTAssertEqual(run.distance, 60, accuracy: 6)
    }

    func testBarometricElevation() {
        var engine = RunEngine()
        engine.start(at: t0)
        var trace = TraceBuilder()
        trace.move(seconds: 120, speed: 3, climb: 20)
        trace.move(seconds: 120, speed: 3, climb: -12)
        trace.feed(&engine)
        let run = engine.finish(at: trace.time)
        XCTAssertEqual(run.altitudeSource, .barometer)
        XCTAssertEqual(run.elevationGain, 20, accuracy: 1.1)
        XCTAssertEqual(run.elevationLoss, 12, accuracy: 1.1)
        // Anchored to GPS altitude (trace starts at 10 m).
        XCTAssertEqual(run.altitudeOffset, 10, accuracy: 0.5)
    }

    func testGPSElevationFallback() {
        var engine = RunEngine()
        engine.start(at: t0)
        var trace = TraceBuilder()
        trace.move(seconds: 120, speed: 3, climb: 30)
        trace.feed(&engine, includeAltimeter: false)
        let run = engine.finish(at: trace.time)
        XCTAssertEqual(run.altitudeSource, .gps)
        XCTAssertEqual(run.elevationGain, 30, accuracy: 4.1)
    }

    func testStepsExcludePausedSteps() {
        var engine = RunEngine()
        engine.start(at: t0)
        engine.ingest(PedometerSample(timestamp: t0.addingTimeInterval(10), steps: 100, cadence: 160))
        engine.pause(at: t0.addingTimeInterval(11))
        engine.ingest(PedometerSample(timestamp: t0.addingTimeInterval(20), steps: 130, cadence: 100))
        engine.resume(at: t0.addingTimeInterval(21))
        engine.ingest(PedometerSample(timestamp: t0.addingTimeInterval(40), steps: 230, cadence: 160))
        XCTAssertEqual(engine.steps, 200)
    }

    func testAutosaveRoundTripContinuesRecording() throws {
        var trace = TraceBuilder()
        trace.move(seconds: 30, speed: 5)
        trace.move(seconds: 30, speed: 1.4)
        var engine = RunEngine()
        engine.start(at: t0)
        trace.feed(&engine)

        let data = try JSONEncoder().encode(engine)
        var restored = try JSONDecoder().decode(RunEngine.self, from: data)
        XCTAssertEqual(restored.distance, engine.distance)
        XCTAssertEqual(restored.state, .running)

        var more = trace
        more.fixes = []
        more.pedometer = []
        more.altitudes = []
        more.motion = []
        more.move(seconds: 30, speed: 5)
        more.feed(&restored)
        let run = restored.finish(at: more.time)
        XCTAssertEqual(run.sprints.count, 2)
        let expected: Double = 150 + 42 + 150
        XCTAssertEqual(run.distance, expected, accuracy: 5)
    }

    func testRecoveredRunClosesAtLastActivity() {
        var trace = TraceBuilder()
        trace.move(seconds: 50, speed: 3)
        var engine = RunEngine()
        engine.start(at: t0)
        trace.feed(&engine)
        XCTAssertEqual(engine.lastActivityDate, trace.time)
    }

    func testRunDateAtActiveTimeSkipsPauses() {
        let run = Run(
            name: "x",
            startDate: t0,
            endDate: t0.addingTimeInterval(300),
            distance: 0,
            movingTime: 240,
            pauses: [PauseInterval(start: t0.addingTimeInterval(100), end: t0.addingTimeInterval(160))]
        )
        XCTAssertEqual(run.date(atActiveTime: 50), t0.addingTimeInterval(50))
        XCTAssertEqual(run.date(atActiveTime: 150), t0.addingTimeInterval(210))
    }

    func testDefaultNames() {
        let calendar = utcCalendar()
        func at(_ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: hour))!
        }
        XCTAssertEqual(Run.defaultName(for: at(7), calendar: calendar), "Morning Run")
        XCTAssertEqual(Run.defaultName(for: at(13), calendar: calendar), "Afternoon Run")
        XCTAssertEqual(Run.defaultName(for: at(18), calendar: calendar), "Evening Run")
        XCTAssertEqual(Run.defaultName(for: at(23), calendar: calendar), "Night Run")
    }
}
