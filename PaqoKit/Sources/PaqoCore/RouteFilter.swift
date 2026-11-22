import Foundation

/// A flat east/north plane in meters around an origin. Accurate to well under a
/// meter across the few kilometres a run covers.
public struct LocalFrame: Codable, Hashable, Sendable {
    public var origin: Coordinate
    let metersPerLatitude: Double
    let metersPerLongitude: Double

    public init(origin: Coordinate) {
        self.origin = origin
        metersPerLatitude = Geo.metersPerDegreeLatitude(at: origin.latitude)
        metersPerLongitude = max(1e-6, Geo.metersPerDegreeLongitude(at: origin.latitude))
    }

    public func toLocal(_ c: Coordinate) -> (east: Double, north: Double) {
        var dLon = c.longitude - origin.longitude
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        return (dLon * metersPerLongitude, (c.latitude - origin.latitude) * metersPerLatitude)
    }

    public func toCoordinate(east: Double, north: Double) -> Coordinate {
        var lon = origin.longitude + east / metersPerLongitude
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        return Coordinate(latitude: origin.latitude + north / metersPerLatitude, longitude: lon)
    }
}

/// One input to the route filter, in the run's local frame.
public struct FilterMeasurement: Codable, Hashable, Sendable {
    public var time: Date
    public var activeTime: TimeInterval
    /// Pause-free stretch this belongs to; the filter restarts at each new line.
    public var line: Int
    public var east: Double
    public var north: Double
    public var positionSigma: Double
    public var velocityEast: Double?
    public var velocityNorth: Double?
    /// Uncertainty along the direction of travel (speed accuracy), m/s.
    public var velocitySigma: Double?
    /// Uncertainty across the direction of travel (speed × course accuracy), m/s.
    /// nil means the same as `velocitySigma`.
    public var velocityCrossSigma: Double?
    /// Feet say the runner is standing: pin velocity to zero.
    public var zeroVelocity: Bool
    /// Speed from cadence × stride, used when GPS is poor.
    public var stepSpeed: Double?
    public var stepSpeedSigma: Double?
    public var altitude: Double?

    public init(
        time: Date,
        activeTime: TimeInterval,
        line: Int,
        east: Double,
        north: Double,
        positionSigma: Double,
        velocityEast: Double?,
        velocityNorth: Double?,
        velocitySigma: Double?,
        velocityCrossSigma: Double? = nil,
        zeroVelocity: Bool,
        stepSpeed: Double?,
        stepSpeedSigma: Double?,
        altitude: Double?
    ) {
        self.time = time
        self.activeTime = activeTime
        self.line = line
        self.east = east
        self.north = north
        self.positionSigma = positionSigma
        self.velocityEast = velocityEast
        self.velocityNorth = velocityNorth
        self.velocitySigma = velocitySigma
        self.velocityCrossSigma = velocityCrossSigma
        self.zeroVelocity = zeroVelocity
        self.stepSpeed = stepSpeed
        self.stepSpeedSigma = stepSpeedSigma
        self.altitude = altitude
    }
}

public struct FilterState: Codable, Hashable, Sendable {
    public var east: Double
    public var north: Double
    public var velocityEast: Double
    public var velocityNorth: Double

    public init(east: Double, north: Double, velocityEast: Double, velocityNorth: Double) {
        self.east = east
        self.north = north
        self.velocityEast = velocityEast
        self.velocityNorth = velocityNorth
    }

    public var speed: Double { (velocityEast * velocityEast + velocityNorth * velocityNorth).squareRoot() }
}

/// Constant-velocity Kalman filter for a runner's position. Blends GPS position,
/// GPS (Doppler) velocity, "standing still" and step-based speed, each weighted by
/// how much it can be trusted right now.
public struct RouteFilter: Codable, Sendable {
    public struct Configuration: Codable, Equatable, Sendable {
        /// Random acceleration the model allows, m/s². Sprinters change speed fast.
        public var accelerationSigma: Double = 1.0
        public var minPositionSigma: Double = 3
        /// 2 degrees of freedom, 99.9 %.
        public var gateChiSquare: Double = 13.8
        /// After this many rejected fixes in a row, accept the next one anyway.
        public var maxConsecutiveRejections: Int = 3
        public var zeroVelocitySigma: Double = 0.05

        public init() {}
    }

    struct Step {
        var xPred: [Double]
        var pPred: [Double]
        var xFilt: [Double]
        var pFilt: [Double]
        var f: [Double]
        var accepted: Bool
        var startsLine: Bool
    }

    public var config: Configuration
    var x: [Double] = [0, 0, 0, 0]
    var p: [Double] = Mat.identity(4)
    var lastTime: Double?
    var line: Int?
    var rejections = 0

    public init(config: Configuration = Configuration()) {
        self.config = config
    }

    public var state: FilterState { FilterState(east: x[0], north: x[1], velocityEast: x[2], velocityNorth: x[3]) }
    public var isRunning: Bool { line != nil }

    public mutating func reset() {
        x = [0, 0, 0, 0]
        p = Mat.identity(4)
        lastTime = nil
        line = nil
        rejections = 0
    }

