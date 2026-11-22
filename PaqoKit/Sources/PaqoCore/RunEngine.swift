import Foundation

public enum RecordingState: String, Codable, Sendable {
    case idle, running, paused, finished
}

/// Everything the live screen and Live Activity show.
public struct LiveSnapshot: Equatable, Sendable {
    public var state: RecordingState
    public var elapsedTime: TimeInterval
    public var movingTime: TimeInterval
    /// Meters.
    public var distance: Double
    /// Seconds per meter over the last few seconds; nil when barely moving.
    public var currentPace: Double?
    /// Seconds per meter over the whole run.
    public var averagePace: Double?
    /// m/s over the last few seconds.
    public var currentSpeed: Double?
    public var segmentKind: SegmentKind?
    /// "Sprint 4" → 4. Counts segments of the current kind so far.
    public var segmentNumber: Int
    public var segmentDuration: TimeInterval
    public var sprintCount: Int
    public var elevationGain: Double
    public var steps: Int?
    /// Steps per minute.
    public var cadence: Double?
    /// Horizontal accuracy of the most recent fix, meters.
    public var gpsAccuracy: Double?
}

/// The run recorder. Pure logic: sensor events go in, live snapshots and a finished
/// `Run` come out. It never reads the clock, so replaying a sensor log reproduces a
/// run exactly.
///
/// While recording, GPS goes through a Kalman filter (position, Doppler velocity,
/// "standing still" and step-based speed), and a live classifier labels sprints and
/// walks. On finish the route is smoothed with the whole run in view and the run is
/// re-segmented second by second.
///
/// The whole engine is `Codable` so an in-progress run can be autosaved and recovered
/// if the app is killed mid-run.
public struct RunEngine: Codable, Sendable {
    /// Bumped whenever detection or filtering changes in a way that changes results.
    public static let version = 2

    public struct Configuration: Codable, Sendable, Equatable {
        /// Fixes less accurate than this (meters) are ignored.
        public var maxHorizontalAccuracy: Double = 50
        /// Fixes less accurate than this count with half the weight.
        public var downweightAccuracy: Double = 25
        /// GPS this poor (meters) brings in step-based speed.
        public var poorGPSAccuracy: Double = 15
        /// Stride is learned only from fixes at least this good (meters).
        public var strideLearningAccuracy: Double = 10
        /// Track points closer than this (meters) to the previous one are skipped.
        public var minStep: Double = 0.5
        /// Window for current pace and speed (seconds).
        public var paceWindow: TimeInterval = 15
        /// Below this speed (m/s), with no steps or a stationary activity, the runner is standing.
        public var stationarySpeed: Double = 0.5
        /// Seconds without new steps that count as "no steps".
        public var stepStaleness: TimeInterval = 4
        /// Doppler speed is trusted when its accuracy is at most this (m/s).
        public var maxSpeedAccuracy: Double = 1.5
        /// Uncertainty of cadence × stride speed (m/s).
        public var stepSpeedSigma: Double = 0.5
        public var classifier = SegmentClassifier.Configuration()
        public var filter = RouteFilter.Configuration()
        public var resegmenter = Resegmenter.Configuration()

        public init() {}
    }

    public let id: UUID
    public var config: Configuration
    public private(set) var state: RecordingState = .idle
    public private(set) var startDate: Date?
    public private(set) var endDate: Date?
    public private(set) var pauses: [PauseInterval] = []
    public private(set) var track: [TrackPoint] = []
    public private(set) var segments: [RunSegment] = []
    /// Meters.
    public private(set) var distance: Double = 0
    public private(set) var elevation = ElevationTracker()
    /// The latest raw fix, accepted or not (for the GPS signal indicator).
    public private(set) var latestFix: LocationSample?

    var lastProcessedFix: LocationSample?
    var needsNewLine = false
    var line = 0
    var frame: LocalFrame?
    var filter: RouteFilter
    var filterInputs: [FilterMeasurement] = []
    var lastPointEast: Double?
    var lastPointNorth: Double?
    var lastSpeed: Double = 0
    var classifier: SegmentClassifier
    var rhythmAnalyzer = StepRhythmAnalyzer()
    var latestRhythm: RhythmSample?
    var stride: Double?
    var evidence: [EvidenceSample] = []
    var latestSteps: Int?
    var lastStepIncrease: Date?
    var stepsAtPause: Int?
    var pausedSteps: Int = 0
    var latestCadence: Double?
    var latestCadenceDate: Date?
    var latestMotion: MotionActivitySample?

