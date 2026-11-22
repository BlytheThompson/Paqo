import Foundation

/// Interpolation helpers over a track. Track points are ordered by `activeTime`, and
/// `distance` never decreases.
public enum TrackMath {
    /// Cumulative distance at an active time, linearly interpolated.
    public static func distance(atActiveTime time: TimeInterval, in track: [TrackPoint]) -> Double {
        guard let first = track.first, let last = track.last else { return 0 }
        if time <= first.activeTime { return first.distance }
        if time >= last.activeTime { return last.distance }
        // First index with activeTime >= time.
        var low = 0, high = track.count - 1
        while low < high {
            let mid = (low + high) / 2
            if track[mid].activeTime < time { low = mid + 1 } else { high = mid }
        }
        let b = track[low]
        let a = track[low - 1]
        let span = b.activeTime - a.activeTime
        guard span > 0 else { return b.distance }
        let f = (time - a.activeTime) / span
        return a.distance + (b.distance - a.distance) * f
    }

    /// Earliest active time at which the cumulative distance reached `distance`.
    public static func activeTime(atDistance distance: Double, in track: [TrackPoint]) -> TimeInterval? {
        guard let first = track.first, let last = track.last, distance <= last.distance else { return nil }
        if distance <= first.distance { return first.activeTime }
        let j = firstIndex(withDistanceAtLeast: distance, in: track)
        let b = track[j]
        let a = track[j - 1]
        let span = b.distance - a.distance
        guard span > 0 else { return b.activeTime }
        let f = (distance - a.distance) / span
        return a.activeTime + (b.activeTime - a.activeTime) * f
    }

    /// Altitude at a cumulative distance, interpolated. Nil when no altitudes exist nearby.
    public static func altitude(atDistance distance: Double, in track: [TrackPoint]) -> Double? {
        guard let first = track.first, let last = track.last else { return nil }
        if distance <= first.distance { return first.altitude }
        if distance >= last.distance { return last.altitude }
        let j = firstIndex(withDistanceAtLeast: distance, in: track)
        let b = track[j]
        let a = track[j - 1]
        guard let altA = a.altitude, let altB = b.altitude else { return a.altitude ?? b.altitude }
        let span = b.distance - a.distance
        guard span > 0 else { return altB }
        let f = (distance - a.distance) / span
        return altA + (altB - altA) * f
    }

    /// Index of the first point whose distance is >= `distance`. Requires
    /// first.distance < distance <= last.distance.
    static func firstIndex(withDistanceAtLeast distance: Double, in track: [TrackPoint]) -> Int {
        var low = 0, high = track.count - 1
        while low < high {
            let mid = (low + high) / 2
            if track[mid].distance < distance { low = mid + 1 } else { high = mid }
        }
        return max(1, low)
    }

    /// Peak speed between two active times: the highest average speed held over
    /// `window` seconds, measured along the track. `time` is the middle of that window.
    /// A span shorter than the window returns its overall average.
    public static func peakSpeed(
        in track: [TrackPoint],
        from start: TimeInterval,
        to end: TimeInterval,
        window: TimeInterval = 2
    ) -> (speed: Double, time: TimeInterval) {
        guard !track.isEmpty, end > start else { return (0, start) }
        if end - start <= window {
            let d = distance(atActiveTime: end, in: track) - distance(atActiveTime: start, in: track)
            return (max(0, d / (end - start)), (start + end) / 2)
        }
        func average(endingAt t: TimeInterval) -> Double {
            max(0, (distance(atActiveTime: t, in: track) - distance(atActiveTime: t - window, in: track)) / window)
        }
        var bestTime = start + window
        var best = average(endingAt: bestTime)
        let endSpeed = average(endingAt: end)
        if endSpeed > best { best = endSpeed; bestTime = end }
        var i = firstIndex(atOrAfter: start + window, in: track)
        while i < track.count && track[i].activeTime <= end {
            let s = average(endingAt: track[i].activeTime)
            if s > best { best = s; bestTime = track[i].activeTime }
            i += 1
        }
        return (best, bestTime - window / 2)
    }

    /// Metres climbed between two active times, ignoring wiggles under `deadband`.
    public static func climb(in track: [TrackPoint], from start: TimeInterval, to end: TimeInterval, deadband: Double = 1) -> Double {
        var gain = 0.0
        var reference: Double?
        var i = firstIndex(atOrAfter: start, in: track)
        while i < track.count && track[i].activeTime <= end {
            if let altitude = track[i].altitude {
                if let ref = reference {
                    if altitude - ref >= deadband {
                        gain += altitude - ref
                        reference = altitude
                    } else if altitude - ref <= -deadband {
                        reference = altitude
                    }
                } else {
                    reference = altitude
                }
            }
            i += 1
        }
        return gain
    }

