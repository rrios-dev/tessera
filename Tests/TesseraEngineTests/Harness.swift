import Foundation
import Testing
@testable import TesseraEngine
import TesseraCore
import TesseraFakes
import TesseraPorts

/// One engine against the fake macOS, in its own temporary state directory.
@MainActor
final class Harness {
    let platform: FakePlatform
    let ui = RecordingUI()
    let directory: URL
    private(set) var engine: Engine
    var options: Engine.Options
    let timing: Timing

    /// How much slower than a developer's Mac the machine running the suite is. Every interval
    /// the engine uses and every wait the tests make scale by it together, so their proportions
    /// hold: a shared CI runner sets `TESSERA_TEST_PACE` (see ci.yml) instead of each test
    /// growing its own margins.
    static let pace: Double = {
        let value = ProcessInfo.processInfo.environment["TESSERA_TEST_PACE"].flatMap(Double.init) ?? 1
        return max(value, 1)
    }()

    static let timing: Timing = {
        var timing = Timing.production.scaled(0.02 * pace)
        // Quitting waits for confirmations; under a loaded test run 40 ms is not enough.
        timing.shutdownWait = 3 * pace
        return timing
    }()

    init(
        directory: URL? = nil, native: Bool = true, platform: FakePlatform? = nil, timing: Timing = Harness.timing,
        configure: (inout Engine.Options) -> Void = { _ in }
    ) throws {
        self.timing = timing
        self.platform = platform ?? FakePlatform()
        if platform == nil { self.platform.dockClamp = 0 }
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-tests-\(UUID().uuidString)", isDirectory: true)
        var options = Engine.Options()
        options.stateDirectory = self.directory
        options.configFile = self.directory.appendingPathComponent("config.toml")
        options.ipc = false
        options.nativeWorkspaces = native
        configure(&options)
        self.options = options
        engine = Engine(options: options, port: self.platform, ui: ui, timing: timing, log: Log(url: nil, echoToStandardError: false))
    }

    func start() throws { try engine.start() }

    /// A new engine on the same state directory and platform, as after a restart.
    func restart(configure: (inout Engine.Options) -> Void = { _ in }) throws {
        var options = self.options
        configure(&options)
        engine = Engine(options: options, port: platform, ui: ui, timing: timing, log: Log(url: nil, echoToStandardError: false))
        try engine.start()
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.shutdown(reason: "test") { continuation.resume() }
        }
    }

    func writeConfig(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    /// Polls `condition` every few milliseconds until it holds or `timeout` passes.
    func until(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout * Harness.pace)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    func settle(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * Harness.pace * 1_000_000_000))
    }

    func frame(_ id: WindowID) -> Rect? { platform.windows[id]?.frame }
    func frames(_ ids: [WindowID]) -> [Rect?] { ids.map(frame) }

    /// Every invariant, with the clock moved past the calm period so settled windows count.
    func violations() -> [String] {
        platform.advanceClock(by: 5)
        return engine.checkInvariants()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension Rect {
    init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) { self.init(x: x, y: y, width: width, height: height) }
}