    public init(id: UUID = UUID(), config: Configuration = Configuration()) {
        self.id = id
        self.config = config
        self.classifier = SegmentClassifier(config: config.classifier)
        self.filter = RouteFilter(config: config.filter)
    }

    // MARK: - Events

    /// Feeds one event. `.control(.finish)` is recorded by the session; call
    /// `finish(at:)` to get the run.
    public mutating func apply(_ event: SensorEvent) {
        switch event {
        case .location(let fix): ingest(fix)
        case .activity(let sample): ingest(sample)
        case .pedometer(let sample): ingest(sample)
        case .altitude(let sample): ingest(sample)
        case .accelerometer(let batch): ingest(batch)
        case .control(let control):
            switch control {
            case .start(let date): start(at: date)
            case .pause(let date): pause(at: date)
            case .resume(let date): resume(at: date)
            case .finish: break
            }
        }
    }

    // MARK: - Control

    public mutating func start(at date: Date) {
        guard state == .idle else { return }
        state = .running
        startDate = date
    }

    public mutating func pause(at date: Date) {
        guard state == .running else { return }
        pauses.append(PauseInterval(start: date))
        stepsAtPause = latestSteps
        state = .paused
    }

    public mutating func resume(at date: Date) {
        guard state == .paused, !pauses.isEmpty else { return }
        pauses[pauses.count - 1].end = max(date, pauses[pauses.count - 1].start)
        if let before = stepsAtPause, let now = latestSteps, now > before {
            pausedSteps += now - before
        }
        stepsAtPause = nil
        state = .running
        // Movement while paused is never counted: the next fix starts a fresh line.
        line += 1
        needsNewLine = true
        lastPointEast = nil
        lastPointNorth = nil
        elevation.resetReference()
    }

    /// Stops recording and returns the finished run.
    public mutating func finish(at date: Date, name: String? = nil, calendar: Calendar = .current) -> Run {
        if state == .paused, !pauses.isEmpty, pauses[pauses.count - 1].end == nil {
            pauses[pauses.count - 1].end = max(date, pauses[pauses.count - 1].start)
        }
        let start = startDate ?? date
        let end = max(date, start)
        let moving = activeTime(at: end)
        state = .finished
        endDate = end

        rebuildSmoothedTrack()
        var finalSegments = resegment(movingTime: moving)
        finalSegments = SegmentSmoother.smooth(finalSegments, track: track)
        finalSegments = finalSegments.map { segment in
            var s = segment
            s.averageCadence = averageCadence(from: segment.startTime, to: segment.endTime)
            return s
        }
        segments = finalSegments

        return Run(
            id: id,
            name: name ?? Run.defaultName(for: start, calendar: calendar),
            startDate: start,
            endDate: end,
            distance: distance,
            movingTime: moving,
            elevationGain: elevation.gain,
            elevationLoss: elevation.loss,
            altitudeSource: elevation.source,
            altitudeOffset: elevation.offset,
            steps: steps,
            track: track,
            segments: finalSegments,
            pauses: pauses,
            savedToHealth: false,
            engineVersion: Self.version
        )
    }

    /// When the last thing was recorded; used to close a recovered run sensibly.
    public var lastActivityDate: Date? {
        [track.last?.timestamp, pauses.last?.end ?? pauses.last?.start, startDate]
            .compactMap { $0 }
            .max()
    }

    // MARK: - Time

    public func elapsedTime(at date: Date) -> TimeInterval {
        guard let start = startDate else { return 0 }
        return max(0, (endDate ?? date).timeIntervalSince(start))
    }

    /// Seconds since start, excluding pauses.
    public func activeTime(at date: Date) -> TimeInterval {
        guard let start = startDate else { return 0 }
        let clamped = min(date, endDate ?? date)
        var paused = 0.0
        for pause in pauses where pause.start < clamped {
            paused += min(pause.end ?? clamped, clamped).timeIntervalSince(pause.start)
        }
        return max(0, clamped.timeIntervalSince(start) - paused)
    }

    public var steps: Int? {
        guard let latestSteps else { return nil }
        var paused = pausedSteps
        if state == .paused, let before = stepsAtPause { paused += max(0, latestSteps - before) }
        return max(0, latestSteps - paused)
    }

    // MARK: - Sensor input