    /// Position at an active time, interpolated between track points.
    public static func coordinate(atActiveTime time: TimeInterval, in track: [TrackPoint]) -> Coordinate? {
        guard let first = track.first, let last = track.last else { return nil }
        if time <= first.activeTime { return first.coordinate }
        if time >= last.activeTime { return last.coordinate }
        let j = firstIndex(atOrAfter: time, in: track)
        let a = track[j - 1], b = track[j]
        let span = b.activeTime - a.activeTime
        guard span > 0 else { return b.coordinate }
        let f = (time - a.activeTime) / span
        return Coordinate(
            latitude: a.latitude + (b.latitude - a.latitude) * f,
            longitude: a.longitude + (b.longitude - a.longitude) * f
        )
    }

    /// Speed around an active time: distance covered from t−1 s to t+1 s. Distance
    /// based, so a stop with no track points reads as (nearly) zero.
    public static func speed(atActiveTime time: TimeInterval, in track: [TrackPoint]) -> Double {
        guard let first = track.first, let last = track.last, last.activeTime > first.activeTime else { return 0 }
        let a = max(first.activeTime, time - 1)
        let b = min(last.activeTime, time + 1)
        guard b > a else { return 0 }
        return max(0, (distance(atActiveTime: b, in: track) - distance(atActiveTime: a, in: track)) / (b - a))
    }

    /// Index of the first point with activeTime >= time (track.count if none).
    static func firstIndex(atOrAfter time: TimeInterval, in track: [TrackPoint]) -> Int {
        var low = 0, high = track.count
        while low < high {
            let mid = (low + high) / 2
            if track[mid].activeTime < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Spike-filtered top speed between two active times: the maximum of a 3-point
    /// rolling median, so a single bad GPS fix cannot set a record.
    public static func topSpeed(in track: [TrackPoint], from start: TimeInterval, to end: TimeInterval) -> Double {
        guard !track.isEmpty else { return 0 }
        var best = 0.0
        for i in track.indices where track[i].activeTime >= start && track[i].activeTime <= end {
            best = max(best, medianSpeed(around: i, in: track))
        }
        return best
    }

    /// Median of the speeds at i-1, i, i+1 (clamped to the track).
    public static func medianSpeed(around i: Int, in track: [TrackPoint]) -> Double {
        let lo = max(0, i - 1)
        let hi = min(track.count - 1, i + 1)
        let speeds = (lo...hi).map { track[$0].speed }.sorted()
        if speeds.count == 2 { return (speeds[0] + speeds[1]) / 2 }
        return speeds[speeds.count / 2]
    }
}

/// A drawable piece of the route: consecutive points of one kind, without pause gaps.
public struct RoutePiece: Hashable, Sendable, Identifiable {
    public var id: Int
    public var kind: SegmentKind?
    public var points: [Coordinate]
}

public enum RouteBuilder {
    /// Splits the track into pieces coloured by segment kind. Neighbouring pieces share
    /// their boundary point so the line looks continuous; pause gaps are left open.
    public static func pieces(track: [TrackPoint], segments: [RunSegment]) -> [RoutePiece] {
        guard !track.isEmpty else { return [] }
        var result: [RoutePiece] = []
        var current: [Coordinate] = []
        var currentKind: SegmentKind? = kind(at: track[0].activeTime, in: segments)
        var segmentIndex = 0

        func kindFor(_ time: TimeInterval) -> SegmentKind? {
            guard !segments.isEmpty else { return nil }
            while segmentIndex < segments.count - 1 && time >= segments[segmentIndex].endTime {
                segmentIndex += 1
            }
            return segments[segmentIndex].kind
        }

        for point in track {
            let k = kindFor(point.activeTime)
            if point.startsNewLine && !current.isEmpty {
                if current.count > 1 { result.append(RoutePiece(id: result.count, kind: currentKind, points: current)) }
                current = []
                currentKind = k
            }
            if k != currentKind && !current.isEmpty {
                current.append(point.coordinate)
                if current.count > 1 { result.append(RoutePiece(id: result.count, kind: currentKind, points: current)) }
                current = []
            }
            currentKind = k
            current.append(point.coordinate)
        }
        if current.count > 1 { result.append(RoutePiece(id: result.count, kind: currentKind, points: current)) }
        return result
    }

    static func kind(at time: TimeInterval, in segments: [RunSegment]) -> SegmentKind? {
        segments.first { time >= $0.startTime && time < $0.endTime }?.kind ?? segments.last?.kind
    }
}
