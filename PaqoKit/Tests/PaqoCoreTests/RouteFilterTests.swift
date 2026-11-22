import Foundation
import XCTest
@testable import PaqoCore

final class RouteFilterTests: XCTestCase {
    func measurement(
        _ i: Int,
        east: Double,
        north: Double,
        sigma: Double = 4,
        velocity: (Double, Double)? = nil,
        zero: Bool = false,
        line: Int = 0
    ) -> FilterMeasurement {
        FilterMeasurement(
            time: t0.addingTimeInterval(Double(i)),
            activeTime: Double(i),
            line: line,
            east: east,
            north: north,
            positionSigma: sigma,
            velocityEast: velocity?.0,
            velocityNorth: velocity?.1,
            velocitySigma: velocity == nil ? nil : 0.3,
            zeroVelocity: zero,
            stepSpeed: nil,
            stepSpeedSigma: nil,
            altitude: nil
        )
    }

    /// 300 s due north at 3 m/s (900 m) with 4 m position noise.
    func straightRun(doppler: Bool, seed: UInt64 = 7) -> [FilterMeasurement] {
        var rng = SeededGenerator(seed: seed)
        return (0...300).map { i in
            measurement(
                i,
                east: 4 * rng.gaussian(),
                north: 3 * Double(i) + 4 * rng.gaussian(),
                velocity: doppler ? (0, 3) : nil
            )
        }
    }

    func pathLength(_ points: [(Double, Double)]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { sum, pair in
            let de = pair.1.0 - pair.0.0, dn = pair.1.1 - pair.0.1
            return sum + (de * de + dn * dn).squareRoot()
        }
    }

    func smoothedLength(_ measurements: [FilterMeasurement]) -> Double {
        pathLength(RouteSmoother.smooth(measurements, config: .init()).map { ($0.east, $0.north) })
    }

    func testSmoothedDistanceWithDopplerWithinOnePercent() {
        XCTAssertEqual(smoothedLength(straightRun(doppler: true)), 900, accuracy: 9)
    }

    func testSmoothedDistanceWithoutDopplerBeatsRaw() {
        let run = straightRun(doppler: false)
        let raw = pathLength(run.map { ($0.east, $0.north) })
        let smoothedError = abs(smoothedLength(run) - 900)
        XCTAssertLessThan(smoothedError, 27)
        XCTAssertLessThan(smoothedError, abs(raw - 900) / 2)
    }

    func testZeroVelocityHoldsStill() {
        var rng = SeededGenerator(seed: 11)
        let still = (0..<60).map { i in
            measurement(i, east: 4 * rng.gaussian(), north: 4 * rng.gaussian(), zero: true)
        }
        XCTAssertLessThan(smoothedLength(still), 2)
    }

    func testOutlierIsRejected() {
        var filter = RouteFilter(config: .init())
        var last = FilterState(east: 0, north: 0, velocityEast: 0, velocityNorth: 0)
        for i in 0...30 {
            last = filter.update(measurement(i, east: 0, north: 3 * Double(i), sigma: 5, velocity: (0, 3))).state
        }
        let result = filter.update(measurement(31, east: 80, north: 93, sigma: 5))
        XCTAssertFalse(result.accepted)
        XCTAssertLessThan(abs(result.state.east - last.east), 3)
    }

    func testLinesAreSmoothedIndependently() {
        let first = (0..<30).map { measurement($0, east: 0, north: 3 * Double($0), velocity: (0, 3)) }
        let second = (30..<60).map { measurement($0, east: 500, north: 3 * Double($0), velocity: (0, 3), line: 1) }
        let states = RouteSmoother.smooth(first + second, config: .init())
        XCTAssertEqual(states.count, 60)
        XCTAssertEqual(states[30].east, 500, accuracy: 10)
        XCTAssertEqual(states[30].north, 90, accuracy: 10)
    }
}
