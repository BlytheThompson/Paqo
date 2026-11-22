#if os(iOS)
import CoreMotion
import Foundation
import PaqoCore

/// The accelerometer at 50 Hz, delivered on the main thread in half-second batches.
/// Feeds the step-rhythm analysis (cadence and impact intensity) for sprint detection.
/// Keeps running in the background during a run because background location keeps
/// the app alive.
public final class AccelerometerService {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Paqo accelerometer"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    /// Only touched on `queue`.
    private var buffer: [AccelSample] = []

    public var onBatch: (([AccelSample]) -> Void)?
    public var rate: Double = 50
    public var batchSize = 25

    public init() {}

    public var isAvailable: Bool { manager.isAccelerometerAvailable }

    public func start() {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        // Accelerometer timestamps count from boot; convert them to wall-clock time.
        let bootEpoch = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        let size = batchSize
        manager.accelerometerUpdateInterval = 1 / rate
        queue.addOperation { [weak self] in self?.buffer = [] }
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.buffer.append(AccelSample(
                timestamp: Date(timeIntervalSince1970: bootEpoch + data.timestamp),
                x: data.acceleration.x,
                y: data.acceleration.y,
                z: data.acceleration.z
            ))
            guard self.buffer.count >= size else { return }
            let batch = self.buffer
            self.buffer = []
            DispatchQueue.main.async { [weak self] in
                self?.onBatch?(batch)
            }
        }
    }

    public func stop() {
        manager.stopAccelerometerUpdates()
        queue.addOperation { [weak self] in self?.buffer = [] }
    }
}
#endif
