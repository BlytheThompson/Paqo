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

/// The run recorder. Pure logic: sensors push samples in, the UI reads snapshots out.
///
/// The whole engine is `Codable` so an in-progress run can be autosaved and recovered
/// if the app is killed mid-run.
public struct RunEngine: Codable, Sendable {
    public struct Configuration: Codable, Sendable, Equatable {
        /// Fixes less accurate than this (meters) are ignored.
        public var maxHorizontalAccuracy: Double = 25
        /// Fixes implying a faster speed than this (m/s) are glitches. Usain Bolt peaks ~12.4.
        public var maxSpeed: Double = 12.5
        /// Movement smaller than this between accepted fixes is treated as jitter (meters).
        /// Distance is measured from the last accepted fix, so nothing is lost.
        public var minStep: Double = 1.0
        /// Window for current pace and speed (seconds).
        public var paceWindow: TimeInterval = 15
        /// Below this speed (m/s), with no steps or a stationary activity, the runner is standing.
        public var stationarySpeed: Double = 0.5
        /// Seconds without new steps that count as "no steps".
        public var stepStaleness: TimeInterval = 4
        /// Doppler speed is trusted when its accuracy is at most this (m/s).
        public var maxSpeedAccuracy: Double = 1.5
        public var classifier = SegmentClassifier.Configuration()

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

    var lastAccepted: LocationSample?
    var needsNewLine = false
    var classifier: SegmentClassifier
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
        lastAccepted = nil
        needsNewLine = true
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
        if !segments.isEmpty {
            segments[segments.count - 1].endTime = max(moving, segments[segments.count - 1].startTime)
            segments[segments.count - 1].endDistance = distance
        }
        state = .finished
        endDate = end

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
            segments: SegmentSmoother.smooth(segments, track: track),
            pauses: pauses,
            savedToHealth: false
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
        if let last = lastAccepted, fix.timestamp <= last.timestamp { return }

        let t = activeTime(at: fix.timestamp)

        guard let last = lastAccepted else {
            // First fix of the run, or first after a resume: anchor without adding distance.
            elevation.ingestGPS(altitude: fix.altitude, verticalAccuracy: fix.verticalAccuracy)
            let speed = trustedSpeed(fix) ?? 0
            appendPoint(fix, activeTime: t, speed: speed, newLine: needsNewLine)
            needsNewLine = false
            lastAccepted = fix
            elevation.accumulate()
            runClassifier(speed: speed, at: fix.timestamp, activeTime: t)
            return
        }

        let step = Geo.distance(last.latitude, last.longitude, fix.latitude, fix.longitude)
        let dt = fix.timestamp.timeIntervalSince(last.timestamp)
        let impliedSpeed = dt > 0 ? step / dt : .infinity
        guard impliedSpeed <= config.maxSpeed else { return } // Glitch: skip this fix.

        elevation.ingestGPS(altitude: fix.altitude, verticalAccuracy: fix.verticalAccuracy)
        let speed = trustedSpeed(fix) ?? impliedSpeed

        // Standing still (traffic light): GPS wanders, but the feet don't.
        if isStationary(at: fix.timestamp, speed: speed) && step < max(8, fix.horizontalAccuracy) {
            runClassifier(speed: 0, at: fix.timestamp, activeTime: t)
            return
        }

        guard step >= config.minStep else {
            runClassifier(speed: speed, at: fix.timestamp, activeTime: t)
            return
        }

        distance += step
        appendPoint(fix, activeTime: t, speed: speed, newLine: false)
        lastAccepted = fix
        elevation.accumulate()
        runClassifier(speed: speed, at: fix.timestamp, activeTime: t)
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
            cadence: cadenceIsFresh ? latestCadence : nil,
            gpsAccuracy: latestFix.map { $0.horizontalAccuracy }
        )
    }

    // MARK: - Internals

    func trustedSpeed(_ fix: LocationSample) -> Double? {
        guard fix.speed >= 0, fix.speedAccuracy >= 0, fix.speedAccuracy <= config.maxSpeedAccuracy else { return nil }
        return fix.speed
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

    mutating func appendPoint(_ fix: LocationSample, activeTime: TimeInterval, speed: Double, newLine: Bool) {
        track.append(TrackPoint(
            timestamp: fix.timestamp,
            latitude: fix.latitude,
            longitude: fix.longitude,
            altitude: elevation.currentAltitude,
            speed: max(0, speed),
            activeTime: activeTime,
            distance: distance,
            startsNewLine: newLine && track.count > 0
        ))
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
}
