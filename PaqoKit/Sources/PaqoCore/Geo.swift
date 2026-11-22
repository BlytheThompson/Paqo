import Foundation

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geo {
    // WGS-84 ellipsoid.
    static let semiMajorAxis = 6_378_137.0
    static let flattening = 1 / 298.257_223_563
    static let eccentricitySquared = flattening * (2 - flattening)

    /// Distance in meters between two nearby points.
    ///
    /// Uses the local radii of curvature of the WGS-84 ellipsoid at the mid latitude
    /// (meridional and prime-vertical). Between consecutive GPS fixes (meters to tens of
    /// meters apart) this is more accurate than a spherical haversine and much cheaper
    /// than Vincenty.
    public static func distance(
        _ lat1: Double, _ lon1: Double,
        _ lat2: Double, _ lon2: Double
    ) -> Double {
        let midLatitude = ((lat1 + lat2) / 2) * .pi / 180
        let sinPhi = sin(midLatitude)
        let w = 1 - eccentricitySquared * sinPhi * sinPhi
        let sqrtW = w.squareRoot()
        let primeVertical = semiMajorAxis / sqrtW
        let meridional = semiMajorAxis * (1 - eccentricitySquared) / (w * sqrtW)

        let dPhi = (lat2 - lat1) * .pi / 180
        var dLambda = (lon2 - lon1) * .pi / 180
        if dLambda > .pi { dLambda -= 2 * .pi } else if dLambda < -.pi { dLambda += 2 * .pi }

        let north = dPhi * meridional
        let east = dLambda * primeVertical * cos(midLatitude)
        return (north * north + east * east).squareRoot()
    }

    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        distance(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Meters per degree of latitude at the given latitude (meridional arc).
    public static func metersPerDegreeLatitude(at latitude: Double) -> Double {
        let phi = latitude * .pi / 180
        let s = sin(phi)
        let w = 1 - eccentricitySquared * s * s
        let meridional = semiMajorAxis * (1 - eccentricitySquared) / (w * w.squareRoot())
        return meridional * .pi / 180
    }

    /// Meters per degree of longitude at the given latitude.
    public static func metersPerDegreeLongitude(at latitude: Double) -> Double {
        let phi = latitude * .pi / 180
        let s = sin(phi)
        let w = 1 - eccentricitySquared * s * s
        let primeVertical = semiMajorAxis / w.squareRoot()
        return primeVertical * cos(phi) * .pi / 180
    }
}
