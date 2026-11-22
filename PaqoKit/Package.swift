// swift-tools-version: 5.10
import PackageDescription

// PaqoKit holds everything the app needs that is not UI.
//
// - PaqoCore: pure Swift (Foundation only). Run recording engine, GPS filtering,
//   sprint/walk detection, splits, best efforts, records, streaks and storage.
//   Builds and tests on Windows, Linux and macOS, so it can be verified without a Mac.
// - PaqoSensors: thin iOS-only wrappers around CoreLocation, CoreMotion and HealthKit
//   that feed PaqoCore. Compiled out on every other platform.
let package = Package(
    name: "PaqoKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PaqoKit", targets: ["PaqoCore", "PaqoSensors"]),
    ],
    targets: [
        .target(name: "PaqoCore"),
        .target(name: "PaqoSensors", dependencies: ["PaqoCore"]),
        .testTarget(name: "PaqoCoreTests", dependencies: ["PaqoCore"]),
    ]
)
