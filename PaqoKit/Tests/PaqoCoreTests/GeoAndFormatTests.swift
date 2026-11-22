import XCTest
@testable import PaqoCore

final class GeoTests: XCTestCase {
    func testOneDegreeOfLongitudeAtEquator() {
        // WGS-84: 111,319.49 m per degree of longitude at the equator.
        XCTAssertEqual(Geo.distance(0, 0, 0, 1), 111_319.49, accuracy: 1)
    }

    func testOneDegreeOfLatitudeAt45() {
        // Meridian arc for 44.5°–45.5° ≈ 111,132 m.
        XCTAssertEqual(Geo.distance(44.5, 0, 45.5, 0), 111_132, accuracy: 5)
    }

    func testShortHopMatchesComponents() {
        let lat = 37.7749
        let north = 30 / Geo.metersPerDegreeLatitude(at: lat)
        let east = 40 / Geo.metersPerDegreeLongitude(at: lat)
        XCTAssertEqual(Geo.distance(lat, -122.0, lat + north, -122.0 + east), 50, accuracy: 0.05)
    }

    func testAntimeridianWraps() {
        XCTAssertEqual(Geo.distance(0, 179.9999, 0, -179.9999), 22.26, accuracy: 0.05)
    }
}

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Format.duration(0), "0:00")
        XCTAssertEqual(Format.duration(7.9), "0:07")
        XCTAssertEqual(Format.duration(247), "4:07")
        XCTAssertEqual(Format.duration(1864), "31:04")
        XCTAssertEqual(Format.duration(3753), "1:02:33")
    }

    func testDistance() {
        XCTAssertEqual(Format.distance(5021.08, unit: .miles), "3.12")
        XCTAssertEqual(Format.distance(5000, unit: .kilometers), "5.00")
        XCTAssertEqual(Format.distance(1234.5, unit: .kilometers, decimals: 1), "1.2")
        XCTAssertEqual(Format.distance(-3, unit: .kilometers), "0.00")
    }

    func testPace() {
        // 597 s per mile → 9:57 /mi.
        XCTAssertEqual(Format.pace(secondsPerMeter: 597 / 1609.344, unit: .miles), "9:57")
        XCTAssertEqual(Format.pace(secondsPerMeter: 0.3, unit: .kilometers), "5:00")
        XCTAssertEqual(Format.pace(secondsPerMeter: nil, unit: .miles), "--:--")
        XCTAssertEqual(Format.pace(secondsPerMeter: 10, unit: .miles), "--:--")
    }

    func testSpeedAndElevation() {
        XCTAssertEqual(Format.speed(6.6, unit: .miles), "14.8")
        XCTAssertEqual(Format.speed(5, unit: .kilometers), "18.0")
        XCTAssertEqual(Format.elevation(100, unit: .miles), "328")
        XCTAssertEqual(Format.elevation(-0.4, unit: .kilometers), "0")
    }

    func testFixed() {
        XCTAssertEqual(Format.fixed(3.105, decimals: 2), "3.11")
        XCTAssertEqual(Format.fixed(0.05, decimals: 1), "0.1")
        XCTAssertEqual(Format.fixed(-1.25, decimals: 1), "-1.3")
        XCTAssertEqual(Format.fixed(12, decimals: 0), "12")
        XCTAssertEqual(Format.fixed(1.999, decimals: 2), "2.00")
    }
}
