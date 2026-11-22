import Foundation
import XCTest
@testable import PaqoCore

/// A run that exercises every field: pauses, missing altitudes and cadences.
func richRun(name: String = "Intervals") -> Run {
    var run = threeSprintRun()
    run.name = name
    run.steps = 812
    run.savedToHealth = true
    run.elevationGain = 2.7
    run.elevationLoss = 1.1
    run.altitudeSource = .barometer
    run.altitudeOffset = 31.5
    run.endDate = run.endDate.addingTimeInterval(30)
    run.pauses = [PauseInterval(start: t0.addingTimeInterval(100.25), end: t0.addingTimeInterval(130.25))]
    run.track[100].startsNewLine = true
    run.track[5].altitude = nil
    run.segments[0].averageCadence = nil
    return run
}

final class ExportTests: XCTestCase {
    func testCSVRoundTripsAwkwardFields() {
        let fields = ["a,b", "say \"hi\"", "two\nlines", "🏃", "", "plain"]
        let text = CSV.byteOrderMark + CSV.line(["h1", "h2", "h3", "h4", "h5", "h6"]) + CSV.line(fields)
        let rows = CSV.parse(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], fields)
        XCTAssertEqual(rows[0].first, "h1")
    }

    func testRunJSONRoundTrip() throws {
        let run = richRun()
        let data = try RunJSON.encode(run)
        let decoded = try RunJSON.decode(data)
        // Dates are stored to the millisecond.
        XCTAssertEqual(decoded.startDate.timeIntervalSince(run.startDate), 0, accuracy: 0.001)
        XCTAssertEqual(decoded.track[7].timestamp.timeIntervalSince(run.track[7].timestamp), 0, accuracy: 0.001)
        var expected = run
        expected.startDate = decoded.startDate
        expected.endDate = decoded.endDate
        expected.pauses = decoded.pauses
        for i in expected.track.indices { expected.track[i].timestamp = decoded.track[i].timestamp }
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(try RunJSON.encode(decoded), data)
    }

    func testRunJSONRejectsNewerVersion() throws {
        let text = String(decoding: try RunJSON.encode(richRun()), as: UTF8.self)
            .replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
        XCTAssertThrowsError(try RunJSON.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? RunJSONError, .newerVersion(2))
        }
        XCTAssertThrowsError(try RunJSON.decode(Data("{\"hello\": 1}".utf8))) { error in
            XCTAssertEqual(error as? RunJSONError, .notPaqoRun)
        }
    }

    func testRunJSONIsHumanReadable() throws {
        let text = String(decoding: try RunJSON.encode(richRun()), as: UTF8.self)
        XCTAssertTrue(text.contains("\"distance_m\""))
        XCTAssertTrue(text.contains("\"format\" : \"paqo-run\""))
        XCTAssertTrue(text.contains("\"2026-") || text.contains("\"2026") || text.contains("\"20"))
        XCTAssertFalse(text.contains("\"la\""))
        XCTAssertTrue(text.contains("\n"))
    }

    func testGPXHasOneSegmentPerLine() {
        let run = richRun()
        let gpx = GPX.document(for: run)
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertTrue(gpx.contains("<trkpt lat=\"\(Format.fixed(run.track[0].latitude, decimals: 6))\" lon=\"\(Format.fixed(run.track[0].longitude, decimals: 6))\">"))
        XCTAssertTrue(gpx.contains("<type>running</type>"))
        XCTAssertTrue(gpx.hasPrefix("<?xml"))
    }

    func testAwkwardNamesSurviveCSVAndGPX() {
        let name = "Hill, \"repeats\"\n🏃"
        let run = richRun(name: name)
        let utc = TimeZone(identifier: "UTC")!
        let rows = CSV.parse(CSV.line(BackupCSV.runsHeader(unit: .miles)) + CSV.line(BackupCSV.runRow(run, unit: .miles, timeZone: utc)))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][1], name)
        let sprintRows = BackupCSV.sprintRows(run, unit: .kilometers, timeZone: utc)
        XCTAssertEqual(CSV.parse(CSV.line(sprintRows[0]))[0][1], name)
        XCTAssertTrue(GPX.document(for: run).contains("Hill, &quot;repeats&quot;\n🏃"))
    }

    func testRunsRowMatchesHeader() {
        let utc = TimeZone(identifier: "UTC")!
        let run = Run(name: "5K", startDate: t0, endDate: t0.addingTimeInterval(1500), distance: 5000, movingTime: 1500)
        for unit in DistanceUnit.allCases {
            XCTAssertEqual(BackupCSV.runRow(run, unit: unit, timeZone: utc).count, BackupCSV.runsHeader(unit: unit).count)
            XCTAssertEqual(BackupCSV.sprintsHeader(unit: unit).count, BackupCSV.sprintRows(richRun(), unit: unit, timeZone: utc)[0].count)
        }
        let header = BackupCSV.runsHeader(unit: .miles)
        let row = BackupCSV.runRow(run, unit: .miles, timeZone: utc)
        XCTAssertEqual(row[header.firstIndex(of: "distance_mi")!], "3.11")
        XCTAssertEqual(row[header.firstIndex(of: "moving_time")!], "25:00")
        XCTAssertFalse(BackupReadme.text(unit: .miles).isEmpty)
    }

    func testThreeHourRunExportsQuickly() throws {
        let track = straightTrack(segments: [(10_800, 2.5)])
        let run = Run(name: "Long", startDate: t0, endDate: t0.addingTimeInterval(10_800), distance: 27_000, movingTime: 10_800, track: track)
        let started = Date()
        _ = try RunJSON.encode(run)
        _ = GPX.document(for: run)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }
}
