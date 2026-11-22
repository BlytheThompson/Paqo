#if os(iOS)
import CoreLocation
import Foundation
import PaqoCore

/// GPS for runs. Uses the fitness activity type and best accuracy, keeps running in the
/// background during a run, and converts fixes into `LocationSample`s.
///
/// All callbacks are delivered on the main thread (the manager is created there).
public final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var authorizationContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var isRecording = false

    /// Every new fix.
    public var onSample: ((LocationSample) -> Void)?
    /// Authorization changes.
    public var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    public override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    public var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    public var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Asks for "While Using the App" permission if not decided yet and waits for the answer.
    /// Main actor so the manager is only touched on the thread that created it.
    @MainActor
    public func requestAuthorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            authorizationContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Start GPS in the foreground only (e.g. to show signal strength before a run).
    public func startWarmup() {
        guard isAuthorized, !isRecording else { return }
        manager.startUpdatingLocation()
    }

    public func stopWarmup() {
        guard !isRecording else { return }
        manager.stopUpdatingLocation()
    }

    /// Start GPS for a run, continuing in the background.
    public func startRecording() {
        guard isAuthorized else { return }
        isRecording = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
    }

    public func stopRecording() {
        isRecording = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            onSample?(LocationSample(location))
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status != .notDetermined {
            let waiting = authorizationContinuations
            authorizationContinuations.removeAll()
            for continuation in waiting { continuation.resume(returning: status) }
        }
        onAuthorizationChange?(status)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (e.g. kCLErrorLocationUnknown) are expected; keep going.
    }
}

public extension LocationSample {
    init(_ location: CLLocation) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy > 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            speedAccuracy: location.speedAccuracy,
            course: location.course,
            courseAccuracy: location.courseAccuracy
        )
    }
}
#endif
