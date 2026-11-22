import Foundation
import XCTest
@testable import PaqoCore

/// Builds log files (header + rows) from events, the way a writer would.
func logFiles(for events: [SensorEvent], meta: SensorLogMeta) throws -> [String: String] {
    var lines: [String: [String]] = [:]
    for name in SensorLogCodec.fileNames { lines[name] = [SensorLogCodec.header(for: name)] }
    for (seq, event) in events.enumerated() {
        for row in SensorLogCodec.rows(for: event, seq: seq) {
            lines[row.file, default: []].append(row.line)
        }
    }
    var files = lines.mapValues { $0.joined(separator: "\n") + "\n" }
    files["meta.json"] = try SensorLogCodec.encodeMeta(meta)
    return files
}

func sampleMeta(config: RunEngine.Configuration = .init()) -> SensorLogMeta {
    SensorLogMeta(
        runID: UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!,
        appVersion: "1.1.0",
        engineVersion: 2,
        deviceModel: "iPhone18,2",
        startDate: t0,
        config: config
    )
}

final class SensorLogTests: XCTestCase {
    func mixedEvents(count: Int) -> [SensorEvent] {
        var events: [SensorEvent] = []
        for i in 0..<count {
            let time = t0.addingTimeInterval(Double(i) * 0.37 + 0.123456789)
            switch i % 6 {
            case 0:
                events.append(.location(LocationSample(
                    timestamp: time,
                    latitude: 37.774_912_345_6 + Double(i) * 1e-5,
                    longitude: -122.419_412_345_6,
                    altitude: i % 12 == 0 ? nil : 12.3456,
                    horizontalAccuracy: 4.567,
                    verticalAccuracy: 3.21,
                    speed: 3.14159,
                    speedAccuracy: 0.333,
                    course: 271.26,
                    courseAccuracy: 4.44
                )))
            case 1:
                events.append(.activity(MotionActivitySample(timestamp: time, kind: .running, confidence: .high)))
            case 2:
                events.append(.pedometer(PedometerSample(
                    timestamp: time,
                    steps: i * 3,
                    cadence: i % 4 == 0 ? nil : 171.987,
                    distance: i % 5 == 0 ? nil : 12.345
                )))
            case 3:
                events.append(.altitude(AltitudeSample(timestamp: time, relativeAltitude: -1.23456)))
            case 4:
                let batch = (0..<25).map { k in
                    AccelSample(
                        timestamp: time.addingTimeInterval(Double(k) * 0.02),
                        x: 0.012345, y: -0.98765, z: 1.5 + Double(k) * 0.01
                    )
                }
                events.append(.accelerometer(batch))
            default:
                events.append(.control(i % 2 == 0 ? .pause(time) : .resume(time)))
            }
        }
        return events
    }

    func testNormalizeIsIdempotent() {
        for event in mixedEvents(count: 12) {
            let once = SensorLogCodec.normalize(event)
            XCTAssertEqual(SensorLogCodec.normalize(once), once)
        }
    }

    func testDecodeOfRowsEqualsNormalizedEvents() throws {
        let events = mixedEvents(count: 200)
        let files = try logFiles(for: events, meta: sampleMeta())
        let log = try SensorLogCodec.decode(files: files)
        XCTAssertEqual(log.events.count, 200)
        XCTAssertEqual(log.events, events.map(SensorLogCodec.normalize))
    }

    func testOldLocationJSONDecodes() throws {
        let sample = LocationSample(timestamp: t0, latitude: 1, longitude: 2, speed: 3, speedAccuracy: 0.5)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as! [String: Any]
        object.removeValue(forKey: "course")
        object.removeValue(forKey: "courseAccuracy")
        let decoded = try JSONDecoder().decode(LocationSample.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.course, -1)
        XCTAssertEqual(decoded.courseAccuracy, -1)
        XCTAssertEqual(decoded.speed, 3)
    }

    func testMetaRoundTrip() throws {
        var config = RunEngine.Configuration()
        config.classifier.sprintCadence = 151
        let meta = sampleMeta(config: config)
        let files = ["meta.json": try SensorLogCodec.encodeMeta(meta)]
        XCTAssertEqual(try SensorLogCodec.decode(files: files).meta, meta)
    }
}
