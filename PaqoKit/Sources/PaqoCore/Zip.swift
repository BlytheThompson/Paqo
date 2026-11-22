import Foundation

/// CRC-32 (IEEE 802.3), as used by zip.
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

public enum ZipError: Error, Equatable {
    case notAZip
    case compressed(path: String)
    case corrupt
}

public struct ZipEntry: Equatable, Sendable {
    public var path: String
    public var data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

/// Writes a zip archive with stored (uncompressed) entries, streaming to disk.
/// Stored zips open everywhere: the iPhone Files app, Windows Explorer, macOS.
public final class ZipWriter {
    private let handle: FileHandle
    private var offset: UInt32 = 0
    private var central = Data()
    private var count: UInt16 = 0
    private var finished = false

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    deinit {
        if !finished { try? handle.close() }
    }

    public func add(path: String, data: Data, modified: Date) throws {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let (time, date) = Self.dosDateTime(modified)
        let size = UInt32(data.count)

        var local = Data()
        local.appendLE(UInt32(0x0403_4B50))
        local.appendLE(UInt16(20))        // version needed
        local.appendLE(UInt16(0x0800))    // UTF-8 names
        local.appendLE(UInt16(0))         // stored
        local.appendLE(time)
        local.appendLE(date)
        local.appendLE(crc)
        local.appendLE(size)
        local.appendLE(size)
        local.appendLE(UInt16(name.count))
        local.appendLE(UInt16(0))
        local.append(name)

        var record = Data()
        record.appendLE(UInt32(0x0201_4B50))
        record.appendLE(UInt16(20))       // version made by
        record.appendLE(UInt16(20))       // version needed
        record.appendLE(UInt16(0x0800))
        record.appendLE(UInt16(0))
        record.appendLE(time)
        record.appendLE(date)
        record.appendLE(crc)
        record.appendLE(size)
        record.appendLE(size)
        record.appendLE(UInt16(name.count))
        record.appendLE(UInt16(0))        // extra
        record.appendLE(UInt16(0))        // comment
        record.appendLE(UInt16(0))        // disk
        record.appendLE(UInt16(0))        // internal attributes
        record.appendLE(UInt32(0))        // external attributes
        record.appendLE(offset)
        record.append(name)

        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)
        offset += UInt32(local.count) + size
        central.append(record)
        count += 1
    }

    public func finish() throws {
        guard !finished else { return }
        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(count)
        end.appendLE(count)
        end.appendLE(UInt32(central.count))
        end.appendLE(offset)
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
        finished = true
    }

    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

/// Reads zip archives whose entries are stored (uncompressed), such as the ones
/// `ZipWriter` produces.
public enum ZipReader {
    public static func entries(of data: Data) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.notAZip }

        // End of central directory: search backwards (a comment may follow it).
        var eocd: Int?
        let lowest = max(0, bytes.count - 22 - 65_535)
        var i = bytes.count - 22
        while i >= lowest {
            if u32(bytes, i) == 0x0605_4B50 {
                eocd = i
                break
            }
            i -= 1
        }
        guard let end = eocd else { throw ZipError.notAZip }

        let total = Int(u16(bytes, end + 10))
        var cursor = Int(u32(bytes, end + 16))
        var result: [ZipEntry] = []
        for _ in 0..<total {
            guard cursor + 46 <= bytes.count, u32(bytes, cursor) == 0x0201_4B50 else { throw ZipError.corrupt }
            let method = u16(bytes, cursor + 10)
            let crc = u32(bytes, cursor + 16)
            let size = Int(u32(bytes, cursor + 20))
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let localOffset = Int(u32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw ZipError.corrupt }
            let path = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            guard method == 0 else { throw ZipError.compressed(path: path) }
            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4B50 else { throw ZipError.corrupt }
            let start = localOffset + 30 + Int(u16(bytes, localOffset + 26)) + Int(u16(bytes, localOffset + 28))
            guard start + size <= bytes.count else { throw ZipError.corrupt }
            let content = Data(bytes[start..<(start + size)])
            guard CRC32.checksum(content) == crc else { throw ZipError.corrupt }
            if path.hasSuffix("/") { continue } // Directory entry.
            result.append(ZipEntry(path: path, data: content))
        }
        return result
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
