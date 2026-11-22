import Foundation

/// Describes a sensor log: which run, which app and engine, and the engine settings
/// the run was recorded with.
public struct SensorLogMeta: Codable, Equatable, Sendable {
    public var format = "paqo-sensor-log"
    public var version = 1
    public var runID: UUID
    public var appVersion: String
    public var engineVersion: Int
    public var deviceModel: String
    public var startDate: Date
    /// nil when the settings were written by a version whose settings no longer decode.
    public var config: RunEngine.Configuration?

    public init(
        runID: UUID,
        appVersion: String,
        engineVersion: Int,
        deviceModel: String,
        startDate: Date,
        config: RunEngine.Configuration?
    ) {
        self.runID = runID
        self.appVersion = appVersion
        self.engineVersion = engineVersion
        self.deviceModel = deviceModel
        self.startDate = startDate
        self.config = config
    }

    enum CodingKeys: String, CodingKey {
        case format, version, runID, appVersion, engineVersion, deviceModel, startDate, config
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        runID = try c.decode(UUID.self, forKey: .runID)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        engineVersion = try c.decodeIfPresent(Int.self, forKey: .engineVersion) ?? 0
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel) ?? ""
        startDate = try c.decode(Date.self, forKey: .startDate)
        // Lenient: settings from an older engine may not decode once new knobs exist.
        config = try? c.decodeIfPresent(RunEngine.Configuration.self, forKey: .config)
    }
}

/// A decoded sensor log: its description and every event in arrival order.
public struct SensorLog: Equatable, Sendable {
    public var meta: SensorLogMeta
    public var events: [SensorEvent]

    public init(meta: SensorLogMeta, events: [SensorEvent]) {
        self.meta = meta
        self.events = events
    }
}

public enum SensorLogError: Error, Equatable {
    case missingMeta
    case unreadableMeta
}

/// The sensor log's on-disk format: plain CSV, one file per sensor, plus `meta.json`.
///
/// Every row starts with `seq`, a counter shared by all files that records arrival
/// order; the rows of one accelerometer batch share their batch's `seq`. Numbers have
/// fixed precision. `normalize` passes an event through exactly that text form, so
/// the engine can be fed the very values the log will replay.
public enum SensorLogCodec {
    public static let fileNames = ["gps.csv", "activity.csv", "pedometer.csv", "altimeter.csv", "accel.csv", "events.csv"]

    static let headers: [String: String] = [
        "gps.csv": "seq,time,lat,lon,alt,h_acc,v_acc,speed,speed_acc,course,course_acc",
        "activity.csv": "seq,time,kind,confidence",
        "pedometer.csv": "seq,time,steps,cadence,distance",
        "altimeter.csv": "seq,time,relative_alt",
        "accel.csv": "seq,time,x,y,z",
        "events.csv": "seq,time,event",
    ]

    public static func header(for file: String) -> String {
        headers[file] ?? ""
    }

    // MARK: - Encoding

    public static func rows(for event: SensorEvent, seq: Int) -> [(file: String, line: String)] {
        let s = "\(seq)"
        switch event {
        case .location(let f):
            let fields = [
                s, time(f.timestamp), n(f.latitude, 6), n(f.longitude, 6), f.altitude.map { n($0, 2) } ?? "",
                n(f.horizontalAccuracy, 2), n(f.verticalAccuracy, 2), n(f.speed, 3), n(f.speedAccuracy, 3),
                n(f.course, 1), n(f.courseAccuracy, 1),
            ]
            return [("gps.csv", fields.joined(separator: ","))]
        case .activity(let a):
            return [("activity.csv", [s, time(a.timestamp), a.kind.rawValue, "\(a.confidence.rawValue)"].joined(separator: ","))]
        case .pedometer(let p):
            let fields = [s, time(p.timestamp), "\(p.steps)", p.cadence.map { n($0, 2) } ?? "", p.distance.map { n($0, 2) } ?? ""]
            return [("pedometer.csv", fields.joined(separator: ","))]
        case .altitude(let a):
            return [("altimeter.csv", [s, time(a.timestamp), n(a.relativeAltitude, 3)].joined(separator: ","))]
        case .accelerometer(let batch):
            return batch.map { a in
                ("accel.csv", [s, time(a.timestamp), n(a.x, 4), n(a.y, 4), n(a.z, 4)].joined(separator: ","))
            }
        case .control(let c):
            return [("events.csv", [s, time(c.date), c.name].joined(separator: ","))]
        }
    }

