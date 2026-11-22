import Foundation

/// Everything about one sprint.
public struct SprintDetail: Hashable, Sendable, Identifiable {
    /// Index of the segment in the run.
    public var id: Int
    /// 1-based sprint number.
    public var number: Int
    public var segment: RunSegment
    /// m/s.
    public var averageSpeed: Double
    /// m/s: highest 2-second average.
    public var peakSpeed: Double
    /// Seconds from the start of the sprint to its peak.
    public var timeToPeak: TimeInterval
    /// Steps per minute.
    public var averageCadence: Double?
    /// Meters climbed during the sprint.
    public var climb: Double
    /// The walk that followed, if any.
    public var restAfter: RunSegment?
    /// (last third's average speed − first third's) ÷ first third's. Negative means
    /// slowing down. Nil for sprints shorter than 6 s.
    public var inSprintFade: Double?

    /// Seconds per meter.
    public var averagePace: Double? { averageSpeed > 0 ? 1 / averageSpeed : nil }
}

/// Sprint numbers for a whole run, kept in the run index so trends never need to
/// load full routes.
public struct SprintStats: Codable, Hashable, Sendable {
    public var sprintCount: Int = 0
    /// Seconds.
    public var totalSprintTime: Double = 0
    /// Meters.
    public var totalSprintDistance: Double = 0
    /// Fraction of moving time spent sprinting, 0…1.
    public var sprintShare: Double = 0
    public var averageSprintTime: Double = 0
    public var averageSprintDistance: Double = 0
    /// Total sprint distance ÷ total sprint time, m/s.
    public var averageSprintSpeed: Double = 0
    /// By average speed, m/s.
    public var fastestSprintSpeed: Double = 0
    public var slowestSprintSpeed: Double = 0
    /// Fastest average speed among sprints of at least 10 s (for records).
    public var fastestTenSecondSprintSpeed: Double?
    /// Highest 2-second speed in any sprint, m/s.
    public var peakSpeed: Double = 0
    /// Mean walk between the first and last sprint, seconds.
    public var averageRest: Double?
    /// Total sprint time ÷ total rest between sprints.
    public var workRestRatio: Double?
    /// Average speed of the last third of sprints vs the first third (needs 3+).
    public var fade: Double?
    public var averageSprintCadence: Double?
    public var averageTimeToPeak: Double?

    public init() {}
}

public enum SprintAnalyzer {
    /// Sprints this short still count for everything except the fastest-sprint record.
    public static let recordMinimumDuration: TimeInterval = 10
    /// Short sprints only climb a metre or two, so use a finer dead band than the run's.
    static let climbDeadband = 0.5

    public static func details(for run: Run) -> [SprintDetail] {
        var result: [SprintDetail] = []
        var number = 0
        let track = run.track
        for (index, segment) in run.segments.enumerated() where segment.kind == .sprint {
            number += 1
            var peak = segment.topSpeed
            var peakTime = segment.startTime
            if track.count > 1 {
                let p = TrackMath.peakSpeed(in: track, from: segment.startTime, to: segment.endTime)
                peak = p.speed
                peakTime = p.time
            }
            var fade: Double?
            if segment.duration >= 6, track.count > 1 {
                let third = segment.duration / 3
                let first = (TrackMath.distance(atActiveTime: segment.startTime + third, in: track)
                    - TrackMath.distance(atActiveTime: segment.startTime, in: track)) / third
                let last = (TrackMath.distance(atActiveTime: segment.endTime, in: track)
                    - TrackMath.distance(atActiveTime: segment.endTime - third, in: track)) / third
                if first > 0 { fade = (last - first) / first }
            }
            let next = index + 1 < run.segments.count ? run.segments[index + 1] : nil
            result.append(SprintDetail(
                id: index,
                number: number,
                segment: segment,
                averageSpeed: segment.averageSpeed,
                peakSpeed: peak,
                timeToPeak: max(0, peakTime - segment.startTime),
                averageCadence: segment.averageCadence,
                climb: TrackMath.climb(in: track, from: segment.startTime, to: segment.endTime, deadband: climbDeadband),
                restAfter: next?.kind == .walk ? next : nil,
                inSprintFade: fade
            ))
        }
        return result
    }

    public static func stats(for run: Run) -> SprintStats {
        stats(for: run, details: details(for: run))
    }

    public static func stats(for run: Run, details: [SprintDetail]) -> SprintStats {
        var stats = SprintStats()
        let n = details.count
        guard n > 0 else { return stats }

        stats.sprintCount = n
        stats.totalSprintTime = details.reduce(0) { $0 + $1.segment.duration }
        stats.totalSprintDistance = details.reduce(0) { $0 + $1.segment.distance }
        stats.sprintShare = run.movingTime > 0 ? stats.totalSprintTime / run.movingTime : 0
        stats.averageSprintTime = stats.totalSprintTime / Double(n)
        stats.averageSprintDistance = stats.totalSprintDistance / Double(n)
        stats.averageSprintSpeed = stats.totalSprintTime > 0 ? stats.totalSprintDistance / stats.totalSprintTime : 0
        let speeds = details.map(\.averageSpeed)
        stats.fastestSprintSpeed = speeds.max() ?? 0
        stats.slowestSprintSpeed = speeds.min() ?? 0
        stats.fastestTenSecondSprintSpeed = details
            .filter { $0.segment.duration >= recordMinimumDuration }
            .map(\.averageSpeed)
            .max()
        stats.peakSpeed = details.map(\.peakSpeed).max() ?? 0

        // Rest: walks strictly between the first and last sprint.
        if let first = details.first?.id, let last = details.last?.id, last > first {
            let rests = run.segments[(first + 1)..<last].filter { $0.kind == .walk }.map(\.duration)
            if !rests.isEmpty {
                let total = rests.reduce(0, +)
                stats.averageRest = total / Double(rests.count)
                stats.workRestRatio = total > 0 ? stats.totalSprintTime / total : nil
            }
        }

        if n >= 3 {
            let k = max(1, n / 3)
            let firstMean = speeds.prefix(k).reduce(0, +) / Double(k)
            let lastMean = speeds.suffix(k).reduce(0, +) / Double(k)
            if firstMean > 0 { stats.fade = (lastMean - firstMean) / firstMean }
        }

        let cadences = details.compactMap(\.averageCadence)
        if !cadences.isEmpty { stats.averageSprintCadence = cadences.reduce(0, +) / Double(cadences.count) }
        stats.averageTimeToPeak = details.reduce(0) { $0 + $1.timeToPeak } / Double(n)
        return stats
    }
}
