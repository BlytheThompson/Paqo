import Foundation

/// What the sensors said about one second of moving time. Components are set
/// independently (rhythm arrives for its window centre, activity with each fix) and
/// missing ones carry forward from earlier seconds.
public struct EvidenceSample: Codable, Hashable, Sendable {
    public var second: Int
    /// Signed activity vote (+ running, − walking/standing).
    public var motion: Double?
    /// Steps per minute.
    public var cadence: Double?
    /// Impact intensity, g RMS.
    public var intensity: Double?

    public init(second: Int, motion: Double?, cadence: Double?, intensity: Double?) {
        self.second = second
        self.motion = motion
        self.cadence = cadence
        self.intensity = intensity
    }
}

/// Labels a whole run at once, sprint or walk for every second, with a two-state
/// hidden Markov model (Viterbi). Looking both ways in time puts boundaries where the
/// evidence actually changed instead of where a live detector became sure.
public enum Resegmenter {
    public struct Configuration: Codable, Equatable, Sendable {
        /// Cost (in nats) of switching between sprint and walk.
        public var switchPenalty: Double = 6.0
        /// How sharply the evidence score maps to a probability.
        public var emissionSlope: Double = 1.5

        public init() {}
    }

    /// One label per second; `speeds[i]` is the speed during second i (nil if unknown).
    public static func labels(
        evidence: [EvidenceSample],
        speeds: [Double?],
        classifier: SegmentClassifier.Configuration,
        config: Configuration
    ) -> [SegmentKind] {
        let count = speeds.count
        guard count > 0 else { return [] }
        let sorted = evidence.sorted { $0.second < $1.second }

        // Carry each component forward independently.
        var scores = [Double](repeating: 0, count: count)
        var motion: Double?, cadence: Double?, intensity: Double?
        var e = 0
        for second in 0..<count {
            while e < sorted.count && sorted[e].second <= second {
                if let m = sorted[e].motion { motion = m }
                if let c = sorted[e].cadence { cadence = c }
                if let i = sorted[e].intensity { intensity = i }
                e += 1
            }
            scores[second] = SegmentClassifier.score(
                motion: motion, cadence: cadence, intensity: intensity, speed: speeds[second], config: classifier
            )
        }

        // Viterbi over states 0 = walk, 1 = sprint.
        let k = config.emissionSlope
        var cost = [-logSigmoid(-k * scores[0]), -logSigmoid(k * scores[0])]
        var back = [[Int]](repeating: [0, 0], count: count)
        for t in 1..<max(1, count) where count > 1 {
            let emitWalk = -logSigmoid(-k * scores[t])
            let emitSprint = -logSigmoid(k * scores[t])
            var next = [0.0, 0.0]
            for state in 0..<2 {
                let stay = cost[state]
                let switchIn = cost[1 - state] + config.switchPenalty
                if stay <= switchIn {
                    next[state] = stay
                    back[t][state] = state
                } else {
                    next[state] = switchIn
                    back[t][state] = 1 - state
                }
                next[state] += state == 0 ? emitWalk : emitSprint
            }
            cost = next
        }

        var state = cost[1] < cost[0] ? 1 : 0
        var result = [SegmentKind](repeating: .walk, count: count)
        var t = count - 1
        while t >= 0 {
            result[t] = state == 1 ? .sprint : .walk
            if t > 0 { state = back[t][state] }
            t -= 1
        }
        return result
    }

    /// Turns per-second labels into segments, measuring distance along the track.
    public static func segments(labels: [SegmentKind], movingTime: TimeInterval, track: [TrackPoint]) -> [RunSegment] {
        guard !labels.isEmpty else { return [] }
        var segments: [RunSegment] = []
        var start = 0
        for i in 1...labels.count {
            if i == labels.count || labels[i] != labels[start] {
                let startTime = Double(start)
                let endTime = i == labels.count ? max(movingTime, startTime) : Double(i)
                segments.append(RunSegment(
                    kind: labels[start],
                    startTime: startTime,
                    endTime: endTime,
                    startDistance: TrackMath.distance(atActiveTime: startTime, in: track),
                    endDistance: TrackMath.distance(atActiveTime: endTime, in: track)
                ))
                start = i
            }
        }
        return segments
    }

    /// log(1 / (1 + e^−x)), stable for large |x|.
    static func logSigmoid(_ x: Double) -> Double {
        x >= 0 ? -log1p(exp(-x)) : x - log1p(exp(x))
    }
}
