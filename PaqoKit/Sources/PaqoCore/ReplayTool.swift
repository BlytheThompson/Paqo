import Foundation

public enum ConfigOverrideError: Error, CustomStringConvertible {
    case unknownKey(String, valid: [String])
    case badValue(String)

    public var description: String {
        switch self {
        case .unknownKey(let key, let valid):
            return "Unknown setting '\(key)'. Valid settings:\n  " + valid.joined(separator: "\n  ")
        case .badValue(let text):
            return "Expected key=number, got '\(text)'."
        }
    }
}

/// `key=value` overrides for engine settings, for trying thresholds on a real log.
public enum ConfigOverrides {
    typealias Config = RunEngine.Configuration

    static let doubles: [(String, WritableKeyPath<Config, Double>)] = [
        ("sprintSpeed", \.classifier.sprintSpeed),
        ("walkSpeed", \.classifier.walkSpeed),
        ("sprintCadence", \.classifier.sprintCadence),
        ("walkCadence", \.classifier.walkCadence),
        ("sprintIntensity", \.classifier.sprintIntensity),
        ("walkIntensity", \.classifier.walkIntensity),
        ("toSprintDelay", \.classifier.toSprintDelay),
        ("toWalkDelay", \.classifier.toWalkDelay),
        ("cadenceFreshness", \.classifier.cadenceFreshness),
        ("rhythmFreshness", \.classifier.rhythmFreshness),
        ("minRhythmPeriodicity", \.classifier.minRhythmPeriodicity),
        ("decisionMargin", \.classifier.decisionMargin),
        ("switchPenalty", \.resegmenter.switchPenalty),
        ("emissionSlope", \.resegmenter.emissionSlope),
        ("accelerationSigma", \.filter.accelerationSigma),
        ("minPositionSigma", \.filter.minPositionSigma),
        ("gateChiSquare", \.filter.gateChiSquare),
        ("zeroVelocitySigma", \.filter.zeroVelocitySigma),
        ("maxHorizontalAccuracy", \.maxHorizontalAccuracy),
        ("downweightAccuracy", \.downweightAccuracy),
        ("poorGPSAccuracy", \.poorGPSAccuracy),
        ("strideLearningAccuracy", \.strideLearningAccuracy),
        ("minStep", \.minStep),
        ("paceWindow", \.paceWindow),
        ("stationarySpeed", \.stationarySpeed),
        ("stepStaleness", \.stepStaleness),
        ("maxSpeedAccuracy", \.maxSpeedAccuracy),
        ("stepSpeedSigma", \.stepSpeedSigma),
    ]

    static let ints: [(String, WritableKeyPath<Config, Int>)] = [
        ("maxConsecutiveRejections", \.filter.maxConsecutiveRejections),
    ]

    public static var keys: [String] { (doubles.map(\.0) + ints.map(\.0)).sorted() }

    public static func apply(_ assignments: [String], to config: inout RunEngine.Configuration) throws {
        for assignment in assignments {
            let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ConfigOverrideError.badValue(assignment) }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let text = parts[1].trimmingCharacters(in: .whitespaces)
            if let path = doubles.first(where: { $0.0 == key })?.1 {
                guard let value = Double(text) else { throw ConfigOverrideError.badValue(assignment) }
                config[keyPath: path] = value
            } else if let path = ints.first(where: { $0.0 == key })?.1 {
                guard let value = Int(text) else { throw ConfigOverrideError.badValue(assignment) }
                config[keyPath: path] = value
            } else {
                throw ConfigOverrideError.unknownKey(key, valid: keys)
            }
        }
    }
}

/// What the replay tool prints.
public enum ReplayReport {
    public static func text(for run: Run) -> String {
        let km = Format.fixed(run.distance / 1000, decimals: 3)
        let mi = Format.fixed(run.distance / 1609.344, decimals: 3)
        var lines = [
            "\(km) km (\(mi) mi) in \(Format.duration(run.movingTime)) · \(run.sprints.count) sprints",
            "",
            "seg  type     start   time     dist m   avg m/s  peak m/s",
        ]
        for (index, segment) in run.segments.enumerated() {
            let peak = TrackMath.peakSpeed(in: run.track, from: segment.startTime, to: segment.endTime).speed
            lines.append([
                "  " + pad("\(index + 1)", 2),
                pad(segment.kind.rawValue, 6, left: false),
                pad(Format.duration(segment.startTime), 7),
                pad(Format.duration(segment.duration), 7),
                pad(Format.fixed(segment.distance, decimals: 1), 9),
                pad(Format.fixed(segment.averageSpeed, decimals: 2), 8),
                pad(Format.fixed(peak, decimals: 2), 9),
            ].joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    struct Result: Codable {
        struct Segment: Codable {
            var type: String
            var start_s: Double
            var duration_s: Double
            var distance_m: Double
            var avg_speed_mps: Double
            var peak_speed_mps: Double
        }
        var distance_m: Double
        var moving_time_s: Double
        var sprint_count: Int
        var segments: [Segment]
    }

    public static func json(for run: Run) throws -> String {
        let result = Result(
            distance_m: run.distance,
            moving_time_s: run.movingTime,
            sprint_count: run.sprints.count,
            segments: run.segments.map { s in
                Result.Segment(
                    type: s.kind.rawValue,
                    start_s: s.startTime,
                    duration_s: s.duration,
                    distance_m: s.distance,
                    avg_speed_mps: s.averageSpeed,
                    peak_speed_mps: TrackMath.peakSpeed(in: run.track, from: s.startTime, to: s.endTime).speed
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }

    static func pad(_ text: String, _ width: Int, left: Bool = true) -> String {
        guard text.count < width else { return text }
        let spaces = String(repeating: " ", count: width - text.count)
        return left ? spaces + text : text + spaces
    }
}

/// Reads a sensor log from a folder (as saved on the phone) or a zip (as shared).
public enum SensorLogFiles {
    public static func read(from url: URL) throws -> [String: String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var files: [String: String] = [:]
        let wanted = Set(["meta.json"] + SensorLogCodec.fileNames)
        if isDirectory.boolValue {
            for name in wanted {
                if let data = try? Data(contentsOf: url.appendingPathComponent(name)) {
                    files[name] = String(decoding: data, as: UTF8.self)
                }
            }
        } else {
            for entry in try ZipReader.entries(of: Data(contentsOf: url)) {
                let name = (entry.path as NSString).lastPathComponent
                if wanted.contains(name) { files[name] = String(decoding: entry.data, as: UTF8.self) }
            }
        }
        return files
    }
}
