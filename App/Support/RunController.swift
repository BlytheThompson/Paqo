import CoreLocation
import Foundation
import Observation
import PaqoCore
import PaqoSensors
import UIKit

/// Runs a recording session: permissions, countdown, sensors → engine, live updates,
/// Live Activity, autosave, finishing, Apple Health.
@MainActor
@Observable
final class RunController {
    enum Phase: Equatable {
        case idle
        case preparing
        case countdown(Int)
        case recording
        case finished
    }

    enum HealthStatus: Equatable {
        case idle
        case off
        case saving
        case saved
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var snapshot: LiveSnapshot?
    private(set) var routePieces: [RoutePiece] = []
    private(set) var finishedRun: Run?
    /// A run rescued from an autosave after the app was closed mid-run.
    var recoveredRun: Run?
    private(set) var gpsAccuracy: Double?
    private(set) var permissionProblem: String?
    private(set) var healthStatus: HealthStatus = .idle

    @ObservationIgnored private let library: RunLibrary
    @ObservationIgnored private let location = LocationService()
    @ObservationIgnored private let motion = MotionService()
    @ObservationIgnored private let health = HealthService()
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private var engine: RunEngine?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastAutosave = Date.distantPast
    @ObservationIgnored private var lastTrackCount = 0

    init(library: RunLibrary) {
        self.library = library
        location.onSample = { [weak self] sample in
            self?.handle(sample)
        }
        motion.onActivity = { [weak self] sample in
            self?.engine?.ingest(sample)
        }
        motion.onPedometer = { [weak self] sample in
            self?.engine?.ingest(sample)
        }
        motion.onAltitude = { [weak self] sample in
            self?.engine?.ingest(sample)
        }
        RunIntentBridge.shared.toggleHandler = { [weak self] in
            self?.togglePause()
        }
        liveActivity.endStaleActivities()
        recoverUnfinishedRun()
    }

    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { snapshot?.state == .paused }
    var isLiveScreenPresented: Bool {
        switch phase {
        case .countdown, .recording, .finished: return true
        case .idle, .preparing: return false
        }
    }

    // MARK: - GPS warm-up on the start screen

    func warmUpGPS() {
        location.startWarmup()
    }

    func coolDownGPS() {
        guard phase == .idle else { return }
        location.stopWarmup()
    }

    // MARK: - Start

    func startTapped() {
        guard phase == .idle else { return }
        finishedRun = nil
        healthStatus = .idle
        phase = .preparing
        Task { await prepareAndCountDown() }
    }

    func cancelCountdown() {
        guard case .countdown = phase else { return }
        phase = .idle
        location.stopRecording()
        location.startWarmup()
    }

    private func prepareAndCountDown() async {
        let status = await location.requestAuthorization()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            permissionProblem = "Paqo needs location access to map your run. Turn it on in Settings › Paqo › Location."
            phase = .idle
            return
        }
        permissionProblem = nil
        _ = await motion.requestAuthorization() // Optional: runs still work without it.
        if UserDefaults.standard.saveToHealth, HealthService.isAvailable, !health.canSaveWorkouts {
            try? await health.requestAuthorization()
        }

        location.startRecording() // GPS settles during the countdown.
        for n in [3, 2, 1] {
            phase = .countdown(n)
            haptic(.light)
            try? await Task.sleep(for: .seconds(1))
            guard phase == .countdown(n) else { return } // Cancelled.
        }
        beginRecording()
    }

    private func beginRecording() {
        let now = Date()
        var engine = RunEngine()
        engine.start(at: now)
        self.engine = engine
        lastTrackCount = 0
        routePieces = []
        motion.start(from: now)
        phase = .recording
        notify(.success)
        refresh()
        liveActivity.start(startDate: now, state: activityState())
        startTicker()
        autosave(force: true)
    }

    // MARK: - During the run

    func togglePause() {
        guard phase == .recording, var engine else { return }
        let now = Date()
        switch engine.state {
        case .running: engine.pause(at: now)
        case .paused: engine.resume(at: now)
        case .idle, .finished: return
        }
        self.engine = engine
        haptic(.medium)
        refresh()
        liveActivity.update(state: activityState(), force: true)
        autosave(force: true)
    }

    private func handle(_ sample: LocationSample) {
        gpsAccuracy = sample.horizontalAccuracy >= 0 ? sample.horizontalAccuracy : nil
        guard engine != nil else { return }
        engine?.ingest(sample)
        let count = engine?.track.count ?? 0
        if count != lastTrackCount {
            lastTrackCount = count
            rebuildRoute()
        }
        autosave(force: false)
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard phase == .recording else { return }
        refresh()
        liveActivity.update(state: activityState(), force: false)
    }

