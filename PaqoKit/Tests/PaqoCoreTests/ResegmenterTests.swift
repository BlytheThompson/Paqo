import Foundation
import XCTest
@testable import PaqoCore

final class ResegmenterTests: XCTestCase {
    let sprintLike = EvidenceSample(second: 0, motion: 1.5, cadence: 170, intensity: 1.0)
    let walkLike = EvidenceSample(second: 0, motion: -1.5, cadence: 110, intensity: 0.3)

    func at(_ second: Int, _ e: EvidenceSample) -> EvidenceSample {
        var copy = e
        copy.second = second
        return copy
    }

    func testViterbiFindsBoundaries() {
        var evidence: [EvidenceSample] = []
        var speeds: [Double?] = []
        for s in 0..<120 {
            var sprint = s < 60
            if s == 30 || s == 31 { sprint = false } // Two noisy seconds mid-sprint.
            evidence.append(at(s, sprint ? sprintLike : walkLike))
            speeds.append(s < 60 ? 4 : 1.4)
        }
        let labels = Resegmenter.labels(evidence: evidence, speeds: speeds, classifier: .init(), config: .init())
        XCTAssertEqual(labels.count, 120)
        XCTAssertEqual(Array(labels[0..<60]), Array(repeating: .sprint, count: 60))
        XCTAssertEqual(Array(labels[60..<120]), Array(repeating: .walk, count: 60))
    }

    func testMissingSecondsCarryForward() {
        // Evidence only every 10 s, and some components missing.
        let evidence = [
            EvidenceSample(second: 0, motion: -1.5, cadence: nil, intensity: nil),
            EvidenceSample(second: 10, motion: nil, cadence: 170, intensity: 1.2),
            EvidenceSample(second: 20, motion: 1.5, cadence: nil, intensity: nil),
        ]
        let speeds: [Double?] = Array(repeating: nil, count: 40)
        let labels = Resegmenter.labels(evidence: evidence, speeds: speeds, classifier: .init(), config: .init())
        XCTAssertEqual(labels.count, 40)
        XCTAssertEqual(labels.first, .walk)
        XCTAssertEqual(labels.last, .sprint)
    }

    func testSegmentsFromLabelsHaveTrackDistances() {
        let track = straightTrack(segments: [(30, 4), (30, 1.5)])
        let labels = Array(repeating: SegmentKind.sprint, count: 30) + Array(repeating: SegmentKind.walk, count: 30)
        let segments = Resegmenter.segments(labels: labels, movingTime: 60, track: track)
        XCTAssertEqual(segments.map(\.kind), [.sprint, .walk])
        XCTAssertEqual(segments[0].startTime, 0)
        XCTAssertEqual(segments[0].endTime, 30)
        XCTAssertEqual(segments[1].endTime, 60)
        XCTAssertEqual(segments[0].distance, 120, accuracy: 0.5)
        XCTAssertEqual(segments[1].distance, 45, accuracy: 0.5)
    }

    func testRhythmReplacesPedometerCadence() {
        var classifier = SegmentClassifier()
        classifier.update(cadence: 110, at: t0)
        classifier.update(rhythm: RhythmSample(timestamp: t0, cadence: 170, periodicity: 0.8, intensity: 1.0))
        XCTAssertGreaterThan(classifier.score(speed: nil, at: t0.addingTimeInterval(1)), 0)
        let parts = classifier.components(at: t0.addingTimeInterval(1))
        XCTAssertEqual(parts.cadence, 170)
        XCTAssertEqual(parts.intensity, 1.0)
    }
}
