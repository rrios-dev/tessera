// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode implies complete strict concurrency checking.
let common: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Tessera",
    platforms: [.macOS("15.2")],
    products: [
        .executable(name: "tessera", targets: ["tessera"]),
        .executable(name: "DummyWindowApp", targets: ["DummyWindowApp"]),
    ],
    targets: [
        // Pure model, solver and invariants. Standard library only: no Foundation, no AppKit.
        .target(name: "TesseraCore", swiftSettings: common),
        // Configuration schema, migrations and the AeroSpace importer.
        .target(name: "TesseraConfig", dependencies: ["TesseraCore", "TesseraPorts"], swiftSettings: common),
        // Interfaces between the engine and the operating system; real and fake implementations.
        .target(name: "TesseraPorts", dependencies: ["TesseraCore"], swiftSettings: common),
        // Shared wire contracts: engine <-> CLI (socket) and engine <-> Settings (XPC).
        .target(name: "TesseraIPC", dependencies: ["TesseraCore"], swiftSettings: common),
        // Everything that talks to macOS: Accessibility, CGWindowList, displays, hotkeys, event taps.
        .target(
            name: "TesseraPlatform",
            dependencies: ["TesseraCore", "TesseraConfig", "TesseraPorts"],
            swiftSettings: common,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
            ]
        ),
        // Deterministic fake window server implementing the same ports as TesseraPlatform.
        .target(name: "TesseraFakes", dependencies: ["TesseraCore", "TesseraPorts"], swiftSettings: common),
        // Event pump, store, reconciler, invariant verifier, journal, persistence.
        .target(
            name: "TesseraEngine",
            dependencies: ["TesseraCore", "TesseraConfig", "TesseraIPC", "TesseraPorts"],
            swiftSettings: common
        ),
        // The AppKit side of the engine's UI: menu bar item, on-screen display, drop highlight,
        // shortcut overlay.
        .target(
            name: "TesseraAppUI",
            dependencies: ["TesseraCore", "TesseraConfig", "TesseraEngine", "TesseraPorts"],
            swiftSettings: common,
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "tessera",
            dependencies: ["TesseraCore", "TesseraConfig", "TesseraPlatform", "TesseraPorts", "TesseraIPC", "TesseraEngine", "TesseraAppUI"],
            swiftSettings: common
        ),
        // Helpers for the live tests: Spaces, visible windows, parked windows, a synthetic drag.
        .executableTarget(name: "tessera-labtools", swiftSettings: common),
        // Timing benchmarks for the pure core, checked against the plan's §11 gates.
        .executableTarget(name: "tessera-bench", dependencies: ["TesseraCore"], swiftSettings: common),
        // Scriptable test windows with configurable min/max, quantum, aspect and self-resize.
        .target(name: "DummyWindowKit", dependencies: ["TesseraCore"], swiftSettings: common),
        .executableTarget(
            name: "DummyWindowApp",
            dependencies: ["DummyWindowKit", "TesseraCore"],
            swiftSettings: common,
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "TesseraCoreTests", dependencies: ["TesseraCore"], swiftSettings: common),
        .testTarget(
            name: "TesseraConfigTests",
            dependencies: ["TesseraConfig", "TesseraCore", "TesseraPorts"],
            swiftSettings: common
        ),
        .testTarget(name: "TesseraPlatformTests", dependencies: ["TesseraPlatform", "TesseraCore"], swiftSettings: common),
        .testTarget(name: "TesseraIPCTests", dependencies: ["TesseraIPC", "TesseraCore"], swiftSettings: common),
        .testTarget(
            name: "TesseraEngineTests",
            dependencies: ["TesseraEngine", "TesseraFakes", "TesseraCore", "TesseraPorts", "TesseraConfig", "TesseraIPC"],
            swiftSettings: common
        ),
        .testTarget(
            name: "DummyWindowKitTests",
            dependencies: ["DummyWindowKit", "TesseraCore"],
            swiftSettings: common
        ),
    ]
)