    @discardableResult
    public mutating func update(_ m: FilterMeasurement) -> (state: FilterState, accepted: Bool) {
        let s = step(m)
        return (state, s.accepted)
    }

    mutating func step(_ m: FilterMeasurement) -> Step {
        let t = m.time.timeIntervalSince1970
        let sigmaP = max(config.minPositionSigma, m.positionSigma)

        guard let currentLine = line, currentLine == m.line, let previous = lastTime else {
            // Start (or restart after a pause).
            let ve = m.zeroVelocity ? 0 : (m.velocityEast ?? 0)
            let vn = m.zeroVelocity ? 0 : (m.velocityNorth ?? 0)
            let sigmaV = m.zeroVelocity ? config.zeroVelocitySigma : (m.velocitySigma ?? 5)
            x = [m.east, m.north, ve, vn]
            p = Mat.diagonal([sigmaP * sigmaP, sigmaP * sigmaP, sigmaV * sigmaV, sigmaV * sigmaV])
            lastTime = t
            line = m.line
            rejections = 0
            return Step(xPred: x, pPred: p, xFilt: x, pFilt: p, f: Mat.identity(4), accepted: true, startsLine: true)
        }

        // Predict.
        let dt = max(0, t - previous)
        let f: [Double] = [
            1, 0, dt, 0,
            0, 1, 0, dt,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        let q = config.accelerationSigma * config.accelerationSigma
        let a = dt * dt * dt * dt / 4 * q, b = dt * dt * dt / 2 * q, c = dt * dt * q
        let noise: [Double] = [
            a, 0, b, 0,
            0, a, 0, b,
            b, 0, c, 0,
            0, b, 0, c,
        ]
        x = Mat.mulVec(f, x, 4)
        p = Mat.add(Mat.mul(Mat.mul(f, p, 4), Mat.transpose(f, 4), 4), noise)
        lastTime = t
        let xPred = x, pPred = p

        // Position, gated against outliers.
        var accepted = true
        let innovation = [m.east - x[0], m.north - x[1]]
        let s = [p[0] + sigmaP * sigmaP, p[1], p[4], p[5] + sigmaP * sigmaP]
        if let sInv = Mat.inverse2(s) {
            let d2 = innovation[0] * (sInv[0] * innovation[0] + sInv[1] * innovation[1])
                + innovation[1] * (sInv[2] * innovation[0] + sInv[3] * innovation[1])
            if d2 > config.gateChiSquare && rejections < config.maxConsecutiveRejections {
                accepted = false
                rejections += 1
            } else {
                rejections = 0
                apply(z: [m.east, m.north], indices: (0, 1), variance: sigmaP * sigmaP)
            }
        }

        // Velocity.
        if m.zeroVelocity {
            let v = config.zeroVelocitySigma * config.zeroVelocitySigma
            apply(z: [0, 0], indices: (2, 3), variance: v)
        } else if let ve = m.velocityEast, let vn = m.velocityNorth, let sv = m.velocitySigma {
            let cross = m.velocityCrossSigma ?? sv
            let speed = (ve * ve + vn * vn).squareRoot()
            if speed > 0.1, cross != sv {
                // Speed is known well along the path, course only blurs it sideways.
                let ue = ve / speed, un = vn / speed
                let a = sv * sv, b = cross * cross
                let r = [a * ue * ue + b * un * un, (a - b) * ue * un, (a - b) * ue * un, a * un * un + b * ue * ue]
                apply(z: [ve, vn], indices: (2, 3), covariance: r)
            } else {
                apply(z: [ve, vn], indices: (2, 3), variance: sv * sv)
            }
        } else if let speed = m.stepSpeed, let sigma = m.stepSpeedSigma {
            let current = (x[2] * x[2] + x[3] * x[3]).squareRoot()
            if current > 0.3 {
                apply(z: [speed * x[2] / current, speed * x[3] / current], indices: (2, 3), variance: sigma * sigma)
            }
        }

        return Step(xPred: xPred, pPred: pPred, xFilt: x, pFilt: p, f: f, accepted: accepted, startsLine: false)
    }

    /// Kalman update for a 2-D measurement of two state components with equal,
    /// independent noise.
    mutating func apply(z: [Double], indices: (Int, Int), variance: Double) {
        apply(z: z, indices: indices, covariance: [variance, 0, 0, variance])
    }

    /// Kalman update for a 2-D measurement with a full 2×2 noise covariance.
    mutating func apply(z: [Double], indices: (Int, Int), covariance r: [Double]) {
        let (i, j) = indices
        let s = [p[i * 4 + i] + r[0], p[i * 4 + j] + r[1], p[j * 4 + i] + r[2], p[j * 4 + j] + r[3]]
        guard let sInv = Mat.inverse2(s) else { return }
        let y = [z[0] - x[i], z[1] - x[j]]
        // K = P Hᵀ S⁻¹ (4×2); Hᵀ picks columns i and j of P.
        var k = [Double](repeating: 0, count: 8)
        for r in 0..<4 {
            let pi = p[r * 4 + i], pj = p[r * 4 + j]
            k[r * 2] = pi * sInv[0] + pj * sInv[2]
            k[r * 2 + 1] = pi * sInv[1] + pj * sInv[3]
        }
        for r in 0..<4 { x[r] += k[r * 2] * y[0] + k[r * 2 + 1] * y[1] }
        // P = (I − K H) P
        var updated = p
        for r in 0..<4 {
            for c in 0..<4 {
                updated[r * 4 + c] = p[r * 4 + c] - (k[r * 2] * p[i * 4 + c] + k[r * 2 + 1] * p[j * 4 + c])
            }
        }
        p = Mat.symmetrize(updated, 4)
    }
}

/// Rauch–Tung–Striebel smoothing: after the run, every point is estimated from the
/// fixes before *and* after it.
public enum RouteSmoother {
    public static func smooth(_ measurements: [FilterMeasurement], config: RouteFilter.Configuration) -> [FilterState] {
        guard !measurements.isEmpty else { return [] }
        var filter = RouteFilter(config: config)
        let steps = measurements.map { filter.step($0) }
        var smoothed = steps.map(\.xFilt)

        var k = steps.count - 2
        while k >= 0 {
            let next = steps[k + 1]
            if !next.startsLine, let pPredInv = Mat.inverse4(next.pPred) {
                // C = P_f[k] Fᵀ[k+1] P_pred[k+1]⁻¹
                let gain = Mat.mul(Mat.mul(steps[k].pFilt, Mat.transpose(next.f, 4), 4), pPredInv, 4)
                let diff = (0..<4).map { smoothed[k + 1][$0] - next.xPred[$0] }
                let correction = Mat.mulVec(gain, diff, 4)
                smoothed[k] = (0..<4).map { steps[k].xFilt[$0] + correction[$0] }
            }
            k -= 1
        }
        return smoothed.map { FilterState(east: $0[0], north: $0[1], velocityEast: $0[2], velocityNorth: $0[3]) }
    }
}

/// Tiny row-major matrix helpers (no dictionaries, deterministic).
enum Mat {
    static func identity(_ n: Int) -> [Double] {
        var m = [Double](repeating: 0, count: n * n)
        for i in 0..<n { m[i * n + i] = 1 }
        return m
    }

