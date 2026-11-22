import Foundation

/// Where a session writes its sensor log.
public protocol SensorLogSink: AnyObject {
    func write(_ event: SensorEvent, seq: Int)
    func flush()
}

/// A sensor log kept in memory (file name → text). Used by tests and the replay tool.
public final class MemoryLogSink: SensorLogSink {
    public private(set) var files: [String: String] = [:]

    public init(meta: SensorLogMeta) {
        for name in SensorLogCodec.fileNames {
            files[name] = SensorLogCodec.header(for: name) + "\n"
        }
        files["meta.json"] = (try? SensorLogCodec.encodeMeta(meta)) ?? ""
    }

    public func write(_ event: SensorEvent, seq: Int) {
        for row in SensorLogCodec.rows(for: event, seq: seq) {
            files[row.file, default: ""] += row.line + "\n"
        }
    }

    public func flush() {}
}

/// Records a run: every event is normalised to exactly what the log will hold,
/// written to the log, then applied to the engine. Replaying the log therefore
/// reproduces the run.
public final class SessionRecorder {
    public private(set) var engine: RunEngine
    let sink: SensorLogSink?
    var seq = 0

    public init(engine: RunEngine, sink: SensorLogSink?) {
        self.engine = engine
        self.sink = sink
    }

    public func record(_ event: SensorEvent) {
        let normalized = SensorLogCodec.normalize(event)
        sink?.write(normalized, seq: seq)
        seq += 1
        engine.apply(normalized)
    }

    public func finish(at date: Date, name: String? = nil, calendar: Calendar = .current) -> Run {
        let normalized = SensorLogCodec.normalize(.control(.finish(date)))
        sink?.write(normalized, seq: seq)
        seq += 1
        sink?.flush()
        var end = date
        if case .control(let control) = normalized { end = control.date }
        return engine.finish(at: end, name: name, calendar: calendar)
    }
}

/// Runs a sensor log back through the engine.
public enum SessionReplayer {
    public static func replay(
        _ log: SensorLog,
        config: RunEngine.Configuration,
        name: String? = nil,
        calendar: Calendar = .current
    ) -> Run {
        var engine = RunEngine(id: log.meta.runID, config: config)
        var finishDate: Date?
        for event in log.events {
            if case .control(.finish(let date)) = event {
                finishDate = date
                break
            }
            engine.apply(event)
        }
        // A log without a finish (the app was killed) closes like a recovered run.
        let end = finishDate ?? engine.lastActivityDate ?? log.meta.startDate
        return engine.finish(at: end, name: name, calendar: calendar)
    }
}

/// Re-runs a saved run through the current detection and filtering using its
/// sensor log, keeping who it is (id, name, Health status).
public enum Reprocessor {
    public static func reprocess(_ run: Run, log: SensorLog, config: RunEngine.Configuration = .init()) -> Run {
        var redone = SessionReplayer.replay(log, config: config, name: run.name)
        redone.id = run.id
        redone.name = run.name
        redone.savedToHealth = run.savedToHealth
        return redone
    }
}
