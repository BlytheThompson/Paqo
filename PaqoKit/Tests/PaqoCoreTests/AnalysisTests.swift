import XCTest
@testable import PaqoCore

final class SegmentTests: XCTestCase {
    func testClassifierWaitsThenBackdates() {
        var classifier = SegmentClassifier()
        // Walking for 10 s.
        for s in 0..<10 {
            _ = classifier.classify(speed: 1.4, at: t0.addingTimeInterval(Double(s)), activeTime: Double(s))
        }
        XCTAssertEqual(classifier.current, .walk)
        // Sprint evidence starts at t=10; switch confirmed 1.5 s later, back-dated to 10.
        var transition: SegmentClassifier.Transition?
        for s in 10..<20 where transition == nil {
            transition = classifier.classify(speed: 5, at: t0.addingTimeInterval(Double(s)), activeTime: Double(s))
        }
        XCTAssertEqual(transition, SegmentClassifier.Transition(kind: .sprint, at: 10))
    }

    func testClassifierIgnoresOneSecondBlip() {
        var classifier = SegmentClassifier()
        for s in 0..<10 { _ = classifier.classify(speed: 1.4, at: t0.addingTimeInterval(Double(s)), activeTime: Double(s)) }
        XCTAssertNil(classifier.classify(speed: 6, at: t0.addingTimeInterval(10), activeTime: 10))
        XCTAssertNil(classifier.classify(speed: 1.4, at: t0.addingTimeInterval(11), activeTime: 11))
        for s in 12..<20 {
            XCTAssertNil(classifier.classify(speed: 1.4, at: t0.addingTimeInterval(Double(s)), activeTime: Double(s)))
        }
        XCTAssertEqual(classifier.current, .walk)
    }

    func testMotionAndCadenceOutvoteNoisySpeed() {
        var classifier = SegmentClassifier()
        classifier.update(motion: MotionActivitySample(timestamp: t0, kind: .running, confidence: .high))
        classifier.update(cadence: 172, at: t0)
        // GPS briefly says slow (e.g. under a bridge) but feet and coprocessor say running.
        XCTAssertEqual(classifier.instantaneousLabel(speed: 1.5, at: t0.addingTimeInterval(1)), .sprint)
    }

    func testSmootherAbsorbsBlips() {
        let track = straightTrack(segments: [(60, 5)])
        let raw = [
            RunSegment(kind: .sprint, startTime: 0, endTime: 20, startDistance: 0, endDistance: 100),
            RunSegment(kind: .walk, startTime: 20, endTime: 22, startDistance: 100, endDistance: 110),   // stumble
            RunSegment(kind: .sprint, startTime: 22, endTime: 40, startDistance: 110, endDistance: 200),
            RunSegment(kind: .walk, startTime: 40, endTime: 50, startDistance: 200, endDistance: 214),
            RunSegment(kind: .sprint, startTime: 50, endTime: 52, startDistance: 214, endDistance: 222), // too short
            RunSegment(kind: .walk, startTime: 52, endTime: 60, startDistance: 222, endDistance: 233),
        ]
        let smoothed = SegmentSmoother.smooth(raw, track: track)
        XCTAssertEqual(smoothed.map(\.kind), [.sprint, .walk])
        XCTAssertEqual(smoothed[0].endTime, 40)
        XCTAssertEqual(smoothed[1].startTime, 40)
        XCTAssertEqual(smoothed[1].endTime, 60)
    }

    func testRoutePiecesFollowSegments() {
        let track = straightTrack(segments: [(10, 5), (10, 1.5)])
        let segments = [
            RunSegment(kind: .sprint, startTime: 0, endTime: 10, startDistance: 0, endDistance: 50),
            RunSegment(kind: .walk, startTime: 10, endTime: 20, startDistance: 50, endDistance: 65),
        ]
        let pieces = RouteBuilder.pieces(track: track, segments: segments)
        XCTAssertEqual(pieces.map(\.kind), [.sprint, .walk])
        // Pieces share the boundary point so the line is continuous.
        XCTAssertEqual(pieces[0].points.last, pieces[1].points.first)
        XCTAssertEqual(pieces[0].points.count + pieces[1].points.count, track.count + 1)
    }
}

