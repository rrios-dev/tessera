import AppKit
import Foundation
import TesseraAppUI
import TesseraConfig
import TesseraCore
import TesseraEngine
import TesseraIPC
import TesseraPlatform

/// Command-line entry point: the engine (`run`), the service, diagnostics and the commands the
/// CLI forwards to a running engine (AeroSpace-compatible names).
@MainActor
func run(_ arguments: [String]) -> Int32 {
    var arguments = arguments
    // Global: --state-dir selects the engine (socket) the CLI talks to, like TESSERA_HOME.
    if let index = arguments.firstIndex(of: "--state-dir") {
        guard index + 1 < arguments.count else { return usageError("--state-dir needs a directory") }
        setenv("TESSERA_HOME", arguments[index + 1], 1)
        arguments.removeSubrange(index...(index + 1))
    }
    guard let command = arguments.first else {
        printUsage()
        return 64
    }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "doctor": return doctor(rest)
    case "run": return runEngine(rest)
    case "service": return Service.run(rest)
    case "keys":
        let voiceOver = rest.contains("--voiceover") || NSWorkspace.shared.isVoiceOverEnabled
        KeymapText.lines(Keymap.defaults(voiceOver: voiceOver)).forEach { print($0) }
        return 0
    case "version", "--version", "-v":
        print(BuildInfo.description)
        return 0
    case "debug":
        guard let what = rest.first, ["state", "stats", "activity", "check"].contains(what) else {
            return usageError("usage: tessera debug state|stats|activity|check")
        }
        return send(IPCRequest(query: what))
    case "reload-config", "pause", "resume", "toggle-pause", "gather", "retile", "revert-layout", "retry", "forget-sizes":
        return send(IPCRequest(action: command))
    case "help", "--help", "-h":
        printUsage()
        return 0
    default:
        do {
            _ = try CommandParser.parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("tessera: \(error.description)\n".utf8))
            printUsage()
            return 64
        }
        return send(IPCRequest(command: arguments))
    }
}

@MainActor
func doctor(_ arguments: [String]) -> Int32 {
    var outputPath: String?
    var raw = false
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--output", "-o":
            index += 1
            guard index < arguments.count else { return usageError("doctor: --output needs a path") }
            outputPath = arguments[index]
        case "--raw":
            raw = true
        default:
            return usageError("doctor: unknown option '\(arguments[index])'")
        }
        index += 1
    }
    let captured = EnvironmentProbe.capture()
    let fixture = raw ? captured : captured.redacted()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        var data = try encoder.encode(fixture)
        data.append(0x0A)
        if let outputPath {
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            FileHandle.standardError.write(Data("tessera doctor: wrote \(outputPath)\(raw ? "" : " (identifiers redacted; --raw keeps them)")\n".utf8))
        } else {
            FileHandle.standardOutput.write(data)
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("tessera doctor: \(error)\n".utf8))
        return 1
    }
}

/// Sends one request to the running engine and prints the reply.
func send(_ request: IPCRequest) -> Int32 {
    do {
        let data = try JSONEncoder().encode(request)
        let reply = try LineSocket.request(data)
        let response = try JSONDecoder().decode(IPCResponse.self, from: reply)
        if let info = response.info {
            for (key, value) in info.sorted(by: { $0.key < $1.key }) { print("\(key): \(value)") }
        }
        if let stats = response.stats {
            for (key, value) in stats.sorted(by: { $0.key < $1.key }) { print("\(key) \(value)") }
        }
        response.lines?.forEach { print($0) }
        if let state = response.state {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(state))
            print("")
        }
        if let error = response.error { FileHandle.standardError.write(Data("tessera: \(error)\n".utf8)) }
        return response.ok ? 0 : 1
    } catch {
        FileHandle.standardError.write(Data("tessera: the engine is not running (tessera run)\n".utf8))
        return 1
    }
}

/// Options that exist for testing and measuring only (audit F10).
let developerOptions: Set<String> = ["--only-pid", "--tile-all", "--dry-run", "--no-menu", "--no-ipc", "--no-prompt"]
var developerMode: Bool { ProcessInfo.processInfo.environment["TESSERA_DEVELOPER"] == "1" }

