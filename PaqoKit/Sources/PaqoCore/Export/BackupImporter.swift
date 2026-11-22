import Foundation

/// Runs read from backups, plus what couldn't be read.
public struct ImportBatch: Sendable {
    public var runs: [Run]
    public var problems: [String]
}

/// Reads Paqo run files back in: from a backup folder, a Paqo backup zip, or
/// individual `.json` files.
public enum BackupImporter {
    public static let compressedZipMessage = "This zip is compressed. Unzip it in the Files app, then pick the folder."

    public static func runs(from urls: [URL]) -> ImportBatch {
        var runs: [Run] = []
        var problems: [String] = []
        var seen = Set<UUID>()

        func add(_ data: Data, name: String) {
            do {
                let run = try RunJSON.decode(data)
                if seen.insert(run.id).inserted { runs.append(run) }
            } catch RunJSONError.newerVersion {
                problems.append("\(name): made by a newer version of Paqo.")
            } catch {
                problems.append("\(name): not a Paqo run file.")
            }
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                problems.append("\(url.lastPathComponent): couldn't be opened.")
                continue
            }
            if isDirectory.boolValue {
                for file in jsonFiles(in: url, isRoot: true) {
                    guard let data = try? Data(contentsOf: file) else {
                        problems.append("\(file.lastPathComponent): couldn't be read.")
                        continue
                    }
                    add(data, name: file.lastPathComponent)
                }
            } else if url.pathExtension.lowercased() == "zip" {
                do {
                    let entries = try ZipReader.entries(of: Data(contentsOf: url))
                    for entry in entries where entry.path.lowercased().hasSuffix(".json") {
                        let components = entry.path.split(separator: "/")
                        if components.dropLast().contains("deleted") { continue }
                        add(entry.data, name: String(components.last ?? ""))
                    }
                } catch ZipError.compressed {
                    problems.append(compressedZipMessage)
                } catch {
                    problems.append("\(url.lastPathComponent): not a zip Paqo can read.")
                }
            } else if let data = try? Data(contentsOf: url) {
                add(data, name: url.lastPathComponent)
            } else {
                problems.append("\(url.lastPathComponent): couldn't be read.")
            }
        }
        return ImportBatch(runs: runs.sorted { $0.startDate < $1.startDate }, problems: problems)
    }

    /// JSON files under a folder, skipping `deleted` folders below the one picked.
    static func jsonFiles(in folder: URL, isRoot: Bool) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var result: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                if item.lastPathComponent == "deleted" { continue }
                result += jsonFiles(in: item, isRoot: false)
            } else if item.pathExtension.lowercased() == "json" {
                result.append(item)
            }
        }
        return result
    }
}
