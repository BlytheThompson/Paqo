import Foundation
import XCTest
@testable import PaqoCore

final class StepRhythmTests: XCTestCase {
    /// Feeds the signal in half-second batches, like the phone does.
    func analyze(_ samples: [AccelSample]) -> [RhythmSample] {
        var analyzer = StepRhythmAnalyzer()
        var out: [RhythmSample] = []
        var i = 0
        while i < samples.count {
            let batch = Array(samples[i..<min(i + 25, samples.count)])
            out += analyzer.ingest(batch)
            i += 25
        }
        return out
    }

    func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s[s.count / 2]
    }

    func lastCadences(_ rhythm: [RhythmSample], _ n: Int = 10) -> [Double] {
        rhythm.suffix(n).compactMap(\.cadence)
    }

    func testFindsWalkingCadence() {
        var rng = SeededGenerator(seed: 1)
        let rhythm = analyze(syntheticAccel(start: t0, seconds: 12, cadence: 110, impact: 0.4, rng: &rng))
        let cadences = lastCadences(rhythm)
        XCTAssertEqual(cadences.count, 10)
        XCTAssertEqual(median(cadences), 110, accuracy: 3)
    }

    func testFindsSprintCadence() {
        var rng = SeededGenerator(seed: 2)
        let rhythm = analyze(syntheticAccel(start: t0, seconds: 12, cadence: 170, impact: 1.5, rng: &rng))
        XCTAssertEqual(median(lastCadences(rhythm)), 170, accuracy: 3)
    }

    func testDoesNotLockOntoStride() {
        var rng = SeededGenerator(seed: 3)
        let rhythm = analyze(syntheticAccel(start: t0, seconds: 12, cadence: 160, impact: 1.2, asymmetry: 0.7, rng: &rng))
        XCTAssertEqual(median(lastCadences(rhythm)), 160, accuracy: 3)
    }

    func testIntensitySeparatesSprintFromWalk() {
        var rng = SeededGenerator(seed: 4)
        let walk = analyze(syntheticAccel(start: t0, seconds: 10, cadence: 110, impact: 0.4, rng: &rng))
        let sprint = analyze(syntheticAccel(start: t0, seconds: 10, cadence: 170, impact: 1.5, rng: &rng))
        XCTAssertGreaterThan(median(sprint.map(\.intensity)), 2 * median(walk.map(\.intensity)))
    }

    func testStillPhoneHasNoCadence() {
        var rng = SeededGenerator(seed: 5)
        let rhythm = analyze(syntheticAccel(start: t0, seconds: 10, cadence: 0, impact: 0, rng: &rng))
        XCTAssertFalse(rhythm.isEmpty)
        XCTAssertTrue(rhythm.allSatisfy { $0.cadence == nil })
    }

    func testTimestampsAreWindowCentres() {
        var rng = SeededGenerator(seed: 6)
        let rhythm = analyze(syntheticAccel(start: t0, seconds: 8, cadence: 120, impact: 0.5, rng: &rng))
        let first = try! XCTUnwrap(rhythm.first)
        XCTAssertEqual(first.timestamp.timeIntervalSince(t0), 2.0, accuracy: 0.05)
        XCTAssertEqual(rhythm[1].timestamp.timeIntervalSince(first.timestamp), 0.5, accuracy: 0.03)
    }
}
