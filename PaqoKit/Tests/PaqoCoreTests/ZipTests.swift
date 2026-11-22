import Foundation
import XCTest
@testable import PaqoCore

final class ZipTests: XCTestCase {
    func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("paqo-tests-\(UUID().uuidString)-\(name)")
    }

    func testCRC32CheckValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testRoundTripPreservesPathsAndBytes() throws {
        let url = tempURL("round.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let files: [(String, Data)] = [
            ("README.txt", Data("Hello\r\n".utf8)),
            ("runs/a.json", Data("{\"name\": \"Café run\"}".utf8)),
            ("runs/ü-emoji-🏃.gpx", Data("<gpx>🏃</gpx>".utf8)),
        ]
        let writer = try ZipWriter(url: url)
        for (path, data) in files {
            try writer.add(path: path, data: data, modified: t0)
        }
        try writer.finish()

        let entries = try ZipReader.entries(of: Data(contentsOf: url))
        XCTAssertEqual(entries.map(\.path), files.map(\.0))
        XCTAssertEqual(entries.map(\.data), files.map(\.1))
    }

    func testRejectsCompressedEntries() throws {
        // A minimal archive whose single entry claims deflate (method 8).
        var data = Data()
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let name = Data("x.txt".utf8)
        let payload = Data([0x03, 0x00])
        le32(0x0403_4B50); le16(20); le16(0); le16(8); le16(0); le16(0)
        le32(0); le32(UInt32(payload.count)); le32(1); le16(UInt16(name.count)); le16(0)
        data.append(name); data.append(payload)
        let central = UInt32(data.count)
        le32(0x0201_4B50); le16(20); le16(20); le16(0); le16(8); le16(0); le16(0)
        le32(0); le32(UInt32(payload.count)); le32(1); le16(UInt16(name.count)); le16(0); le16(0)
        le16(0); le16(0); le32(0); le32(0)
        data.append(name)
        let centralSize = UInt32(data.count) - central
        le32(0x0605_4B50); le16(0); le16(0); le16(1); le16(1); le32(centralSize); le32(central); le16(0)

        XCTAssertThrowsError(try ZipReader.entries(of: data)) { error in
            XCTAssertEqual(error as? ZipError, .compressed(path: "x.txt"))
        }
    }

    func testRejectsNonZip() {
        XCTAssertThrowsError(try ZipReader.entries(of: Data("hello".utf8))) { error in
            XCTAssertEqual(error as? ZipError, .notAZip)
        }
    }

    func testWritesZipForManualCheck() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paqo-zip-check.zip")
        try? FileManager.default.removeItem(at: url)
        let writer = try ZipWriter(url: url)
        try writer.add(path: "README.txt", data: Data("Paqo zip check\r\n".utf8), modified: Date())
        try writer.add(path: "runs/2026-11-22-0712-abcdef12.json", data: Data("{\"ok\": true}".utf8), modified: Date())
        try writer.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