    public static func encodeMeta(_ meta: SensorLogMeta) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.string(from: date))
        }
        return String(decoding: try encoder.encode(meta), as: UTF8.self)
    }

    /// The event exactly as it will read back from the log.
    public static func normalize(_ event: SensorEvent) -> SensorEvent {
        let rows = rows(for: event, seq: 0)
        if case .accelerometer = event {
            return .accelerometer(rows.compactMap { parseAccel(fields($0.line)) })
        }
        guard let row = rows.first, let parsed = parse(file: row.file, fields: fields(row.line)) else { return event }
        return parsed
    }

    // MARK: - Decoding

    public static func decode(files: [String: String]) throws -> SensorLog {
        guard let metaText = files["meta.json"] else { throw SensorLogError.missingMeta }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = ISO8601.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(text)")
            }
            return date
        }
        guard let meta = try? decoder.decode(SensorLogMeta.self, from: Data(metaText.utf8)) else {
            throw SensorLogError.unreadableMeta
        }

        var tagged: [(seq: Int, event: SensorEvent)] = []
        for file in fileNames {
            guard let text = files[file] else { continue }
            var batchSeq: Int?
            var batch: [AccelSample] = []
            func flushBatch() {
                if let seq = batchSeq, !batch.isEmpty { tagged.append((seq, .accelerometer(batch))) }
                batchSeq = nil
                batch = []
            }
            for (index, raw) in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).enumerated() where index > 0 {
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
                let f = fields(line)
                guard let seq = f.first.flatMap({ Int($0) }) else { continue }
                if file == "accel.csv" {
                    guard let sample = parseAccel(f) else { continue }
                    if batchSeq != seq { flushBatch() }
                    batchSeq = seq
                    batch.append(sample)
                } else if let event = parse(file: file, fields: f) {
                    tagged.append((seq, event))
                }
            }
            flushBatch()
        }
        // Stable sort keeps file order for (impossible) equal seqs.
        let ordered = tagged.enumerated().sorted { a, b in
            a.element.seq != b.element.seq ? a.element.seq < b.element.seq : a.offset < b.offset
        }
        return SensorLog(meta: meta, events: ordered.map(\.element.event))
    }

    // MARK: - Helpers

    static func fields(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    static func n(_ value: Double, _ decimals: Int) -> String {
        Format.fixed(value, decimals: decimals)
    }

    static func time(_ date: Date) -> String {
        Format.fixed(date.timeIntervalSince1970, decimals: 6)
    }

    static func date(_ text: String) -> Date? {
        Double(text).map { Date(timeIntervalSince1970: $0) }
    }

    static func double(_ text: String) -> Double? { Double(text) }

    static func optionalDouble(_ text: String) -> Double?? {
        if text.isEmpty { return .some(nil) }
        guard let value = Double(text) else { return nil }
        return .some(value)
    }

    static func parseAccel(_ f: [String]) -> AccelSample? {
        guard f.count == 5, let t = date(f[1]), let x = double(f[2]), let y = double(f[3]), let z = double(f[4]) else { return nil }
        return AccelSample(timestamp: t, x: x, y: y, z: z)
    }

    static func parse(file: String, fields f: [String]) -> SensorEvent? {
        switch file {
        case "gps.csv":
            guard f.count == 11, let t = date(f[1]), let lat = double(f[2]), let lon = double(f[3]),
                  let alt = optionalDouble(f[4]), let h = double(f[5]), let v = double(f[6]),
                  let sp = double(f[7]), let spAcc = double(f[8]), let course = double(f[9]),
                  let courseAcc = double(f[10]) else { return nil }
            return .location(LocationSample(
                timestamp: t, latitude: lat, longitude: lon, altitude: alt,
                horizontalAccuracy: h, verticalAccuracy: v, speed: sp, speedAccuracy: spAcc,
                course: course, courseAccuracy: courseAcc
            ))
        case "activity.csv":
            guard f.count == 4, let t = date(f[1]), let kind = MotionActivityKind(rawValue: f[2]),
                  let raw = Int(f[3]), let confidence = MotionConfidence(rawValue: raw) else { return nil }
            return .activity(MotionActivitySample(timestamp: t, kind: kind, confidence: confidence))
        case "pedometer.csv":
            guard f.count == 5, let t = date(f[1]), let steps = Int(f[2]),
                  let cadence = optionalDouble(f[3]), let distance = optionalDouble(f[4]) else { return nil }
            return .pedometer(PedometerSample(timestamp: t, steps: steps, cadence: cadence, distance: distance))
        case "altimeter.csv":
            guard f.count == 3, let t = date(f[1]), let rel = double(f[2]) else { return nil }
            return .altitude(AltitudeSample(timestamp: t, relativeAltitude: rel))
        case "events.csv":
            guard f.count == 3, let t = date(f[1]), let control = ControlEvent(name: f[2], date: t) else { return nil }
            return .control(control)
        default:
            return nil
        }
    }
}

/// ISO 8601 with milliseconds, e.g. "2026-11-22T07:12:03.120Z".
enum ISO8601 {
    /// ISO8601DateFormatter is thread-safe; creating one per date made exports slow.
    static let withMilliseconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(from date: Date) -> String {
        withMilliseconds.string(from: date)
    }

    static func date(from text: String) -> Date? {
        withMilliseconds.date(from: text) ?? plain.date(from: text)
    }
}