    public mutating func ingest(_ fix: LocationSample) {
        latestFix = fix
        guard state == .running, let start = startDate, fix.timestamp >= start else { return }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= config.maxHorizontalAccuracy else { return }
        if let last = lastProcessedFix, fix.timestamp <= last.timestamp { return }
        lastProcessedFix = fix

        let t = activeTime(at: fix.timestamp)
        if frame == nil { frame = LocalFrame(origin: fix.coordinate) }
        guard let frame else { return }
        let local = frame.toLocal(fix.coordinate)

        elevation.ingestGPS(altitude: fix.altitude, verticalAccuracy: fix.verticalAccuracy)
        let trusted = trustedSpeed(fix)
        let stationary = isStationary(at: fix.timestamp, speed: trusted ?? (filter.isRunning ? filter.state.speed : 0))
        let rhythmCadence = freshRhythmCadence(at: fix.timestamp)
        learnStride(fix: fix, speed: trusted, cadence: rhythmCadence)

        var sigma = max(config.filter.minPositionSigma, fix.horizontalAccuracy)
        if fix.horizontalAccuracy > config.downweightAccuracy { sigma *= 2 }

        var velocity: (east: Double, north: Double, along: Double, cross: Double)?
        if let speed = trusted, fix.course >= 0 {
            let course = fix.course * .pi / 180
            let courseSigma = (fix.courseAccuracy >= 0 ? fix.courseAccuracy : 10) * .pi / 180
            let along = max(0.1, fix.speedAccuracy)
            velocity = (speed * sin(course), speed * cos(course), along, max(along, speed * courseSigma))
        }

        var stepSpeed: Double?
        if fix.horizontalAccuracy > config.poorGPSAccuracy, let cadence = rhythmCadence, let stride {
            stepSpeed = cadence / 60 * stride
        }

        let measurement = FilterMeasurement(
            time: fix.timestamp,
            activeTime: t,
            line: line,
            east: local.east,
            north: local.north,
            positionSigma: sigma,
            velocityEast: velocity?.east,
            velocityNorth: velocity?.north,
            velocitySigma: velocity?.along,
            velocityCrossSigma: velocity?.cross,
            zeroVelocity: stationary,
            stepSpeed: stepSpeed,
            stepSpeedSigma: stepSpeed == nil ? nil : config.stepSpeedSigma,
            altitude: elevation.currentAltitude
        )
        filterInputs.append(measurement)
        let (filtered, accepted) = filter.update(measurement)
        elevation.accumulate()

        let speed = stationary ? 0 : (trusted ?? filtered.speed)
        lastSpeed = speed
        if lastPointEast == nil || lastPointNorth == nil {
            appendPoint(filtered, frame: frame, fix: fix, activeTime: t, speed: speed, newLine: needsNewLine)
            needsNewLine = false
        } else if accepted, !stationary, let e = lastPointEast, let n = lastPointNorth {
            let step = hypot(filtered.east - e, filtered.north - n)
            if step >= config.minStep {
                distance += step
                appendPoint(filtered, frame: frame, fix: fix, activeTime: t, speed: speed, newLine: false)
            }
        }

        runClassifier(speed: speed, at: fix.timestamp, activeTime: t)
        let parts = classifier.components(at: fix.timestamp)
        let rhythmIsFresh = latestRhythm.map { abs(fix.timestamp.timeIntervalSince($0.timestamp)) <= config.classifier.rhythmFreshness } ?? false
        setEvidence(second: Int(t), motion: parts.motion, cadence: rhythmIsFresh ? nil : parts.cadence, intensity: nil)
    }

    public mutating func ingest(_ sample: MotionActivitySample) {
        guard state != .finished else { return }
        latestMotion = sample
        classifier.update(motion: sample)
    }

    public mutating func ingest(_ sample: PedometerSample) {
        guard state == .running || state == .paused else { return }
        if let previous = latestSteps {
            if sample.steps > previous { lastStepIncrease = sample.timestamp }
        } else if sample.steps > 0 {
            lastStepIncrease = sample.timestamp
        }
        latestSteps = max(latestSteps ?? 0, sample.steps)
        if let cadence = sample.cadence {
            latestCadence = cadence
            latestCadenceDate = sample.timestamp
            classifier.update(cadence: cadence, at: sample.timestamp)
        }
    }

    public mutating func ingest(_ sample: AltitudeSample) {
        guard state != .finished else { return }
        elevation.ingest(sample)
    }

    /// Accelerometer readings (about 25 at a time). Produces the step rhythm that
    /// feeds sprint detection.
    public mutating func ingest(_ batch: [AccelSample]) {
        guard state == .running || state == .paused, let start = startDate, let newest = batch.last else { return }
        let rhythm = rhythmAnalyzer.ingest(batch)
        guard state == .running else { return }
        for sample in rhythm where sample.timestamp >= start {
            latestRhythm = sample
            classifier.update(rhythm: sample)
            let cadence: Double?
            if sample.periodicity >= config.classifier.minRhythmPeriodicity, let c = sample.cadence {
                cadence = c
            } else {
                // No rhythm: standing (low intensity) counts as zero cadence; a phone
                // being handled (high intensity, no rhythm) says nothing.
                cadence = sample.intensity < 0.1 ? 0 : nil
            }
            setEvidence(second: Int(activeTime(at: sample.timestamp)), motion: nil, cadence: cadence, intensity: sample.intensity)
        }
        if !rhythm.isEmpty, newest.timestamp >= start {
            runClassifier(speed: lastSpeed, at: newest.timestamp, activeTime: activeTime(at: newest.timestamp))
        }
    }

