import Foundation

/// Tracks altitude and elevation gain/loss.
///
/// Prefers the barometric altimeter (precise to well under a meter) and uses GPS
/// altitude only to anchor it to sea level. Falls back to GPS altitude alone if the
/// barometer never reports. Gain and loss use a dead band so sensor noise is not
/// counted as climbing.
public struct ElevationTracker: Codable, Sendable {
    public private(set) var source: AltitudeSource = .none
    public private(set) var gain: Double = 0
    public private(set) var loss: Double = 0

    var latestRelative: Double?
    var latestGPS: Double?
    var anchorSum: Double = 0
    var anchorCount: Int = 0
    var reference: Double?

    /// Dead band in meters for each source.
    public var barometerThreshold: Double = 1.0
    public var gpsThreshold: Double = 4.0
    /// GPS fixes with worse vertical accuracy than this are ignored.
    public var maxVerticalAccuracy: Double = 10
    /// How many GPS fixes to average when anchoring the barometer.
    public var anchorSamples: Int = 30

    public init() {}

    public mutating func ingest(_ sample: AltitudeSample) {
        if source != .barometer {
            source = .barometer
            reference = nil // Different frame; restart the dead band.
        }
        latestRelative = sample.relativeAltitude
    }

    public mutating func ingestGPS(altitude: Double?, verticalAccuracy: Double) {
        guard let altitude, verticalAccuracy > 0, verticalAccuracy <= maxVerticalAccuracy else { return }
        latestGPS = altitude
        switch source {
        case .barometer:
            if let relative = latestRelative, anchorCount < anchorSamples {
                anchorSum += altitude - relative
                anchorCount += 1
            }
        case .none:
            source = .gps
        case .gps:
            break
        }
    }

    /// Current altitude in the tracker's frame (relative when barometric).
    public var currentAltitude: Double? {
        switch source {
        case .barometer: return latestRelative
        case .gps: return latestGPS
        case .none: return nil
        }
    }

    /// Add to `currentAltitude` for meters above sea level.
    public var offset: Double {
        source == .barometer && anchorCount > 0 ? anchorSum / Double(anchorCount) : 0
    }

    /// Call whenever a point is committed while recording.
    public mutating func accumulate() {
        guard let altitude = currentAltitude else { return }
        guard let ref = reference else {
            reference = altitude
            return
        }
        let threshold = source == .barometer ? barometerThreshold : gpsThreshold
        let delta = altitude - ref
        if delta >= threshold {
            gain += delta
            reference = altitude
        } else if delta <= -threshold {
            loss += -delta
            reference = altitude
        }
    }

    /// Forget the dead-band reference (after a pause), so climbing done while paused
    /// is not counted.
    public mutating func resetReference() {
        reference = nil
    }
}
