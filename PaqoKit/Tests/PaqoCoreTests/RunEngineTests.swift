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
            // The trace jumps from 1.4 to 5.5 m/s instantly (no runner does); the smoother
            // overshoots that by under 1 %.
            XCTAssertEqual(sprint.topSpeed, 5.5, accuracy: 0.08)
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
        // The first fix of each line (3 m in) anchors it and adds no distance: 2 × 3 m.
        XCTAssertEqual(run.distance, 360, accuracy: 6.5)
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
        // The first fix (1 s in, 5 m along) anchors the route and adds no distance.
        XCTAssertEqual(run.distance, expected, accuracy: 6)
    }

    /// Walk 60 s, sprint 30 s, walk 60 s, sprint 30 s, walk 60 s.
    func intervalTrace(accuracy: Double = 5) -> TraceBuilder {
        var trace = TraceBuilder()
        for (seconds, speed) in [(60, 1.4), (30, 4.0), (60, 1.4), (30, 4.0), (60, 1.4)] {
            trace.move(seconds: seconds, speed: speed, accuracy: accuracy)
        }
        return trace
    }

    func run(from trace: TraceBuilder) -> Run {
        var engine = RunEngine()
        for event in trace.events() { engine.apply(event) }
        return engine.finish(at: trace.time)
    }

    func testSprintBoundariesWithinOneAndAHalfSeconds() {
        let run = run(from: intervalTrace())
        XCTAssertEqual(run.sprints.count, 2)
        guard run.sprints.count == 2 else { return }
        XCTAssertEqual(run.sprints[0].startTime, 60, accuracy: 1.5)
        XCTAssertEqual(run.sprints[0].endTime, 90, accuracy: 1.5)
        XCTAssertEqual(run.sprints[1].startTime, 150, accuracy: 1.5)
        XCTAssertEqual(run.sprints[1].endTime, 180, accuracy: 1.5)
    }

    func testDistanceWithinOnePercentOfTruth() {
        let run = run(from: intervalTrace(accuracy: 8))
        let truth = 60 * 1.4 * 3 + 30 * 4.0 * 2
        XCTAssertEqual(run.distance, truth, accuracy: truth * 0.01)
    }

    func testRunWithNoFixesFinishesCleanly() {
        var trace = TraceBuilder()
        trace.move(seconds: 60, speed: 1.4)
        trace.move(seconds: 60, speed: 4)
        var engine = RunEngine()
        for event in trace.events() {
            if case .location = event { continue }
            engine.apply(event)
        }
        let run = engine.finish(at: trace.time)
        XCTAssertEqual(run.distance, 0)
        XCTAssertTrue(run.track.isEmpty)
        XCTAssertEqual(run.movingTime, 120, accuracy: 0.001)
        XCTAssertEqual(run.segments.last?.endTime ?? 0, 120, accuracy: 0.001)
    }

    func testThreeHourRunFinishesQuickly() {
        var trace = TraceBuilder()
        trace.includeAccel = false
        trace.move(seconds: 10_800, speed: 2.5)
        var engine = RunEngine()
        engine.start(at: t0)
        trace.feed(&engine)
        let started = Date()
        let run = engine.finish(at: trace.time)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(run.distance, 27_000, accuracy: 270)
    }

    func testPeakSpeedIsTwoSecondAverage() {
        let track = straightTrack(segments: [(10, 4), (1, 9), (10, 4)])
        let peak = TrackMath.peakSpeed(in: track, from: 0, to: 21)
        XCTAssertLessThan(peak.speed, 6.6)
        XCTAssertGreaterThan(peak.speed, 6.4)
    }

    func testRunCarriesEngineVersionAndCadence() {
        let run = run(from: intervalTrace())
        XCTAssertEqual(run.engineVersion, 2)
        for sprint in run.sprints {
            XCTAssertEqual(sprint.averageCadence ?? 0, 170, accuracy: 5)
        }
    }

    func testLowWeightFixAndBigJumpBarelyMoveTheRoute() {
        var engine = RunEngine()
        engine.start(at: t0)
        var trace = TraceBuilder()
        trace.move(seconds: 60, speed: 3)
        // A 30 m-accuracy fix 20 m off to the side, and a 300 m jump.
        trace.fixes[30].horizontalAccuracy = 30
        trace.fixes[30].longitude += 20 / Geo.metersPerDegreeLongitude(at: trace.latitude)
        trace.fixes[45].latitude += 300 / Geo.metersPerDegreeLatitude(at: trace.latitude)
        trace.fixes[45].speed = -1
        trace.feed(&engine)
        let run = engine.finish(at: trace.time)
        XCTAssertEqual(run.distance, 180, accuracy: 5)
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

    func testRunWithoutGPSHasNoZeroDistanceSprint() {
        // Treadmill or indoors: the feet say sprint for 10 minutes but there is no GPS.
        var trace = TraceBuilder()
        trace.move(seconds: 600, speed: 4)
        var engine = RunEngine()
        for event in trace.events() {
            if case .location = event { continue }
            engine.apply(event)
        }
        let run = engine.finish(at: trace.time)
        XCTAssertTrue(run.sprints.isEmpty, "a sprint with no distance is not a sprint")
        XCTAssertEqual(run.segments.map(\.kind), [.walk])
        XCTAssertEqual(RunSummary(run: run).longestSprintDuration, 0)
    }
}
