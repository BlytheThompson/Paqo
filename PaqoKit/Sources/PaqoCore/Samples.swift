import Foundation

/// One raw GPS fix, mirroring the useful parts of `CLLocation`.
public struct LocationSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    /// Meters above sea level; nil when the fix has no valid altitude.
    public var altitude: Double?
    /// Radius of uncertainty in meters. Negative means the fix is invalid.
    public var horizontalAccuracy: Double
    /// Negative means altitude is invalid.
    public var verticalAccuracy: Double
    /// Doppler speed in m/s. Negative means unavailable.
    public var speed: Double
    /// Negative means unavailable.
    public var speedAccuracy: Double
    /// Direction of travel in degrees from true north. Negative means invalid.
    public var course: Double
    /// Degrees. Negative means invalid.
    public var courseAccuracy: Double

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double = 5,
        verticalAccuracy: Double = -1,
        speed: Double = -1,
        speedAccuracy: Double = -1,
        course: Double = -1,
        courseAccuracy: Double = -1
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    enum CodingKeys: String, CodingKey {
        case timestamp, latitude, longitude, altitude, horizontalAccuracy, verticalAccuracy
        case speed, speedAccuracy, course, courseAccuracy
    }

    // Course fields arrived in v1.1; older autosaves don't have them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        altitude = try c.decodeIfPresent(Double.self, forKey: .altitude)
        horizontalAccuracy = try c.decode(Double.self, forKey: .horizontalAccuracy)
        verticalAccuracy = try c.decode(Double.self, forKey: .verticalAccuracy)
        speed = try c.decode(Double.self, forKey: .speed)
        speedAccuracy = try c.decode(Double.self, forKey: .speedAccuracy)
        course = try c.decodeIfPresent(Double.self, forKey: .course) ?? -1
        courseAccuracy = try c.decodeIfPresent(Double.self, forKey: .courseAccuracy) ?? -1
    }
}

public enum MotionActivityKind: String, Codable, Sendable {
    case stationary, walking, running, cycling, automotive, unknown
}

public enum MotionConfidence: Int, Codable, Sendable, Comparable {
    case low = 0, medium = 1, high = 2

    public static func < (lhs: MotionConfidence, rhs: MotionConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Output of the motion coprocessor's activity classifier (CMMotionActivity).
/// Arrives only when the activity changes, so the latest one stays valid until replaced.
public struct MotionActivitySample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var kind: MotionActivityKind
    public var confidence: MotionConfidence

    public init(timestamp: Date, kind: MotionActivityKind, confidence: MotionConfidence) {
        self.timestamp = timestamp
        self.kind = kind
        self.confidence = confidence
    }
}

/// Pedometer update (CMPedometerData). Steps are cumulative since the run started.
public struct PedometerSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var steps: Int
    /// Steps per minute, if the pedometer reported a current cadence.
    public var cadence: Double?
    /// Pedometer's own distance estimate in meters, if any.
    public var distance: Double?

    public init(timestamp: Date, steps: Int, cadence: Double? = nil, distance: Double? = nil) {
        self.timestamp = timestamp
        self.steps = steps
        self.cadence = cadence
        self.distance = distance
    }
}

/// Barometric altimeter update (CMAltimeter). Relative to when the altimeter started.
public struct AltitudeSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var relativeAltitude: Double

    public init(timestamp: Date, relativeAltitude: Double) {
        self.timestamp = timestamp
        self.relativeAltitude = relativeAltitude
    }
}

/// One accelerometer reading (CMAccelerometerData), in g, including gravity.
public struct AccelSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var x: Double
    public var y: Double
    public var z: Double

    public init(timestamp: Date, x: Double, y: Double, z: Double) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}
