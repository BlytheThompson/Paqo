import Foundation

/// What the replay shows at one moment.
public struct ReplayState: Equatable, Sendable {
    public var activeTime: TimeInterval
    public var coordinate: Coordinate?
    /// Meters so far.
    public var distance: Double
    /// m/s.
    public var speed: Double
    public var segmentKind: SegmentKind?
    /// "Sprint 3" → 3.
    public var segmentNumber: Int
    public var segmentElapsed: TimeInterval
}

/// Plays a finished run back: position, stats and the route drawn so far at any
/// moment of moving time.
public struct ReplayTimeline: Sendable {
    let track: [TrackPoint]
    let segments: [RunSegment]
    public let duration: TimeInterval

    public init(run: Run) {
        track = run.track
        segments = run.segments
        duration = run.movingTime
    }

    public func state(at time: TimeInterval) -> ReplayState {
        let t = min(max(0, time), duration)
        var kind: SegmentKind?
        var number = 0
        var elapsed = 0.0
        if let index = segmentIndex(at: t) {
            let segment = segments[index]
            kind = segment.kind
            number = segments[0...index].filter { $0.kind == segment.kind }.count
            elapsed = t - segment.startTime
        }
        return ReplayState(
            activeTime: t,
            coordinate: TrackMath.coordinate(atActiveTime: t, in: track),
            distance: TrackMath.distance(atActiveTime: t, in: track),
            speed: TrackMath.speed(atActiveTime: t, in: track),
            segmentKind: kind,
            segmentNumber: number,
            segmentElapsed: elapsed
        )
    }

    /// The route up to `time`, coloured by segment, ending exactly at the playhead.
    public func trail(upTo time: TimeInterval) -> [RoutePiece] {
        let t = min(max(0, time), duration)
        guard let first = track.first, t > first.activeTime else { return [] }
        let end = TrackMath.firstIndex(atOrAfter: t, in: track)
        var partial = Array(track[..<end])
        if let coordinate = TrackMath.coordinate(atActiveTime: t, in: track) {
            partial.append(TrackPoint(
                timestamp: first.timestamp,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                altitude: nil,
                speed: 0,
                activeTime: t,
                distance: TrackMath.distance(atActiveTime: t, in: track),
                startsNewLine: end < track.count && track[end].startsNewLine && track[end].activeTime == t
            ))
        }
        return RouteBuilder.pieces(track: partial, segments: segments)
    }

    func segmentIndex(at t: TimeInterval) -> Int? {
        guard !segments.isEmpty else { return nil }
        return segments.firstIndex { t >= $0.startTime && t < $0.endTime } ?? (segments.count - 1)
    }
}
