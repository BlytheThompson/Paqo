import Foundation

/// Decides, fix by fix, whether the runner is sprinting or walking.
///
/// Three independent signals vote:
/// - the motion coprocessor's activity classifier (running / walking / stationary),
/// - step cadence from the pedometer,
/// - GPS speed.
/// A switch only happens after the new state has held for a short delay, and the
/// boundary is back-dated to when the evidence first changed, so segment start times
/// stay accurate.
public struct SegmentClassifier: Codable, Sendable {
    public struct Configuration: Codable, Sendable, Equatable {
        /// m/s at or above which speed votes "sprint" (~10:44 /mi).
        public var sprintSpeed: Double = 2.5
        /// m/s at or below which speed votes "walk" (~14:07 /mi).
        public var walkSpeed: Double = 1.9
        /// Steps per minute at or above which cadence votes "sprint".
        public var sprintCadence: Double = 145
        /// Steps per minute at or below which cadence votes "walk".
        public var walkCadence: Double = 125
        /// Accelerometer impact intensity (g RMS) at or above which it votes "sprint".
        public var sprintIntensity: Double = 0.7
        /// Intensity at or below which it votes "walk".
        public var walkIntensity: Double = 0.35
        /// A rhythm sample (timestamped at its window's centre) counts this long.
        public var rhythmFreshness: TimeInterval = 3
        /// Rhythm cadence below this periodicity is ignored.
        public var minRhythmPeriodicity: Double = 0.3
        /// Seconds the sprint evidence must hold before switching walk → sprint.
        public var toSprintDelay: TimeInterval = 1.5
        /// Seconds the walk evidence must hold before switching sprint → walk.
        public var toWalkDelay: TimeInterval = 2
        /// Cadence older than this is ignored.
        public var cadenceFreshness: TimeInterval = 6
        /// |score| below this is "can't tell" and doesn't push either way.
        public var decisionMargin: Double = 0.25

        public init() {}
    }

    public struct Transition: Equatable, Sendable {
        public var kind: SegmentKind
        /// Active time the new segment starts at.
        public var at: TimeInterval
    }

    public var config: Configuration
    public private(set) var current: SegmentKind?
    var pendingKind: SegmentKind?
    var pendingSince: TimeInterval?
    var lastMotion: MotionActivitySample?
    var lastCadence: Double?
    var lastCadenceDate: Date?
    var lastRhythm: RhythmSample?

    public init(config: Configuration = Configuration()) {
        self.config = config
    }

    public mutating func update(motion: MotionActivitySample) {
        lastMotion = motion
    }

    public mutating func update(cadence: Double, at date: Date) {
        lastCadence = cadence
        lastCadenceDate = date
    }

    public mutating func update(rhythm: RhythmSample) {
        lastRhythm = rhythm
    }

    /// The evidence that counts right now: the activity vote (signed weight), a
    /// cadence (accelerometer rhythm when fresh, else the pedometer) and the impact
    /// intensity (accelerometer only).
    public func components(at date: Date) -> (motion: Double, cadence: Double?, intensity: Double?) {
        var motionVote = 0.0
        if let motion = lastMotion {
            let weight: Double
            switch motion.confidence {
            case .low: weight = 0.5
            case .medium: weight = 1.0
            case .high: weight = 1.5
            }
            switch motion.kind {
            case .running: motionVote = weight
            case .walking, .stationary: motionVote = -weight
            case .cycling, .automotive, .unknown: break
            }
        }

        if let rhythm = lastRhythm, abs(date.timeIntervalSince(rhythm.timestamp)) <= config.rhythmFreshness {
            let cadence = rhythm.periodicity >= config.minRhythmPeriodicity ? rhythm.cadence : nil
            return (motionVote, cadence, rhythm.intensity)
        }

        var cadence: Double?
        if let c = lastCadence, let when = lastCadenceDate, date.timeIntervalSince(when) <= config.cadenceFreshness {
            cadence = c
        }
        return (motionVote, cadence, nil)
    }

