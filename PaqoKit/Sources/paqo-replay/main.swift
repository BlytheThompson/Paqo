import Foundation
import PaqoCore

// paqo-replay: runs a Paqo sensor log through the same engine the phone uses.
//
//   swift run paqo-replay <log folder or zip> [--set key=value ...] [--json]

let usage = """
Usage: paqo-replay <log folder or zip> [--set key=value ...] [--json]

  --set key=value   override an engine setting, e.g. --set sprintCadence=150
  --json            print machine-readable output

Settings: \(ConfigOverrides.keys.joined(separator: ", "))
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n\n" + usage + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var path: String?
var overrides: [String] = []
var json = false
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--set":
        guard !arguments.isEmpty else { fail("--set needs key=value") }
        overrides.append(arguments.removeFirst())
    case "--json":
        json = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if path == nil { path = argument } else { fail("Unexpected argument: \(argument)") }
    }
}

guard let path else { fail("Missing log folder or zip.") }

do {
    let files = try SensorLogFiles.read(from: URL(fileURLWithPath: path))
    let log = try SensorLogCodec.decode(files: files)
    var config = log.meta.config ?? RunEngine.Configuration()
    try ConfigOverrides.apply(overrides, to: &config)
    let run = SessionReplayer.replay(log, config: config)
    print(json ? try ReplayReport.json(for: run) : ReplayReport.text(for: run))
} catch let error as ConfigOverrideError {
    fail(error.description)
} catch {
    fail("Couldn't read the log at \(path): \(error)")
}
