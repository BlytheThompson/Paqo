import Foundation

/// Appends a run's sensor log to disk as it is recorded: `meta.json` plus one CSV per
/// sensor. Rows are buffered and flushed every couple of seconds (or 64 KB), so a
/// crash loses at most the last moments.
public final class SensorLogWriter: SensorLogSink {
    public let directory: URL
    private var handles: [String: FileHandle] = [:]
    private var buffers: [String: String] = [:]
    private var bufferedBytes = 0
    private var lastFlush: Date?
    private var closed = false
    public var flushInterval: TimeInterval = 2
    public var flushBytes = 64 * 1024

    public init(directory: URL, meta: SensorLogMeta) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(SensorLogCodec.encodeMeta(meta).utf8).write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
        for name in SensorLogCodec.fileNames {
            let url = directory.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data((SensorLogCodec.header(for: name) + "\n").utf8))
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            handles[name] = handle
        }
    }

    deinit {
        close()
    }

    public func write(_ event: SensorEvent, seq: Int) {
        guard !closed else { return }
        for row in SensorLogCodec.rows(for: event, seq: seq) {
            buffers[row.file, default: ""] += row.line + "\n"
            bufferedBytes += row.line.utf8.count + 1
        }
        let time = Self.time(of: event)
        if lastFlush == nil { lastFlush = time }
        if bufferedBytes >= flushBytes || time.timeIntervalSince(lastFlush ?? time) >= flushInterval {
            flush()
            lastFlush = time
        }
    }

    public func flush() {
        for name in SensorLogCodec.fileNames {
            guard let text = buffers[name], !text.isEmpty, let handle = handles[name] else { continue }
            try? handle.write(contentsOf: Data(text.utf8))
            buffers[name] = ""
        }
        bufferedBytes = 0
    }

    public func close() {
        guard !closed else { return }
        flush()
        for handle in handles.values { try? handle.close() }
        handles = [:]
        closed = true
    }

    static func time(of event: SensorEvent) -> Date {
        switch event {
        case .location(let s): return s.timestamp
        case .activity(let s): return s.timestamp
        case .pedometer(let s): return s.timestamp
        case .altitude(let s): return s.timestamp
        case .accelerometer(let batch): return batch.last?.timestamp ?? .distantPast
        case .control(let c): return c.date
        }
    }
}

/// Sensor logs on disk, one folder per run: `<directory>/<run-id>/`.
public final class SensorLogStore {
    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func folder(_ runID: UUID) -> URL {
        directory.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    public func makeWriter(meta: SensorLogMeta) throws -> SensorLogWriter {
        try SensorLogWriter(directory: folder(meta.runID), meta: meta)
    }

    public func hasLog(for runID: UUID) -> Bool {
        fm.fileExists(atPath: folder(runID).appendingPathComponent("meta.json").path)
    }

    public func files(runID: UUID) throws -> [String: String] {
        var files: [String: String] = [:]
        for name in ["meta.json"] + SensorLogCodec.fileNames {
            let url = folder(runID).appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                files[name] = String(decoding: data, as: UTF8.self)
            }
        }
        return files
    }

    /// Just the log's description (reads only meta.json).
    public func meta(runID: UUID) -> SensorLogMeta? {
        guard let data = try? Data(contentsOf: folder(runID).appendingPathComponent("meta.json")) else { return nil }
        return try? SensorLogCodec.decode(files: ["meta.json": String(decoding: data, as: UTF8.self)]).meta
    }

    public func load(runID: UUID) throws -> SensorLog {
        try SensorLogCodec.decode(files: files(runID: runID))
    }

    public func runIDs() -> [UUID] {
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { UUID(uuidString: $0.lastPathComponent) }.sorted { $0.uuidString < $1.uuidString }
    }

    public func delete(runID: UUID) {
        try? fm.removeItem(at: folder(runID))
    }

    public func deleteAll() {
        for id in runIDs() { delete(runID: id) }
    }

    /// Keeps the `keep` newest logs (by start date) plus `protecting`.
    public func prune(keep: Int, protecting: UUID?) {
        let dated: [(id: UUID, start: Date)] = runIDs().map { id in
            (id, meta(runID: id)?.startDate ?? .distantPast)
        }
        let newestFirst = dated.sorted { $0.start != $1.start ? $0.start > $1.start : $0.id.uuidString < $1.id.uuidString }
        for (index, entry) in newestFirst.enumerated() where index >= keep && entry.id != protecting {
            delete(runID: entry.id)
        }
    }

    public func totalBytes() -> Int64 {
        var total: Int64 = 0
        for id in runIDs() {
            let items = (try? fm.contentsOfDirectory(at: folder(id), includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for item in items {
                total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Zips one log as `paqo-sensor-log-<id>/…`, ready to share.
    public func archive(runID: UUID, to url: URL) throws {
        let files = try files(runID: runID)
        let prefix = "paqo-sensor-log-\(runID.uuidString.prefix(8).lowercased())/"
        let writer = try ZipWriter(url: url)
        for name in ["meta.json"] + SensorLogCodec.fileNames {
            guard let text = files[name] else { continue }
            try writer.add(path: prefix + name, data: Data(text.utf8), modified: Date())
        }
        try writer.finish()
    }
}
