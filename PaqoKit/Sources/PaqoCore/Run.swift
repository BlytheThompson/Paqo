import Foundation

public enum SegmentKind: String, Codable, Sendable, CaseIterable {
    case sprint
    case walk

    public var displayName: String { self == .sprint ? "Sprint" : "Walk" }
}

/// One accepted point on the route.
public struct TrackPoint: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    /// Altitude in meters in the run's altitude frame (add `Run.altitudeOffset` for
    /// height above sea level when the source is the barometer).
    public var altitude: Double?
    /// Best speed estimate at this point, m/s.
    public var speed: Double
    /// Seconds since the run started, excluding pauses.
    public var activeTime: TimeInterval
    /// Cumulative distance in meters.
    public var distance: Double
    /// True for the first point after a pause: don't draw a line from the previous point.
    public var startsNewLine: Bool

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double?,
        speed: Double,
        activeTime: TimeInterval,
        distance: Double,
        startsNewLine: Bool
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.activeTime = activeTime
        self.distance = distance
        self.startsNewLine = startsNewLine
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    // Short keys: a one-hour run has ~3,600 points.
    enum CodingKeys: String, CodingKey {
        case timestamp = "t", latitude = "la", longitude = "lo", altitude = "al"
        case speed = "sp", activeTime = "at", distance = "d", startsNewLine = "nl"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        altitude = try c.decodeIfPresent(Double.self, forKey: .altitude)
        speed = try c.decode(Double.self, forKey: .speed)
        activeTime = try c.decode(Double.self, forKey: .activeTime)
        distance = try c.decode(Double.self, forKey: .distance)
        startsNewLine = try c.decodeIfPresent(Bool.self, forKey: .startsNewLine) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encodeIfPresent(altitude, forKey: .altitude)
        try c.encode(speed, forKey: .speed)
        try c.encode(activeTime, forKey: .activeTime)
        try c.encode(distance, forKey: .distance)
        if startsNewLine { try c.encode(true, forKey: .startsNewLine) }
    }
}

/// A stretch of the run that was either a sprint or a walk.
public struct RunSegment: Codable, Hashable, Sendable {
    public var kind: SegmentKind
    /// Active seconds since start.
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// Cumulative meters.
    public var startDistance: Double
    public var endDistance: Double
    /// m/s. Peak speed: the highest 2-second average (v1 runs: 3-point median).
    public var topSpeed: Double
    /// Steps per minute over the segment (v1.1 runs).
    public var averageCadence: Double?

    public init(
        kind: SegmentKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        startDistance: Double,
        endDistance: Double,
        topSpeed: Double = 0,
        averageCadence: Double? = nil
    ) {
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.startDistance = startDistance
        self.endDistance = endDistance
        self.topSpeed = topSpeed
        self.averageCadence = averageCadence
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
    public var distance: Double { max(0, endDistance - startDistance) }
    /// Seconds per meter.
    public var averagePace: Double? { distance > 1 ? duration / distance : nil }
    /// m/s.
    public var averageSpeed: Double { duration > 0 ? distance / duration : 0 }
}

public struct PauseInterval: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date?

    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public func duration(until now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

public enum AltitudeSource: String, Codable, Sendable {
    case barometer, gps, none
}

/// A finished run with everything needed to draw its summary.
public struct Run: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var startDate: Date
    public var endDate: Date
    /// Meters.
    public var distance: Double
    /// Seconds excluding pauses.
    public var movingTime: TimeInterval
    public var elevationGain: Double
    public var elevationLoss: Double
    public var altitudeSource: AltitudeSource
    /// Add to `TrackPoint.altitude` to get meters above sea level.
    public var altitudeOffset: Double
    public var steps: Int?
    public var track: [TrackPoint]
    public var segments: [RunSegment]
    public var pauses: [PauseInterval]
    public var savedToHealth: Bool
    /// Which detection/filter version produced this run; nil for v1 runs.
    public var engineVersion: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        startDate: Date,
        endDate: Date,
        distance: Double,
        movingTime: TimeInterval,
        elevationGain: Double = 0,
        elevationLoss: Double = 0,
        altitudeSource: AltitudeSource = .none,
        altitudeOffset: Double = 0,
        steps: Int? = nil,
        track: [TrackPoint] = [],
        segments: [RunSegment] = [],
        pauses: [PauseInterval] = [],
        savedToHealth: Bool = false,
        engineVersion: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.distance = distance
        self.movingTime = movingTime
        self.elevationGain = elevationGain
        self.elevationLoss = elevationLoss
        self.altitudeSource = altitudeSource
        self.altitudeOffset = altitudeOffset
        self.steps = steps
        self.track = track
        self.segments = segments
        self.pauses = pauses
        self.savedToHealth = savedToHealth
        self.engineVersion = engineVersion
    }

