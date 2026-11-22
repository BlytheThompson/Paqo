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
    /// Half-second accelerometer batches; second i owns batches 2i and 2i+1.
    var accelBatches: [[AccelSample]] = []
    var includeAccel = true
    var rng = SeededGenerator(seed: 42)
    let startTime = t0

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
        if includeAccel {
            let samples = syntheticAccel(
                start: time, seconds: Double(seconds), cadence: cadence,
                impact: isStill ? 0 : (isSprint ? 1.5 : 0.4), rng: &rng
            )
            var i = 0
            while i < samples.count {
                accelBatches.append(Array(samples[i..<min(i + 25, samples.count)]))
                i += 25
            }
        }
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
                speedAccuracy: 0.3,
                course: 0,
                courseAccuracy: 5
            ))
            pedometer.append(PedometerSample(timestamp: time, steps: steps, cadence: isStill ? nil : cadence))
            altitudes.append(AltitudeSample(timestamp: time, relativeAltitude: relativeAltitude))
        }
    }

    /// Every sample as the phone would deliver it: per second, activity changes, two
    /// accelerometer batches, altimeter, pedometer, then the GPS fix.
    func events(includeStart: Bool = true) -> [SensorEvent] {
        var out: [SensorEvent] = includeStart ? [.control(.start(startTime))] : []
        var motionIndex = 0
        for (i, fix) in fixes.enumerated() {
            while motionIndex < motion.count && motion[motionIndex].timestamp < fix.timestamp {
                out.append(.activity(motion[motionIndex]))
                motionIndex += 1
            }
            for b in [2 * i, 2 * i + 1] where b < accelBatches.count {
                out.append(.accelerometer(accelBatches[b]))
            }
            out.append(.altitude(altitudes[i]))
            out.append(.pedometer(pedometer[i]))
            out.append(.location(fix))
        }
        return out
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

/// Deterministic random numbers (SplitMix64) so noisy tests are repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal sample (Box–Muller).
    mutating func gaussian() -> Double {
        let u1 = max(Double.leastNonzeroMagnitude, Double(next() >> 11) / Double(1 << 53))
        let u2 = Double(next() >> 11) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

/// 50 Hz accelerometer signal for running or walking: gravity on z plus a short
/// impact pulse at every step (every other step scaled by `asymmetry`) and noise.
func syntheticAccel(
    start: Date,
    seconds: Double,
    cadence: Double,
    impact: Double,
    asymmetry: Double = 1,
    noise: Double = 0.02,
    rng: inout SeededGenerator
) -> [AccelSample] {
    let rate = 50.0
    let count = Int((seconds * rate).rounded())
    let period = cadence > 0 ? 60 / cadence : .infinity
    let sigma = 0.025
    var samples: [AccelSample] = []
    samples.reserveCapacity(count)
    for i in 0..<count {
        let t = Double(i) / rate
        var pulse = 0.0
        if impact > 0, period.isFinite {
            let k = (t / period).rounded()
            for step in [k - 1, k, k + 1] where step >= 0 {
                let height = Int(step) % 2 == 0 ? impact : impact * asymmetry
                let dt = t - step * period
                pulse += height * exp(-0.5 * (dt / sigma) * (dt / sigma))
            }
        }
        samples.append(AccelSample(
            timestamp: start.addingTimeInterval(t),
            x: noise * rng.gaussian(),
            y: noise * rng.gaussian(),
            z: 1 + pulse + noise * rng.gaussian()
        ))
    }
    return samples
}
