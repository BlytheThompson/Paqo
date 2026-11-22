import Foundation

/// Douglas–Peucker line simplification in local meters.
public enum RouteSimplifier {
    public static func simplify(_ points: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard points.count > 2, let origin = points.first else { return points }
        let frame = LocalFrame(origin: origin)
        let local = points.map { frame.toLocal($0) }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first
            var farthestDistance = 0.0
            for i in (first + 1)..<last {
                let d = distanceToSegment(local[i], local[first], local[last])
                if d > farthestDistance {
                    farthestDistance = d
                    farthest = i
                }
            }
            if farthestDistance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    static func distanceToSegment(
        _ p: (east: Double, north: Double),
        _ a: (east: Double, north: Double),
        _ b: (east: Double, north: Double)
    ) -> Double {
        let dx = b.east - a.east, dy = b.north - a.north
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.east - a.east, p.north - a.north) }
        let t = max(0, min(1, ((p.east - a.east) * dx + (p.north - a.north) * dy) / lengthSquared))
        return hypot(p.east - (a.east + t * dx), p.north - (a.north + t * dy))
    }
}

public struct HeatmapPiece: Codable, Hashable, Sendable {
    public var kind: SegmentKind?
    public var points: [Coordinate]

    public init(kind: SegmentKind?, points: [Coordinate]) {
        self.kind = kind
        self.points = points
    }
}

/// A run's route, simplified for drawing many runs at once.
public struct HeatmapRoute: Codable, Hashable, Sendable, Identifiable {
    /// The run's id.
    public var id: UUID
    public var startDate: Date
    public var pieces: [HeatmapPiece]

    public init(id: UUID, startDate: Date, pieces: [HeatmapPiece]) {
        self.id = id
        self.startDate = startDate
        self.pieces = pieces
    }
}

public enum HeatmapBuilder {
    public static func route(for run: Run, tolerance: Double = 5) -> HeatmapRoute {
        let pieces = RouteBuilder.pieces(track: run.track, segments: run.segments).map { piece in
            HeatmapPiece(kind: piece.kind, points: RouteSimplifier.simplify(piece.points, tolerance: tolerance))
        }
        return HeatmapRoute(id: run.id, startDate: run.startDate, pieces: pieces)
    }
}
