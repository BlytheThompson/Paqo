import Foundation
import XCTest
@testable import PaqoCore

final class HeatmapReplayTests: XCTestCase {
    let origin = Coordinate(latitude: 37.77, longitude: -122.42)

    func offset(east: Double, north: Double) -> Coordinate {
        LocalFrame(origin: origin).toCoordinate(east: east, north: north)
    }

    func testSimplifyStraightLineKeepsEnds() {
        let line = (0..<100).map { offset(east: 0, north: Double($0) * 3) }
        let simplified = RouteSimplifier.simplify(line, tolerance: 5)
        XCTAssertEqual(simplified, [line.first!, line.last!])
    }

    func testSimplifyKeepsCorner() {
        let up = (0..<50).map { offset(east: 0, north: Double($0) * 3) }
        let corner = offset(east: 0, north: 150)
        let across = (1...50).map { offset(east: Double($0) * 3, north: 150) }
        let simplified = RouteSimplifier.simplify(up + [corner] + across, tolerance: 5)
        XCTAssertEqual(simplified.count, 3)
        XCTAssertEqual(simplified[1], corner)
    }

    func testHeatmapCacheFollowsSaveAndDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paqo-heat-\(UUID().uuidString)")
        let store = try RunStore(directory: directory)
        let a = threeSprintRun()
        let b = threeSprintRun(start: t0.addingTimeInterval(86_400))
        try store.save(a)
        try store.save(b)
        let routes = try store.loadHeatmapRoutes()
        XCTAssertEqual(Set(routes.map(\.id)), [a.id, b.id])
        XCTAssertTrue(routes.allSatisfy { $0.pieces.contains { $0.kind == .sprint } })

        try store.delete(id: a.id)
        XCTAssertEqual(try store.loadHeatmapRoutes().map(\.id), [b.id])

        try FileManager.default.removeItem(at: directory.appendingPathComponent("heatmap.json"))
        XCTAssertEqual(try store.loadHeatmapRoutes().map(\.id), [b.id])
    }

    func testReplayStateMidSprint() {
        let timeline = ReplayTimeline(run: threeSprintRun())
        XCTAssertEqual(timeline.duration, 260)
        let state = timeline.state(at: 70)
        XCTAssertEqual(state.segmentKind, .sprint)
        XCTAssertEqual(state.segmentNumber, 1)
        XCTAssertEqual(state.segmentElapsed, 10, accuracy: 0.01)
        XCTAssertEqual(state.distance, 90 + 50, accuracy: 0.01)
        XCTAssertEqual(state.speed, 5, accuracy: 0.01)
        XCTAssertEqual(timeline.state(at: 130).segmentNumber, 2)
    }

    func testTrailEndsAtPlayhead() {
        let timeline = ReplayTimeline(run: threeSprintRun())
        let trail = timeline.trail(upTo: 70)
        XCTAssertEqual(trail.last?.points.last, timeline.state(at: 70).coordinate)
        XCTAssertEqual(trail.last?.kind, .sprint)
        XCTAssertTrue(timeline.trail(upTo: 0).isEmpty)
    }
}
