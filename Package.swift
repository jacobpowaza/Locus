// swift-tools-version:5.9
//
// Platform-independent core of Locus "Scheduled Runs" (scheduling engine,
// route interpolation, speed profiles, ETA, persistence).
//
// The same source files are compiled into the iOS app target by XcodeGen
// (`project.yml` includes everything under `Locus/`). This package exists so
// the logic can be built and unit/integration-tested with `swift test` on
// Linux (Docker) or macOS without Xcode, an iOS Simulator, or a device.
// See docs/TESTING.md.
import PackageDescription

let package = Package(
    name: "LocusSchedulingCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LocusSchedulingCore", targets: ["LocusSchedulingCore"]),
    ],
    targets: [
        .target(
            name: "LocusSchedulingCore",
            path: "Locus/Scheduling/Core"
        ),
        .testTarget(
            name: "LocusSchedulingCoreTests",
            dependencies: ["LocusSchedulingCore"],
            path: "Tests/LocusSchedulingCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