    private func refresh() {
        snapshot = engine?.snapshot(at: Date())
    }

    private func rebuildRoute() {
        guard let engine else { return }
        routePieces = RouteBuilder.pieces(track: engine.track, segments: engine.segments)
    }

    // MARK: - Finish

    func finish() {
        guard phase == .recording, var engine else { return }
        let run = engine.finish(at: Date())
        stopSensors()
        self.engine = nil
        liveActivity.end(state: activityState(for: run))
        library.save(run)
        library.store?.clearInProgress()
        routePieces = RouteBuilder.pieces(track: run.track, segments: run.segments)
        finishedRun = run
        phase = .finished
        notify(.success)
        saveToHealthIfEnabled(run)
    }

    func discard() {
        guard phase == .recording else { return }
        stopSensors()
        engine = nil
        liveActivity.end(state: nil)
        library.store?.clearInProgress()
        routePieces = []
        snapshot = nil
        phase = .idle
        haptic(.medium)
    }

    func dismissSummary() {
        phase = .idle
        finishedRun = nil
        routePieces = []
        snapshot = nil
        location.startWarmup()
    }

    private func stopSensors() {
        tickTask?.cancel()
        tickTask = nil
        location.stopRecording()
        motion.stop()
    }

    // MARK: - Apple Health

    private func saveToHealthIfEnabled(_ run: Run) {
        guard UserDefaults.standard.saveToHealth else {
            healthStatus = .off
            return
        }
        Task { await saveToHealth(run) }
    }

    /// Saves a run to Apple Health and marks it saved. Also used from past runs' summaries.
    @discardableResult
    func saveToHealth(_ run: Run) async -> Bool {
        guard HealthService.isAvailable else {
            healthStatus = .failed("Apple Health isn't available on this device.")
            return false
        }
        healthStatus = .saving
        do {
            try await health.save(run)
            var saved = run
            saved.savedToHealth = true
            library.save(saved)
            if finishedRun?.id == run.id { finishedRun = saved }
            healthStatus = .saved
            return true
        } catch {
            healthStatus = .failed("Couldn't save to Apple Health. Check Settings › Health › Data Access › Paqo.")
            return false
        }
    }

    // MARK: - Autosave & recovery

    private func autosave(force: Bool) {
        guard let engine, let store = library.store else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastAutosave) >= 15 else { return }
        lastAutosave = now
        try? store.saveInProgress(engine)
    }

    private func recoverUnfinishedRun() {
        guard let store = library.store, var engine = store.loadInProgress() else { return }
        store.clearInProgress()
        guard engine.state == .running || engine.state == .paused, engine.track.count > 1 else { return }
        let run = engine.finish(at: engine.lastActivityDate ?? Date())
        library.save(run)
        recoveredRun = run
    }

    // MARK: - Live Activity state

    private func activityState() -> RunActivityAttributes.ContentState {
        let unit = UserDefaults.standard.distanceUnit
        let s = snapshot ?? engine?.snapshot(at: Date())
        let moving = s?.movingTime ?? 0
        let segment: String
        if let kind = s?.segmentKind {
            segment = "\(kind.displayName) \(s?.segmentNumber ?? 1)"
        } else {
            segment = "Starting"
        }
        return RunActivityAttributes.ContentState(
            isPaused: s?.state == .paused,
            timerStart: Date().addingTimeInterval(-moving),
            movingText: Format.duration(moving),
            distance: Format.distance(s?.distance ?? 0, unit: unit),
            unit: unit.abbreviation,
            pace: Format.pace(secondsPerMeter: s?.currentPace ?? s?.averagePace, unit: unit),
            paceUnit: unit.paceSuffix,
            segment: segment,
            isSprinting: s?.segmentKind == .sprint
        )
    }

    private func activityState(for run: Run) -> RunActivityAttributes.ContentState {
        let unit = UserDefaults.standard.distanceUnit
        return RunActivityAttributes.ContentState(
            isPaused: true,
            timerStart: Date().addingTimeInterval(-run.movingTime),
            movingText: Format.duration(run.movingTime),
            distance: Format.distance(run.distance, unit: unit),
            unit: unit.abbreviation,
            pace: Format.pace(secondsPerMeter: run.averagePace, unit: unit),
            paceUnit: unit.paceSuffix,
            segment: "Finished",
            isSprinting: false
        )
    }

    // MARK: - Haptics

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
