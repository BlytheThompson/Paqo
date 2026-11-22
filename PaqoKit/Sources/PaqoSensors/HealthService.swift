#if os(iOS)
import CoreLocation
import Foundation
import HealthKit
import PaqoCore

public enum HealthServiceError: Error {
    case unavailable
    case notAuthorized
    case failed
}

/// Saves finished runs to Apple Health as running workouts with their route.
///
/// Every call fails gracefully: a sideloaded build may not carry the HealthKit
/// entitlement, in which case HealthKit returns errors instead of crashing.
public final class HealthService {
    private let store = HKHealthStore()

    public init() {}

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var shareTypes: Set<HKSampleType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning),
        ]
    }

    /// True once the user has allowed Paqo to save workouts.
    public var canSaveWorkouts: Bool {
        Self.isAvailable && store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    public func requestAuthorization() async throws {
        guard Self.isAvailable else { throw HealthServiceError.unavailable }
        let store = self.store
        let types = shareTypes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: types, read: nil) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Saves the run as a workout (distance samples per segment, pause events, elevation
    /// metadata) and attaches its GPS route.
    public func save(_ run: Run) async throws {
        guard Self.isAvailable else { throw HealthServiceError.unavailable }
        if !canSaveWorkouts {
            try await requestAuthorization()
            guard canSaveWorkouts else { throw HealthServiceError.notAuthorized }
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())

        try await perform { builder.beginCollection(withStart: run.startDate, completion: $0) }

        let distanceType = HKQuantityType(.distanceWalkingRunning)
        var samples: [HKSample] = []
        for segment in run.segments where segment.distance > 0 {
            let start = run.date(atActiveTime: segment.startTime)
            let end = run.date(atActiveTime: segment.endTime)
            guard end > start else { continue }
            samples.append(HKQuantitySample(
                type: distanceType,
                quantity: HKQuantity(unit: .meter(), doubleValue: segment.distance),
                start: start,
                end: end
            ))
        }
        if samples.isEmpty, run.distance > 0, run.endDate > run.startDate {
            samples.append(HKQuantitySample(
                type: distanceType,
                quantity: HKQuantity(unit: .meter(), doubleValue: run.distance),
                start: run.startDate,
                end: run.endDate
            ))
        }
        if !samples.isEmpty {
            try await perform { builder.add(samples, completion: $0) }
        }

        var events: [HKWorkoutEvent] = []
        for pause in run.pauses {
            events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pause.start, duration: 0), metadata: nil))
            if let end = pause.end {
                events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: end, duration: 0), metadata: nil))
            }
        }
        if !events.isEmpty {
            try await perform { builder.addWorkoutEvents(events, completion: $0) }
        }

        let metadata: [String: Any] = [
            HKMetadataKeyIndoorWorkout: false,
            HKMetadataKeyElevationAscended: HKQuantity(unit: .meter(), doubleValue: run.elevationGain),
        ]
        try await perform { builder.addMetadata(metadata, completion: $0) }

        try await perform { builder.endCollection(withEnd: run.endDate, completion: $0) }

        let workout: HKWorkout? = try await withCheckedThrowingContinuation { continuation in
            builder.finishWorkout { workout, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: workout)
                }
            }
        }

        guard let workout, run.track.count > 1 else { return }
        try await saveRoute(for: run, workout: workout)
    }

    private func saveRoute(for run: Run, workout: HKWorkout) async throws {
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        let locations: [CLLocation] = run.track.map { point in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                altitude: (point.altitude ?? 0) + run.altitudeOffset,
                horizontalAccuracy: 5,
                verticalAccuracy: point.altitude == nil ? -1 : 3,
                course: -1,
                speed: point.speed,
                timestamp: point.timestamp
            )
        }
        var index = 0
        while index < locations.count {
            let chunk = Array(locations[index..<min(index + 500, locations.count)])
            try await perform { routeBuilder.insertRouteData(chunk, completion: $0) }
            index += 500
        }
        let _: HKWorkoutRoute? = try await withCheckedThrowingContinuation { continuation in
            routeBuilder.finishRoute(with: workout, metadata: nil) { route, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: route)
                }
            }
        }
    }

    /// Bridges HealthKit's (Bool, Error?) completion handlers to async/await.
    private func perform(_ body: @escaping (@escaping (Bool, Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            body { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if !success {
                    continuation.resume(throwing: HealthServiceError.failed)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
#endif
