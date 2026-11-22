import Foundation

/// Run controls, recorded with the moment they happened.
public enum ControlEvent: Hashable, Sendable {
    case start(Date)
    case pause(Date)
    case resume(Date)
    case finish(Date)

    public var date: Date {
        switch self {
        case .start(let d), .pause(let d), .resume(let d), .finish(let d): return d
        }
    }

    public var name: String {
        switch self {
        case .start: return "start"
        case .pause: return "pause"
        case .resume: return "resume"
        case .finish: return "finish"
        }
    }

    public init?(name: String, date: Date) {
        switch name {
        case "start": self = .start(date)
        case "pause": self = .pause(date)
        case "resume": self = .resume(date)
        case "finish": self = .finish(date)
        default: return nil
        }
    }
}

/// Everything that reaches the run engine, in arrival order. The live app, the sensor
/// log and replay all speak this one stream, so a replayed log reproduces the run.
public enum SensorEvent: Hashable, Sendable {
    case location(LocationSample)
    case activity(MotionActivitySample)
    case pedometer(PedometerSample)
    case altitude(AltitudeSample)
    case accelerometer([AccelSample])
    case control(ControlEvent)
}
