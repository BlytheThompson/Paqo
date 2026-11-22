import Foundation
@testable import PaqoCore

let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000) // fixed, deterministic

/// UTC Gregorian calendar with Monday-first weeks.
func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}

/// Builds a synthetic run: moves due north from a start point, one fix per second,
/// and produces matching pedometer and motion-activity samples.
struct TraceBuilder {
    var latitude = 37.7749
    var longitude = -122.4194
    var time = t0
    var steps = 0
    var altitude = 10.0
    var fixes: [LocationSample] = []
    var pedometer: [PedometerSample] = []
    var motion: [MotionActivitySample] = []
    var altitudes: [AltitudeSample] = []
    var relativeAltitude = 0.0

    /// Move for `seconds` at `speed` m/s. Activity and cadence follow the speed.
    mutating func move(seconds: Int, speed: Double, climb: Double = 0, accuracy: Double = 5) {
        let isSprint = speed >= 2.5
        let isStill = speed < 0.2
        motion.append(MotionActivitySample(
            timestamp: time,
            kind: isStill ? .stationary : (isSprint ? .running : .walking),
            confidence: .high
        ))
        let cadence = isStill ? 0.0 : (isSprint ? 170.0 : 110.0)
        for _ in 0..<seconds {
            time = time.addingTimeInterval(1)
            latitude += speed / Geo.metersPerDegreeLatitude(at: latitude)
            altitude += climb / Double(seconds)
            relativeAltitude += climb / Double(seconds)
            if !isStill { steps += Int((cadence / 60).rounded()) }
            fixes.append(LocationSample(
                timestamp: time,
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                horizontalAccuracy: accuracy,
                verticalAccuracy: 3,
                speed: speed,
                speedAccuracy: 0.3
            ))
            pedometer.append(PedometerSample(timestamp: time, steps: steps, cadence: isStill ? nil : cadence))
            altitudes.append(AltitudeSample(timestamp: time, relativeAltitude: relativeAltitude))
        }
    }

    /// Feed every sample to the engine in time order.
    func feed(_ engine: inout RunEngine, includeAltimeter: Bool = true) {
        var motionIndex = 0
        for (i, fix) in fixes.enumerated() {
            while motionIndex < motion.count && motion[motionIndex].timestamp < fix.timestamp {
                engine.ingest(motion[motionIndex])
                motionIndex += 1
            }
            if includeAltimeter { engine.ingest(altitudes[i]) }
            engine.ingest(pedometer[i])
            engine.ingest(fix)
        }
    }
}

/// A straight-line track at constant speed, for split and best-effort tests.
func straightTrack(segments: [(seconds: Int, speed: Double)], start: Date = t0) -> [TrackPoint] {
    var points: [TrackPoint] = []
    var distance = 0.0
    var time = 0.0
    var latitude = 0.0
    points.append(TrackPoint(timestamp: start, latitude: 0, longitude: 0, altitude: 0, speed: 0, activeTime: 0, distance: 0, startsNewLine: false))
    for segment in segments {
        for _ in 0..<segment.seconds {
            time += 1
            distance += segment.speed
            latitude += segment.speed / Geo.metersPerDegreeLatitude(at: latitude)
            points.append(TrackPoint(
                timestamp: start.addingTimeInterval(time),
                latitude: latitude,
                longitude: 0,
                altitude: distance / 100, // 1 m climb per 100 m
                speed: segment.speed,
                activeTime: time,
                distance: distance,
                startsNewLine: false
            ))
        }
    }
    return points
}