final class SplitAndEffortTests: XCTestCase {
    func testSplitsInterpolateBoundaries() {
        // 400 s at 4 m/s = 1600 m, then 200 s at 2 m/s = 400 m → 2000 m total.
        let track = straightTrack(segments: [(400, 4), (200, 2)])
        let splits = SplitCalculator.splits(for: track, unitLength: 1000)
        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].duration, 250, accuracy: 0.001)
        // Second km: 600 m at 4 m/s (150 s) + 400 m at 2 m/s (200 s).
        XCTAssertEqual(splits[1].duration, 350, accuracy: 0.001)
        XCTAssertFalse(splits[1].isPartial)
        XCTAssertEqual(splits[0].elevationChange ?? 0, 10, accuracy: 0.001)
    }

    func testPartialFinalSplit() {
        let track = straightTrack(segments: [(500, 4)]) // 2000 m
        let splits = SplitCalculator.splits(for: track, unitLength: 1609.344)
        XCTAssertEqual(splits.count, 2)
        XCTAssertTrue(splits[1].isPartial)
        XCTAssertEqual(splits[1].distance, 2000 - 1609.344, accuracy: 0.001)
        XCTAssertEqual(splits[0].pace ?? 0, 0.25, accuracy: 0.0001)
    }

    func testBestEffortFindsFastestStretch() {
        // Slow 1 km, fast 1 km, slow 1 km.
        let track = straightTrack(segments: [(500, 2), (200, 5), (500, 2)])
        XCTAssertEqual(BestEffortCalculator.bestEffort(distance: 1000, in: track) ?? 0, 200, accuracy: 0.001)
        // Fastest 1500 m: 1000 m fast (200 s) + 500 m slow (250 s).
        XCTAssertEqual(BestEffortCalculator.bestEffort(distance: 1500, in: track) ?? 0, 450, accuracy: 0.001)
        XCTAssertNil(BestEffortCalculator.bestEffort(distance: 5000, in: track))
    }

    func testProfileHasPaceAndAltitude() {
        let track = straightTrack(segments: [(250, 4)]) // 1000 m
        let run = Run(name: "x", startDate: t0, endDate: t0.addingTimeInterval(250), distance: 1000, movingTime: 250, altitudeOffset: 100, track: track)
        let profile = ProfileBuilder.profile(for: run, samples: 20)
        XCTAssertGreaterThan(profile.count, 10)
        XCTAssertNil(profile[0].pace)
        XCTAssertEqual(profile[5].pace ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(profile.last?.altitude ?? 0, 110, accuracy: 0.6)
    }
}

final class StatsAndRecordsTests: XCTestCase {
    func summary(_ date: Date, distance: Double, time: Double = 1800, sprints: Int = 0, top: Double = 0, efforts: [BestEffort] = []) -> RunSummary {
        var run = Run(name: "r", startDate: date, endDate: date.addingTimeInterval(time), distance: distance, movingTime: time)
        if sprints > 0 {
            var segments: [RunSegment] = []
            for i in 0..<sprints {
                let start = Double(i) * 100
                let startDistance = Double(i) * 300
                segments.append(RunSegment(kind: .sprint, startTime: start, endTime: start + 30, startDistance: startDistance, endDistance: startDistance + 150, topSpeed: top))
            }
            run.segments = segments
        }
        var s = RunSummary(run: run)
        s.bestEfforts = efforts
        return s
    }

