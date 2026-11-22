import Foundation

/// The user's preferred unit system. Switchable in Settings.
public enum DistanceUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case miles
    case kilometers

    public var id: String { rawValue }

    public var metersPerUnit: Double { self == .miles ? 1609.344 : 1000 }
    public var abbreviation: String { self == .miles ? "mi" : "km" }
    public var speedAbbreviation: String { self == .miles ? "mph" : "km/h" }
    public var elevationAbbreviation: String { self == .miles ? "ft" : "m" }
    public var displayName: String { self == .miles ? "Miles" : "Kilometers" }
    public var paceSuffix: String { "/" + abbreviation }

    public func distance(fromMeters meters: Double) -> Double { meters / metersPerUnit }
    public func meters(fromDistance value: Double) -> Double { value * metersPerUnit }

    public func speed(fromMetersPerSecond mps: Double) -> Double {
        self == .miles ? mps * 2.236_936_292_054_4 : mps * 3.6
    }

    public func elevation(fromMeters meters: Double) -> Double {
        self == .miles ? meters * 3.280_839_895 : meters
    }

    /// Seconds per unit distance, from seconds per meter.
    public func pace(fromSecondsPerMeter secondsPerMeter: Double) -> Double {
        secondsPerMeter * metersPerUnit
    }
}

/// Locale-independent formatting for everything Paqo displays.
public enum Format {
    /// "4:07", "31:04", "1:02:33".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(pad2(minutes)):\(pad2(secs))"
        }
        return "\(minutes):\(pad2(secs))"
    }

    /// "3.12" (no unit label).
    public static func distance(_ meters: Double, unit: DistanceUnit, decimals: Int = 2) -> String {
        fixed(unit.distance(fromMeters: max(0, meters)), decimals: decimals)
    }

    /// "9:57" (no suffix). Returns "--:--" when there is no meaningful pace.
    public static func pace(secondsPerMeter: Double?, unit: DistanceUnit) -> String {
        guard let secondsPerMeter, secondsPerMeter.isFinite, secondsPerMeter > 0 else { return "--:--" }
        let perUnit = unit.pace(fromSecondsPerMeter: secondsPerMeter)
        guard perUnit < 100 * 60 else { return "--:--" }
        let total = Int(perUnit.rounded())
        return "\(total / 60):\(pad2(total % 60))"
    }

    /// "14.8" (no unit label).
    public static func speed(_ metersPerSecond: Double, unit: DistanceUnit, decimals: Int = 1) -> String {
        fixed(unit.speed(fromMetersPerSecond: max(0, metersPerSecond)), decimals: decimals)
    }

    /// "312" (no unit label).
    public static func elevation(_ meters: Double, unit: DistanceUnit) -> String {
        let value = Int(unit.elevation(fromMeters: meters).rounded())
        return "\(value == 0 ? 0 : value)"
    }

    /// Fixed-point decimal without locale grouping, e.g. 3.1 -> "3.10".
    public static func fixed(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "0" }
        let places = max(0, min(decimals, 6))
        var factor = 1.0
        for _ in 0..<places { factor *= 10 }
        let scaled = (abs(value) * factor).rounded()
        let negative = value < 0 && scaled > 0
        let whole = Int(scaled / factor)
        let fraction = Int(scaled - Double(whole) * factor)
        var text = "\(whole)"
        if places > 0 {
            var fractionText = "\(fraction)"
            while fractionText.count < places { fractionText = "0" + fractionText }
            text += "." + fractionText
        }
        return negative ? "-" + text : text
    }

    static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
