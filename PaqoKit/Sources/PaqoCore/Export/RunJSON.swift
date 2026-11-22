import Foundation

public enum RunJSONError: Error, Equatable {
    case notPaqoRun
    case newerVersion(Int)
}

/// One run as a readable, self-describing JSON file ("paqo-run", version 1): full key
/// names with units, ISO 8601 dates. Holds everything in `Run`, so it imports back.
public enum RunJSON {
    public static let format = "paqo-run"
    public static let version = 1

    struct Header: Codable {
        var format: String?
        var version: Int?
    }

    struct File: Codable {
        struct Segment: Codable {
            var type: String
            var start_s: Double
            var end_s: Double
            var start_distance_m: Double
            var end_distance_m: Double
            var top_speed_mps: Double
            var avg_cadence_spm: Double?
        }

        struct Pause: Codable {
            var start: Date
            var end: Date?
        }

        struct Point: Codable {
            var time: Date
            var lat: Double
            var lon: Double
            var alt_m: Double?
            var speed_mps: Double
            var active_s: Double
            var distance_m: Double
            var new_line: Bool
        }

        var format: String
        var version: Int
        var id: UUID
        var name: String
        var start: Date
        var end: Date
        var distance_m: Double
        var moving_time_s: Double
        var elevation_gain_m: Double
        var elevation_loss_m: Double
        var altitude_source: String
        var altitude_offset_m: Double
        var steps: Int?
        var saved_to_health: Bool
        var engine_version: Int?
        var segments: [Segment]
        var pauses: [Pause]
        var track: [Point]
    }

    public static func encode(_ run: Run) throws -> Data {
        let file = File(
            format: format,
            version: version,
            id: run.id,
            name: run.name,
            start: run.startDate,
            end: run.endDate,
            distance_m: run.distance,
            moving_time_s: run.movingTime,
            elevation_gain_m: run.elevationGain,
            elevation_loss_m: run.elevationLoss,
            altitude_source: run.altitudeSource.rawValue,
            altitude_offset_m: run.altitudeOffset,
            steps: run.steps,
            saved_to_health: run.savedToHealth,
            engine_version: run.engineVersion,
            segments: run.segments.map {
                File.Segment(
                    type: $0.kind.rawValue,
                    start_s: $0.startTime,
                    end_s: $0.endTime,
                    start_distance_m: $0.startDistance,
                    end_distance_m: $0.endDistance,
                    top_speed_mps: $0.topSpeed,
                    avg_cadence_spm: $0.averageCadence
                )
            },
            pauses: run.pauses.map { File.Pause(start: $0.start, end: $0.end) },
            track: run.track.map {
                File.Point(
                    time: $0.timestamp, lat: $0.latitude, lon: $0.longitude, alt_m: $0.altitude,
                    speed_mps: $0.speed, active_s: $0.activeTime, distance_m: $0.distance, new_line: $0.startsNewLine
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.string(from: date))
        }
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> Run {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = ISO8601.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(text)")
            }
            return date
        }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == format,
              let fileVersion = header.version else { throw RunJSONError.notPaqoRun }
        guard fileVersion <= version else { throw RunJSONError.newerVersion(fileVersion) }
        let file = try decoder.decode(File.self, from: data)
        return Run(
            id: file.id,
            name: file.name,
            startDate: file.start,
            endDate: file.end,
            distance: file.distance_m,
            movingTime: file.moving_time_s,
            elevationGain: file.elevation_gain_m,
            elevationLoss: file.elevation_loss_m,
            altitudeSource: AltitudeSource(rawValue: file.altitude_source) ?? .none,
            altitudeOffset: file.altitude_offset_m,
            steps: file.steps,
            track: file.track.map {
                TrackPoint(
                    timestamp: $0.time, latitude: $0.lat, longitude: $0.lon, altitude: $0.alt_m,
                    speed: $0.speed_mps, activeTime: $0.active_s, distance: $0.distance_m, startsNewLine: $0.new_line
                )
            },
            segments: file.segments.map {
                RunSegment(
                    kind: SegmentKind(rawValue: $0.type) ?? .walk,
                    startTime: $0.start_s,
                    endTime: $0.end_s,
                    startDistance: $0.start_distance_m,
                    endDistance: $0.end_distance_m,
                    topSpeed: $0.top_speed_mps,
                    averageCadence: $0.avg_cadence_spm
                )
            },
            pauses: file.pauses.map { PauseInterval(start: $0.start, end: $0.end) },
            savedToHealth: file.saved_to_health,
            engineVersion: file.engine_version
        )
    }
}