@MainActor
func runEngine(_ arguments: [String]) -> Int32 {
    var options = Engine.Options()
    var menu = true
    var index = 0
    while index < arguments.count {
        let option = arguments[index]
        if developerOptions.contains(option), !developerMode {
            return usageError("\(option) is a developer option (set TESSERA_DEVELOPER=1)")
        }
        switch option {
        case "--only-pid":
            index += 1
            guard index < arguments.count, let pid = Int32(arguments[index]) else { return usageError("--only-pid needs a process id") }
            options.onlyPIDs = (options.onlyPIDs ?? []).union([pid])
        case "--no-hotkeys": options.hotkeys = false
        case "--verbose": options.verbose = true
        case "--tile-all": options.tileAll = true
        case "--no-menu": menu = false
        case "--no-ipc": options.ipc = false
        case "--no-prompt": options.promptForPermission = false
        case "--emulated-workspaces": options.nativeWorkspaces = false
        case "--dry-run":
            options.dryRun = true
            options.hotkeys = false
        case "--config":
            index += 1
            guard index < arguments.count else { return usageError("--config needs a path") }
            options.configFile = URL(fileURLWithPath: arguments[index])
        case "--gap":
            index += 1
            guard index < arguments.count, let gap = Int(arguments[index]), (0...WorldSettings.maxGap).contains(gap) else {
                return usageError("--gap needs 0…\(WorldSettings.maxGap) points")
            }
            options.settings.innerGap = gap
            options.settings.outerGap = gap
        default:
            return usageError("unknown option '\(option)'")
        }
        index += 1
    }
    if ProcessInfo.processInfo.environment["TESSERA_NO_PROMPT"] == "1" { options.promptForPermission = false }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let paths = StatePaths(directory: nil)
    options.stateDirectory = paths.isDefault ? nil : paths.directory
    try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let log = Log(url: paths.log)
    log.verbose = options.verbose
    let engine = Engine(options: options, port: LivePlatform(), ui: AppKitUI(menu: menu), log: log)
    engine.onQuitRequested = { engine.shutdown(reason: "quit from the menu") { exit(0) } }
    do {
        try engine.start()
    } catch Engine.StartError.alreadyRunning(let detail) {
        // Not a failure: another engine owns this state directory. Exit 0 so launchd does not
        // keep relaunching this one every few seconds.
        FileHandle.standardError.write(Data("tessera: \(detail)\n".utf8))
        return 0
    } catch {
        FileHandle.standardError.write(Data("tessera: \(error)\n".utf8))
        return 1
    }

    // Quit, Ctrl-C and launchd's SIGTERM all put hidden windows back before exiting.
    for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { engine.shutdown(reason: "signal \(signalNumber)") { exit(0) } }
        }
        source.resume()
        retainedSignalSources.append(source)
    }
    // Logging out or shutting down restores windows too.
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { engine.shutdown(reason: "power off") { exit(0) } }
    }
    application.run()
    return 0
}

nonisolated(unsafe) var retainedSignalSources: [any DispatchSourceSignal] = []

func usageError(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("tessera: \(message)\n".utf8))
    return 64
}

func printUsage() {
    print("""
    usage: tessera [--state-dir <dir>] <command> [options]

    engine:
      run [--no-hotkeys] [--gap <points>] [--verbose] [--emulated-workspaces] [--config <file>]
      service install|uninstall|status|restart     Run under launchd (login item, crash restart).
      pause | resume | retile (alias gather) | reload-config | revert-layout | retry | forget-sizes
      keys [--voiceover]         Print the keyboard shortcuts.
      version

    diagnostics:
      debug state|stats|activity|check
      doctor [--output <path>] [--raw]   Environment fixture (identifiers redacted unless --raw).

    commands (sent to the running engine):
    \(CommandParser.usage.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))

    State lives in ~/Library/Application Support/Tessera (TESSERA_HOME or --state-dir to change it).
    Developer options (TESSERA_DEVELOPER=1): --only-pid <pid>, --tile-all, --dry-run, --no-menu, --no-ipc, --no-prompt.
    """)
}

let launchArguments = LaunchCommand.arguments(
    given: Array(CommandLine.arguments.dropFirst()),
    inAppBundle: Bundle.main.bundleURL.pathExtension == "app",
    interactive: isatty(STDIN_FILENO) != 0
)
exit(MainActor.assumeIsolated { run(launchArguments) })
