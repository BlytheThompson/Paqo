import Foundation

public struct Split: Hashable, Sendable, Identifiable {
    /// 1-based.
    public var index: Int
    /// Meters covered: a full unit, or less for the final partial split.
    public var distance: Double
    /// Moving seconds.
    public var duration: TimeInterval
    /// Meters climbed (+) or descended (−) across the split, if altitude is known.
    public var elevationChange: Double?
    public var isPartial: Bool

    public var id: Int { index }
    /// Seconds per meter.
    public var pace: Double? { distance > 0 ? duration / distance : nil }
}

public enum SplitCalculator {
    /// Splits every `unitLength` meters (1609.344 for miles, 1000 for km). The final
    /// partial split is included when it is at least `minimumPartial` meters.
    public static func splits(for track: [TrackPoint], unitLength: Double, minimumPartial: Double = 10) -> [Split] {
        guard unitLength > 0, let first = track.first, let last = track.last, last.distance > first.distance else { return [] }
        var result: [Split] = []
        var previousDistance = first.distance
        var previousTime = first.activeTime
        var k = 1
        while first.distance + Double(k) * unitLength <= last.distance + 1e-9 {
            let boundary = first.distance + Double(k) * unitLength
            guard let time = TrackMath.activeTime(atDistance: boundary, in: track) else { break }
            result.append(Split(
                index: k,
                distance: unitLength,
                duration: time - previousTime,
                elevationChange: elevationChange(from: previousDistance, to: boundary, in: track),
                isPartial: false
            ))
            previousDistance = boundary
            previousTime = time
            k += 1
        }
        let remaining = last.distance - previousDistance
        if remaining >= minimumPartial {
            result.append(Split(
                index: k,
                distance: remaining,
                duration: last.activeTime - previousTime,
                elevationChange: elevationChange(from: previousDistance, to: last.distance, in: track),
                isPartial: true
            ))
        }
        return result
    }

    static func elevationChange(from a: Double, to b: Double, in track: [TrackPoint]) -> Double? {
        guard let start = TrackMath.altitude(atDistance: a, in: track),
              let end = TrackMath.altitude(atDistance: b, in: track) else { return nil }
        return end - start
    }
}

public enum BestEffortCalculator {
    /// Fastest moving time to cover `target` meters anywhere in the run.
    public static func bestEffort(distance target: Double, in track: [TrackPoint]) -> TimeInterval? {
        guard target > 0, track.count >= 2, let first = track.first, let last = track.last,
              last.distance - first.distance >= target - 1e-9 else { return nil }
        var best: TimeInterval?
        var i = 0
        for j in 1..<track.count {
            let end = track[j]
            let startDistance = end.distance - target
            guard startDistance >= first.distance - 1e-9 else { continue }
            // Advance i so that track[i].distance <= startDistance < track[i + 1].distance.
            while i + 1 < j && track[i + 1].distance <= startDistance { i += 1 }
            let a = track[i]
            let b = track[min(i + 1, j)]
            let startTime: TimeInterval
            if b.distance > a.distance {
                let f = max(0, min(1, (startDistance - a.distance) / (b.distance - a.distance)))
                startTime = a.activeTime + (b.activeTime - a.activeTime) * f
            } else {
                startTime = a.activeTime
            }
            let duration = end.activeTime - startTime
            if duration > 0, best == nil || duration < best! { best = duration }
        }
        return best
    }

    public static func bestEfforts(in track: [TrackPoint], distances: [Double]) -> [BestEffort] {
        distances.compactMap { d in bestEffort(distance: d, in: track).map { BestEffort(distance: d, duration: $0) } }
    }
}

/// One sample of the summary charts.
public struct ProfilePoint: Hashable, Sendable, Identifiable {
    /// Meters from the start.
    public var distance: Double
    /// Meters above sea level, if known.
    public var altitude: Double?
    /// Seconds per meter over the bucket ending here, if moving.
    public var pace: Double?
    public var kind: SegmentKind?
    public var id: Double { distance }
}

public enum ProfileBuilder {
    /// Evenly spaced samples along the run for the pace and elevation charts.
    public static func profile(for run: Run, samples: Int = 120) -> [ProfilePoint] {
        let track = run.track
        guard let first = track.first, let last = track.last, last.distance - first.distance > 20, samples > 1 else { return [] }
        let total = last.distance - first.distance
        // Buckets of at least 25 m so pace isn't dominated by GPS noise.
        let bucket = max(25, total / Double(samples))
        var points: [ProfilePoint] = []
        var d = first.distance
        while d <= last.distance + 1e-9 {
            let altitude = TrackMath.altitude(atDistance: d, in: track).map { $0 + run.altitudeOffset }
            var pace: Double?
            if d - bucket >= first.distance - 1e-9,
               let t1 = TrackMath.activeTime(atDistance: d, in: track),
               let t0 = TrackMath.activeTime(atDistance: max(first.distance, d - bucket), in: track),
               t1 > t0 {
                pace = (t1 - t0) / min(bucket, d - first.distance)
            }
            let time = TrackMath.activeTime(atDistance: d, in: track) ?? 0
            let kind = run.segments.first { time >= $0.startTime && time <= $0.endTime }?.kind
            points.append(ProfilePoint(distance: d - first.distance, altitude: altitude, pace: pace, kind: kind))
            d += bucket
        }
        return points
    }
}
