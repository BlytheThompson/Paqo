#if os(iOS)
import CoreMotion
import Foundation
import PaqoCore

/// Motion & Fitness sensors: the motion coprocessor's activity classifier, the
/// pedometer (steps and cadence) and the barometric altimeter.
///
/// All callbacks are delivered on the main thread.
public final class MotionService {
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()

    public var onActivity: ((MotionActivitySample) -> Void)?
    public var onPedometer: ((PedometerSample) -> Void)?
    public var onAltitude: ((AltitudeSample) -> Void)?

    public init() {}

    public static var isAvailable: Bool {
        CMMotionActivityManager.isActivityAvailable() || CMPedometer.isStepCountingAvailable()
    }

    public static var authorizationStatus: CMAuthorizationStatus {
        CMMotionActivityManager.authorizationStatus()
    }

    public static var isBarometerAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    /// Triggers the Motion & Fitness permission prompt (if not decided yet) by making a
    /// harmless query, and returns whether access is granted.
    public func requestAuthorization() async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        if CMMotionActivityManager.authorizationStatus() == .authorized { return true }
        let manager = activityManager
        return await withCheckedContinuation { continuation in
            let now = Date()
            manager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in
                continuation.resume(returning: CMMotionActivityManager.authorizationStatus() == .authorized)
            }
        }
    }

    public func start(from startDate: Date) {
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self, let activity else { return }
                self.onActivity?(MotionActivitySample(activity))
            }
        }

        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: startDate) { [weak self] data, _ in
                guard let data else { return }
                let sample = PedometerSample(
                    timestamp: data.endDate,
                    steps: data.numberOfSteps.intValue,
                    cadence: data.currentCadence.map { $0.doubleValue * 60 },
                    distance: data.distance?.doubleValue
                )
                DispatchQueue.main.async {
                    self?.onPedometer?(sample)
                }
            }
        }

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.onAltitude?(AltitudeSample(timestamp: Date(), relativeAltitude: data.relativeAltitude.doubleValue))
            }
        }
    }

    public func stop() {
        activityManager.stopActivityUpdates()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
    }
}

public extension MotionActivitySample {
    init(_ activity: CMMotionActivity) {
        let kind: MotionActivityKind
        if activity.running {
            kind = .running
        } else if activity.walking {
            kind = .walking
        } else if activity.cycling {
            kind = .cycling
        } else if activity.automotive {
            kind = .automotive
        } else if activity.stationary {
            kind = .stationary
        } else {
            kind = .unknown
        }
        let confidence: MotionConfidence
        switch activity.confidence {
        case .high: confidence = .high
        case .medium: confidence = .medium
        default: confidence = .low
        }
        // CMMotionActivity.startDate can lag well behind; use arrival time so the
        // classifier treats it as current evidence.
        self.init(timestamp: Date(), kind: kind, confidence: confidence)
    }
}
#endif