    static func diagonal(_ d: [Double]) -> [Double] {
        let n = d.count
        var m = [Double](repeating: 0, count: n * n)
        for i in 0..<n { m[i * n + i] = d[i] }
        return m
    }

    static func mul(_ a: [Double], _ b: [Double], _ n: Int) -> [Double] {
        var out = [Double](repeating: 0, count: n * n)
        for r in 0..<n {
            for c in 0..<n {
                var sum = 0.0
                for k in 0..<n { sum += a[r * n + k] * b[k * n + c] }
                out[r * n + c] = sum
            }
        }
        return out
    }

    static func mulVec(_ a: [Double], _ v: [Double], _ n: Int) -> [Double] {
        (0..<n).map { r in (0..<n).reduce(0.0) { $0 + a[r * n + $1] * v[$1] } }
    }

    static func add(_ a: [Double], _ b: [Double]) -> [Double] {
        zip(a, b).map { $0 + $1 }
    }

    static func transpose(_ a: [Double], _ n: Int) -> [Double] {
        var out = a
        for r in 0..<n { for c in 0..<n { out[c * n + r] = a[r * n + c] } }
        return out
    }

    static func symmetrize(_ a: [Double], _ n: Int) -> [Double] {
        var out = a
        for r in 0..<n {
            for c in (r + 1)..<n where c < n {
                let v = (a[r * n + c] + a[c * n + r]) / 2
                out[r * n + c] = v
                out[c * n + r] = v
            }
        }
        return out
    }

    static func inverse2(_ m: [Double]) -> [Double]? {
        let det = m[0] * m[3] - m[1] * m[2]
        guard abs(det) > 1e-12 else { return nil }
        return [m[3] / det, -m[1] / det, -m[2] / det, m[0] / det]
    }

    /// Gauss–Jordan with partial pivoting.
    static func inverse4(_ m: [Double]) -> [Double]? {
        let n = 4
        var a = m
        var inv = identity(n)
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r * n + col]) > abs(a[pivot * n + col]) { pivot = r }
            guard abs(a[pivot * n + col]) > 1e-12 else { return nil }
            if pivot != col {
                for c in 0..<n {
                    a.swapAt(col * n + c, pivot * n + c)
                    inv.swapAt(col * n + c, pivot * n + c)
                }
            }
            let d = a[col * n + col]
            for c in 0..<n {
                a[col * n + c] /= d
                inv[col * n + c] /= d
            }
            for r in 0..<n where r != col {
                let factor = a[r * n + col]
                if factor == 0 { continue }
                for c in 0..<n {
                    a[r * n + c] -= factor * a[col * n + c]
                    inv[r * n + c] -= factor * inv[col * n + c]
                }
            }
        }
        return inv
    }
}