    func testWeeklyTotalsIncludeEmptyWeeks() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 12))! // Saturday
        let runs = [
            summary(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 8))!, distance: 3000),
            summary(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 8))!, distance: 4000),
            summary(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 8))!, distance: 5000),
        ]
        let weeks = Stats.totals(for: runs, period: .week, count: 4, now: now, calendar: calendar)
        XCTAssertEqual(weeks.count, 4)
        // Weeks starting Oct 26, Nov 2, Nov 9, Nov 16.
        XCTAssertEqual(weeks.map(\.distance), [0, 5000, 0, 7000])
        XCTAssertEqual(weeks.last?.runCount, 2)
        XCTAssertEqual(weeks.last?.start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))!)

        let months = Stats.totals(for: runs, period: .month, count: 2, now: now, calendar: calendar)
        XCTAssertEqual(months.map(\.distance), [0, 12000])
        let years = Stats.totals(for: runs, period: .year, count: 1, now: now, calendar: calendar)
        XCTAssertEqual(years.first?.runCount, 3)
    }

    func testRecordsAndStreaks() {
        let calendar = utcCalendar()
        func day(_ month: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: 9))!
        }
        let now = day(11, 21)
        let runs = [
            summary(day(10, 1), distance: 8000, time: 3000, efforts: [BestEffort(distance: 1609.344, duration: 540)]),
            // Weeks of Nov 2, 9, 16 in a row.
            summary(day(11, 3), distance: 5000, sprints: 3, top: 6.1, efforts: [BestEffort(distance: 1609.344, duration: 500), BestEffort(distance: 5000, duration: 1700)]),
            summary(day(11, 10), distance: 4000, sprints: 7, top: 6.8),
            summary(day(11, 17), distance: 3000, time: 3600),
            summary(day(11, 19), distance: 6500),
        ]
        let records = PersonalRecords.compute(from: runs, now: now, calendar: calendar)

        XCTAssertEqual(records.fastest.first { $0.distance == .oneMile }?.entry.value, 500)
        XCTAssertEqual(records.fastest.first { $0.distance == .fiveK }?.entry.runID, runs[1].id)
        XCTAssertEqual(records.longestDistance?.value, 8000)
        XCTAssertEqual(records.longestDuration?.value, 3600)
        XCTAssertEqual(records.topSpeed?.value, 6.8)
        XCTAssertEqual(records.mostSprints?.value, 7)
        XCTAssertEqual(records.longestSprintDistance?.value, 150)
        XCTAssertEqual(records.currentWeekStreak, 3)
        XCTAssertEqual(records.longestWeekStreak, 3)
        XCTAssertEqual(records.biggestWeek?.value, 9500)
        XCTAssertEqual(records.biggestMonth?.value, 18500)
    }

    func testStreakSurvivesUntilWeekEnds() {
        let calendar = utcCalendar()
        let lastWeek = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let records = PersonalRecords.compute(from: [summary(lastWeek, distance: 1000)], now: now, calendar: calendar)
        XCTAssertEqual(records.currentWeekStreak, 1, "no run yet this week, but last week still counts")

        let muchLater = calendar.date(from: DateComponents(year: 2026, month: 12, day: 2, hour: 9))!
        XCTAssertEqual(PersonalRecords.compute(from: [summary(lastWeek, distance: 1000)], now: muchLater, calendar: calendar).currentWeekStreak, 0)
    }
}

final class RunStoreTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaqoTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeRun(_ offset: TimeInterval) -> Run {
        var trace = TraceBuilder()
        trace.time = t0.addingTimeInterval(offset)
        trace.move(seconds: 40, speed: 5)
        trace.move(seconds: 60, speed: 1.4)
        var engine = RunEngine()
        engine.start(at: t0.addingTimeInterval(offset))
        trace.feed(&engine)
        return engine.finish(at: trace.time)
    }

    func testSaveLoadDelete() throws {
        let store = try RunStore(directory: directory)
        let older = makeRun(0)
        let newer = makeRun(86_400)
        try store.save(older)
        try store.save(newer)

        let summaries = try store.loadSummaries()
        XCTAssertEqual(summaries.map(\.id), [newer.id, older.id])
        XCTAssertEqual(summaries[0].sprintCount, 1)

        let loaded = try store.loadRun(id: older.id)
        XCTAssertEqual(loaded, older)

        try store.delete(id: older.id)
        XCTAssertEqual(try store.loadSummaries().map(\.id), [newer.id])
        XCTAssertThrowsError(try store.loadRun(id: older.id))
    }

    func testRenameKeepsSingleEntry() throws {
        let store = try RunStore(directory: directory)
        var run = makeRun(0)
        try store.save(run)
        run.name = "Hill sprints"
        try store.save(run)
        let summaries = try store.loadSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].name, "Hill sprints")
    }

    func testIndexRebuildsWhenMissing() throws {
        let store = try RunStore(directory: directory)
        let run = makeRun(0)
        try store.save(run)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("index.json"))
        XCTAssertEqual(try store.loadSummaries().map(\.id), [run.id])
    }

    func testInProgressAutosave() throws {
        let store = try RunStore(directory: directory)
        XCTAssertNil(store.loadInProgress())
        var engine = RunEngine()
        engine.start(at: t0)
        var trace = TraceBuilder()
        trace.move(seconds: 20, speed: 3)
        trace.feed(&engine)
        try store.saveInProgress(engine)

        let restored = try XCTUnwrap(store.loadInProgress())
        XCTAssertEqual(restored.id, engine.id)
        XCTAssertEqual(restored.distance, engine.distance)
        store.clearInProgress()
        XCTAssertNil(store.loadInProgress())
    }
}
