import Foundation

/// Step rhythm worked out from the accelerometer over a short window.
public struct RhythmSample: Codable, Hashable, Sendable {
    /// Centre of the analysis window.
    public var timestamp: Date
    /// Steps per minute; nil when there's no clear rhythm (standing, phone handled).
    public var cadence: Double?
    /// How periodic the signal is, 0…1 (peak autocorrelation).
    public var periodicity: Double
    /// RMS of the acceleration magnitude around its mean, in g. Sprints hit far harder.
    public var intensity: Double

    public init(timestamp: Date, cadence: Double?, periodicity: Double, intensity: Double) {
        self.timestamp = timestamp
        self.cadence = cadence
        self.periodicity = periodicity
        self.intensity = intensity
    }
}

/// Turns 50 Hz accelerometer samples into a step cadence and impact intensity every
/// half second. Uses the magnitude, so it works whatever way the phone is held.
public struct StepRhythmAnalyzer: Codable, Sendable {
    public var window: TimeInterval = 4
    public var interval: TimeInterval = 0.5
    /// Lag range: 240 down to 60 steps per minute.
    public var minPeriod: TimeInterval = 0.25
    public var maxPeriod: TimeInterval = 1.0
    public var minPeriodicity: Double = 0.3
    public var minIntensity: Double = 0.03
    /// Prefer half the lag (one step instead of a two-step stride) when its peak is
    /// at least this fraction of the best one.
    public var halfLagRatio: Double = 0.6

    var times: [Double] = []
    var values: [Double] = []
    var nextEmit: Double?

    public init() {}

    public mutating func ingest(_ batch: [AccelSample]) -> [RhythmSample] {
        var out: [RhythmSample] = []
        for sample in batch {
            let t = sample.timestamp.timeIntervalSince1970
            if let last = times.last, t <= last { continue }
            times.append(t)
            values.append(sample.magnitude)
            if nextEmit == nil { nextEmit = t + window }
            if let due = nextEmit, t >= due - 1e-6 {
                if let rhythm = analyze(endingAt: t) { out.append(rhythm) }
                nextEmit = due + interval
                if t > due + interval { nextEmit = t + interval } // Gap in the data.
            }
        }
        trim()
        return out
    }

    mutating func trim() {
        guard let last = times.last else { return }
        let cutoff = last - window - 1
        if let firstKept = times.firstIndex(where: { $0 >= cutoff }), firstKept > 0 {
            times.removeFirst(firstKept)
            values.removeFirst(firstKept)
        }
    }

    func analyze(endingAt end: Double) -> RhythmSample? {
        guard let startIndex = times.firstIndex(where: { $0 >= end - window - 1e-6 }) else { return nil }
        let t = Array(times[startIndex...])
        let m = Array(values[startIndex...])
        let n = m.count
        guard n >= 20, let first = t.first, let last = t.last, last > first else { return nil }

        let dt = (last - first) / Double(n - 1)
        let mean = m.reduce(0, +) / Double(n)
        let d = m.map { $0 - mean }
        let energy = d.reduce(0) { $0 + $1 * $1 }
        let intensity = (energy / Double(n)).squareRoot()
        let centre = Date(timeIntervalSince1970: (first + last) / 2)

        let minLag = max(1, Int((minPeriod / dt).rounded(.up)))
        let maxLag = min(n - 2, Int((maxPeriod / dt).rounded(.down)))
        guard energy > 0, maxLag > minLag + 1 else {
            return RhythmSample(timestamp: centre, cadence: nil, periodicity: 0, intensity: intensity)
        }

        func r(_ lag: Int) -> Double {
            var sum = 0.0, a = 0.0, b = 0.0
            for i in 0..<(n - lag) {
                sum += d[i] * d[i + lag]
                a += d[i] * d[i]
                b += d[i + lag] * d[i + lag]
            }
            let denominator = (a * b).squareRoot()
            return denominator > 0 ? sum / denominator : 0
        }

        let lags = Array((minLag - 1)...(maxLag + 1))
        let scores = lags.map { r($0) }
        func score(_ lag: Int) -> Double { scores[lag - (minLag - 1)] }

        var best = minLag
        for lag in minLag...maxLag where score(lag) > score(best) { best = lag }

        // A two-step stride correlates at least as well as one step; take the step.
        let half = Int((Double(best) / 2).rounded())
        if half >= minLag {
            var halfBest = half
            for lag in max(minLag, half - 1)...min(maxLag, half + 1) where score(lag) > score(halfBest) { halfBest = lag }
            if score(halfBest) >= halfLagRatio * score(best) { best = halfBest }
        }

        let peak = score(best)
        // Parabolic interpolation for sub-sample precision.
        let y0 = score(best - 1), y1 = peak, y2 = score(best + 1)
        let curvature = y0 - 2 * y1 + y2
        let offset = curvature < 0 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / curvature)) : 0
        let period = (Double(best) + offset) * dt

        let hasRhythm = peak >= minPeriodicity && intensity >= minIntensity && period > 0
        return RhythmSample(
            timestamp: centre,
            cadence: hasRhythm ? 60 / period : nil,
            periodicity: max(0, peak),
            intensity: intensity
        )
    }
}