    public var elapsedTime: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
    /// Seconds per meter over moving time.
    public var averagePace: Double? { distance > 10 ? movingTime / distance : nil }
    public var sprints: [RunSegment] { segments.filter { $0.kind == .sprint } }
    public var walks: [RunSegment] { segments.filter { $0.kind == .walk } }
    public var topSpeed: Double { sprints.map(\.topSpeed).max() ?? segments.map(\.topSpeed).max() ?? 0 }
    /// Steps per minute.
    public var averageCadence: Double? {
        guard let steps, steps > 0, movingTime > 30 else { return nil }
        return Double(steps) / movingTime * 60
    }

    /// Wall-clock date for a moment expressed in active (moving) seconds.
    public func date(atActiveTime activeTime: TimeInterval) -> Date {
        var date = startDate.addingTimeInterval(activeTime)
        for pause in pauses.sorted(by: { $0.start < $1.start }) where pause.start <= date {
            date = date.addingTimeInterval(pause.duration(until: endDate))
        }
        return min(date, endDate)
    }

    /// Default name from the time of day, e.g. "Morning Run".
    public static func defaultName(for date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return "Morning Run"
        case 12..<17: return "Afternoon Run"
        case 17..<21: return "Evening Run"
        default: return "Night Run"
        }
    }
}

/// A standard distance tracked for best efforts and records.
public struct EffortDistance: Hashable, Sendable, Identifiable {
    public var meters: Double
    public var label: String
    public var id: Double { meters }

    public init(meters: Double, label: String) {
        self.meters = meters
        self.label = label
    }

    public static let oneK = EffortDistance(meters: 1000, label: "1K")
    public static let oneMile = EffortDistance(meters: 1609.344, label: "1 mile")
    public static let fiveK = EffortDistance(meters: 5000, label: "5K")
    public static let tenK = EffortDistance(meters: 10_000, label: "10K")
    public static let half = EffortDistance(meters: 21_097.5, label: "Half marathon")

    public static let standard: [EffortDistance] = [.oneK, .oneMile, .fiveK, .tenK, .half]
}

public struct BestEffort: Codable, Hashable, Sendable {
    public var distance: Double
    public var duration: TimeInterval

    public init(distance: Double, duration: TimeInterval) {
        self.distance = distance
        self.duration = duration
    }
}

/// Lightweight per-run facts kept in the index so history, totals and records never
/// need to load full routes.
public struct RunSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var startDate: Date
    public var distance: Double
    public var movingTime: TimeInterval
    public var elapsedTime: TimeInterval
    public var elevationGain: Double
    public var sprintCount: Int
    public var topSpeed: Double
    public var longestSprintDistance: Double
    public var longestSprintDuration: TimeInterval
    public var bestEfforts: [BestEffort]
    public var savedToHealth: Bool
    /// Non-optional on purpose: a v1 index without it fails to decode and is rebuilt
    /// from the run files.
    public var sprintStats: SprintStats

    public init(run: Run) {
        id = run.id
        name = run.name
        startDate = run.startDate
        distance = run.distance
        movingTime = run.movingTime
        elapsedTime = run.elapsedTime
        elevationGain = run.elevationGain
        let sprints = run.sprints
        sprintCount = sprints.count
        let stats = SprintAnalyzer.stats(for: run)
        sprintStats = stats
        // Peak speed by the 2-second rule for every run, old or new.
        if !sprints.isEmpty {
            topSpeed = stats.peakSpeed
        } else if run.track.count > 1 {
            topSpeed = TrackMath.peakSpeed(in: run.track, from: 0, to: run.movingTime).speed
        } else {
            topSpeed = run.topSpeed
        }
        longestSprintDistance = sprints.map(\.distance).max() ?? 0
        longestSprintDuration = sprints.map(\.duration).max() ?? 0
        bestEfforts = BestEffortCalculator.bestEfforts(
            in: run.track,
            distances: EffortDistance.standard.map(\.meters)
        )
        savedToHealth = run.savedToHealth
    }

    /// Seconds per meter.
    public var averagePace: Double? { distance > 10 ? movingTime / distance : nil }

    public func bestEffort(for distance: Double) -> TimeInterval? {
        bestEfforts.first { abs($0.distance - distance) < 0.5 }?.duration
    }
}