    /// Positive means sprint, negative means walk. Roughly in [-4.5, 4.5].
    public func score(speed: Double?, at date: Date) -> Double {
        let parts = components(at: date)
        return Self.score(motion: parts.motion, cadence: parts.cadence, intensity: parts.intensity, speed: speed, config: config)
    }

    /// The evidence score from its parts; shared with whole-run re-segmentation.
    public static func score(motion: Double?, cadence: Double?, intensity: Double?, speed: Double?, config: Configuration) -> Double {
        var score = motion ?? 0
        if let cadence { score += vote(cadence, low: config.walkCadence, high: config.sprintCadence) }
        if let intensity { score += vote(intensity, low: config.walkIntensity, high: config.sprintIntensity) }
        if let speed, speed >= 0 { score += vote(speed, low: config.walkSpeed, high: config.sprintSpeed) }
        return score
    }

    /// The label the evidence points to right now, or nil if it can't tell.
    public func instantaneousLabel(speed: Double?, at date: Date) -> SegmentKind? {
        let s = score(speed: speed, at: date)
        if s > config.decisionMargin { return .sprint }
        if s < -config.decisionMargin { return .walk }
        return nil
    }

    /// Feed one moment of the run. Returns a transition when a new segment begins.
    /// The very first decision returns a transition at the given active time; callers
    /// usually start the first segment at 0.
    public mutating func classify(speed: Double?, at date: Date, activeTime: TimeInterval) -> Transition? {
        let label = instantaneousLabel(speed: speed, at: date)

        guard let current else {
            guard let label else { return nil }
            self.current = label
            return Transition(kind: label, at: activeTime)
        }

        guard let label else { return nil } // Undecided: neither confirms nor cancels.

        if label == current {
            pendingKind = nil
            pendingSince = nil
            return nil
        }

        if pendingKind != label {
            pendingKind = label
            pendingSince = activeTime
        }

        let delay = label == .sprint ? config.toSprintDelay : config.toWalkDelay
        if let since = pendingSince, activeTime - since >= delay {
            self.current = label
            pendingKind = nil
            pendingSince = nil
            return Transition(kind: label, at: since)
        }
        return nil
    }

    /// Maps a value to a vote in [-1, 1]: -1 at or below `low`, +1 at or above `high`.
    static func vote(_ value: Double, low: Double, high: Double) -> Double {
        if value >= high { return 1 }
        if value <= low { return -1 }
        let mid = (low + high) / 2
        return (value - mid) / ((high - low) / 2)
    }
}

/// Cleans up segments after a run: absorbs blips that are too short to be real.
public enum SegmentSmoother {
    public static func smooth(
        _ segments: [RunSegment],
        track: [TrackPoint],
        minSprintDuration: TimeInterval = 5,
        minSprintDistance: Double = 15,
        minWalkDuration: TimeInterval = 5
    ) -> [RunSegment] {
        guard segments.count > 1 else { return recomputeTopSpeeds(segments, track: track) }
        var result = segments

        // 1. A very short walk between two sprints is part of one sprint (a stumble).
        if result.count >= 3 {
            for i in 1..<(result.count - 1)
            where result[i].kind == .walk
                && result[i - 1].kind == .sprint
                && result[i + 1].kind == .sprint
                && result[i].duration < minWalkDuration {
                result[i].kind = .sprint
            }
        }
        result = merge(result)

        // 2. A sprint that is too short or too small is just a quick step while walking.
        for i in result.indices where result[i].kind == .sprint
            && (result[i].duration < minSprintDuration || result[i].distance < minSprintDistance) {
            result[i].kind = .walk
        }
        result = merge(result)

        return recomputeTopSpeeds(result, track: track)
    }

    static func merge(_ segments: [RunSegment]) -> [RunSegment] {
        var merged: [RunSegment] = []
        for segment in segments {
            if var last = merged.last, last.kind == segment.kind {
                last.endTime = segment.endTime
                last.endDistance = segment.endDistance
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    static func recomputeTopSpeeds(_ segments: [RunSegment], track: [TrackPoint]) -> [RunSegment] {
        segments.map { segment in
            var s = segment
            s.topSpeed = TrackMath.peakSpeed(in: track, from: segment.startTime, to: segment.endTime).speed
            return s
        }
    }
}