    // MARK: - Snapshot

    public func snapshot(at now: Date) -> LiveSnapshot {
        let moving = activeTime(at: now)
        var currentPace: Double?
        var currentSpeed: Double?
        if state == .running, moving > 0, !track.isEmpty {
            let window = min(config.paceWindow, moving)
            let moved = distance - TrackMath.distance(atActiveTime: moving - window, in: track)
            if window >= 3, moved >= 3 {
                currentPace = window / moved
                currentSpeed = moved / window
            } else if window >= 3 {
                currentSpeed = 0
            }
        }

        let current = segments.last
        let sameKindCount = current.map { kind in segments.filter { $0.kind == kind.kind }.count } ?? 0
        let cadenceIsFresh = latestCadenceDate.map { now.timeIntervalSince($0) <= 10 } ?? false
        let rhythmCadence = freshRhythmCadence(at: now)

        return LiveSnapshot(
            state: state,
            elapsedTime: elapsedTime(at: now),
            movingTime: moving,
            distance: distance,
            currentPace: currentPace,
            averagePace: distance > 10 ? moving / distance : nil,
            currentSpeed: currentSpeed,
            segmentKind: current?.kind,
            segmentNumber: sameKindCount,
            segmentDuration: current.map { max(0, moving - $0.startTime) } ?? 0,
            sprintCount: segments.filter { $0.kind == .sprint }.count,
            elevationGain: elevation.gain,
            steps: steps,
            cadence: rhythmCadence ?? (cadenceIsFresh ? latestCadence : nil),
            gpsAccuracy: latestFix.map { $0.horizontalAccuracy }
        )
    }

    // MARK: - Internals

    func trustedSpeed(_ fix: LocationSample) -> Double? {
        guard fix.speed >= 0, fix.speedAccuracy >= 0, fix.speedAccuracy <= config.maxSpeedAccuracy else { return nil }
        return fix.speed
    }

    func freshRhythmCadence(at date: Date) -> Double? {
        guard let rhythm = latestRhythm,
              abs(date.timeIntervalSince(rhythm.timestamp)) <= config.classifier.rhythmFreshness,
              rhythm.periodicity >= config.classifier.minRhythmPeriodicity else { return nil }
        return rhythm.cadence
    }

    mutating func learnStride(fix: LocationSample, speed: Double?, cadence: Double?) {
        guard fix.horizontalAccuracy <= config.strideLearningAccuracy,
              let speed, speed > 0.5, let cadence, cadence > 30 else { return }
        let sample = speed / (cadence / 60)
        stride = stride.map { 0.9 * $0 + 0.1 * sample } ?? sample
    }

    func isStationary(at date: Date, speed: Double) -> Bool {
        guard speed < config.stationarySpeed else { return false }
        let motionSaysStill = latestMotion.map { $0.kind == .stationary && $0.confidence >= .medium } ?? false
        var noSteps = false
        if latestSteps != nil {
            if let lastIncrease = lastStepIncrease {
                noSteps = date.timeIntervalSince(lastIncrease) > config.stepStaleness
            } else {
                noSteps = true
            }
        }
        return motionSaysStill || noSteps
    }

    mutating func appendPoint(
        _ state: FilterState,
        frame: LocalFrame,
        fix: LocationSample,
        activeTime: TimeInterval,
        speed: Double,
        newLine: Bool
    ) {
        let coordinate = frame.toCoordinate(east: state.east, north: state.north)
        track.append(TrackPoint(
            timestamp: fix.timestamp,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: elevation.currentAltitude,
            speed: max(0, speed),
            activeTime: activeTime,
            distance: distance,
            startsNewLine: newLine && !track.isEmpty
        ))
        lastPointEast = state.east
        lastPointNorth = state.north
    }

    mutating func setEvidence(second: Int, motion: Double?, cadence: Double?, intensity: Double?) {
        guard second >= 0 else { return }
        while evidence.count <= second {
            evidence.append(EvidenceSample(second: evidence.count, motion: nil, cadence: nil, intensity: nil))
        }
        if let motion { evidence[second].motion = motion }
        if let cadence { evidence[second].cadence = cadence }
        if let intensity { evidence[second].intensity = intensity }
    }

    mutating func runClassifier(speed: Double?, at date: Date, activeTime t: TimeInterval) {
        if let transition = classifier.classify(speed: speed, at: date, activeTime: t) {
            if segments.isEmpty {
                segments.append(RunSegment(kind: transition.kind, startTime: 0, endTime: t, startDistance: 0, endDistance: distance))
            } else {
                let last = segments.count - 1
                let at = min(max(transition.at, segments[last].startTime), t)
                let distanceAt = TrackMath.distance(atActiveTime: at, in: track)
                segments[last].endTime = at
                segments[last].endDistance = distanceAt
                segments[last].topSpeed = TrackMath.topSpeed(in: track, from: segments[last].startTime, to: at)
                segments.append(RunSegment(kind: transition.kind, startTime: at, endTime: t, startDistance: distanceAt, endDistance: distance))
                segments[last + 1].topSpeed = TrackMath.topSpeed(in: track, from: at, to: t)
            }
        }
        guard !segments.isEmpty else { return }
        let last = segments.count - 1
        segments[last].endTime = max(t, segments[last].startTime)
        segments[last].endDistance = distance
        if let newest = track.indices.last, track[newest].activeTime >= segments[last].startTime {
            // The median needs the next point too, so score the previous one.
            let i = max(0, newest - 1)
            if track[i].activeTime >= segments[last].startTime {
                segments[last].topSpeed = max(segments[last].topSpeed, TrackMath.medianSpeed(around: i, in: track))
            }
        }
    }

    // MARK: - Finish

    /// Replaces the live track with one built from the smoothed (forward + backward)
    /// filter states.
    mutating func rebuildSmoothedTrack() {
        guard let frame, !filterInputs.isEmpty else { return }
        let states = RouteSmoother.smooth(filterInputs, config: config.filter)
        var rebuilt: [TrackPoint] = []
        rebuilt.reserveCapacity(track.count)
        var total = 0.0
        var lastEast = 0.0, lastNorth = 0.0
        var currentLine: Int?

        func append(_ m: FilterMeasurement, _ s: FilterState, newLine: Bool) {
            let c = frame.toCoordinate(east: s.east, north: s.north)
            rebuilt.append(TrackPoint(
                timestamp: m.time,
                latitude: c.latitude,
                longitude: c.longitude,
                altitude: m.altitude,
                speed: m.zeroVelocity ? 0 : s.speed,
                activeTime: m.activeTime,
                distance: total,
                startsNewLine: newLine
            ))
            lastEast = s.east
            lastNorth = s.north
        }

        for (m, s) in zip(filterInputs, states) {
            if m.line != currentLine {
                currentLine = m.line
                append(m, s, newLine: !rebuilt.isEmpty)
                continue
            }
            if m.zeroVelocity { continue }
            let step = hypot(s.east - lastEast, s.north - lastNorth)
            guard step >= config.minStep else { continue }
            total += step
            append(m, s, newLine: false)
        }
        track = rebuilt
        distance = total
    }

    func resegment(movingTime: TimeInterval) -> [RunSegment] {
        let seconds = Int(movingTime.rounded(.up))
        if seconds > 0, !evidence.isEmpty {
            let speeds: [Double?] = (0..<seconds).map { s in
                track.count > 1 ? TrackMath.speed(atActiveTime: Double(s) + 0.5, in: track) : nil
            }
            let labels = Resegmenter.labels(
                evidence: evidence, speeds: speeds, classifier: config.classifier, config: config.resegmenter
            )
            return Resegmenter.segments(labels: labels, movingTime: movingTime, track: track)
        }
        // No evidence: keep the live segments, measured against the final track.
        var result = segments
        for i in result.indices {
            result[i].startDistance = TrackMath.distance(atActiveTime: result[i].startTime, in: track)
            result[i].endDistance = TrackMath.distance(atActiveTime: result[i].endTime, in: track)
        }
        if !result.isEmpty {
            result[result.count - 1].endTime = max(movingTime, result[result.count - 1].startTime)
            result[result.count - 1].endDistance = distance
        }
        return result
    }

    func averageCadence(from start: TimeInterval, to end: TimeInterval) -> Double? {
        let lo = max(0, Int(start.rounded(.down)))
        let hi = min(evidence.count, Int(end.rounded(.up)))
        guard hi > lo else { return nil }
        var sum = 0.0, count = 0
        for i in lo..<hi {
            if let c = evidence[i].cadence, c > 0 {
                sum += c
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
