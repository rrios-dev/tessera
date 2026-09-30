import Foundation

/// `tessera service …`: runs the engine under launchd so it starts at login, comes back after
/// a crash and stays down after "Quit" (audit A3).
///
/// `KeepAlive = { SuccessfulExit = false, Crashed = true }`: launchd restarts Tessera when it
/// crashes or exits with an error, never when it quits normally (exit 0 is only Quit and
/// launchd's own SIGTERM). `ThrottleInterval = 5` bounds a crash loop; the engine's crash guard
/// turns three crashes in five minutes into safe mode.
enum Service {
    static var label: String { ProcessInfo.processInfo.environment["TESSERA_SERVICE_LABEL"] ?? "dev.rrios.tessera" }

    static var agentsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TESSERA_LAUNCH_AGENTS"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var plistURL: URL { agentsDirectory.appendingPathComponent("\(label).plist") }
    static var logDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tessera", isDirectory: true) }
    static var domain: String { "gui/\(getuid())" }

    static func plist(binary: String, arguments: [String], environment: [String: String]) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "run"] + arguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false, "Crashed": true],
            "ThrottleInterval": 5,
            "ExitTimeOut": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logDirectory.appendingPathComponent("launchd.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("launchd.log").path,
        ]
        if !environment.isEmpty { plist["EnvironmentVariables"] = environment }
        return plist
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { return usage() }
        switch verb {
        case "install":
            var binary = CommandLine.arguments[0]
            var extra: [String] = []
            var environment: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--binary":
                    index += 1
                    guard index < arguments.count else { return usage() }
                    binary = arguments[index]
                case "--env":
                    index += 1
                    guard index < arguments.count, let equals = arguments[index].firstIndex(of: "=") else { return usage() }
                    environment[String(arguments[index][..<equals])] = String(arguments[index][arguments[index].index(after: equals)...])
                case "--":
                    extra = Array(arguments[(index + 1)...])
                    index = arguments.count
                    continue
                default:
                    return usage()
                }
                index += 1
            }
            return install(binary: absolute(binary), arguments: extra, environment: environment)
        case "uninstall":
            _ = launchctl(["bootout", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
            print("removed \(label)")
            return 0
        case "status":
            let (code, output) = launchctl(["print", "\(domain)/\(label)"])
            guard code == 0 else {
                print("\(label): not loaded")
                return 1
            }
            for line in output.split(separator: "\n") where ["state =", "pid =", "last exit code =", "runs ="].contains(where: { line.contains($0) }) {
                print(line.trimmingCharacters(in: .whitespaces))
            }
            return 0
        case "restart":
            let (code, output) = launchctl(["kickstart", "-k", "\(domain)/\(label)"])
            if code != 0 { FileHandle.standardError.write(Data(output.utf8)) }
            return code
        default:
            return usage()
        }
    }

    static func install(binary: String, arguments: [String], environment: [String: String]) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist(binary: binary, arguments: arguments, environment: environment), format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("tessera service: \(error)\n".utf8))
            return 1
        }
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        let (code, output) = launchctl(["bootstrap", domain, plistURL.path])
        guard code == 0 else {
            FileHandle.standardError.write(Data("tessera service: launchctl bootstrap failed: \(output)\n".utf8))
            return 1
        }
        print("installed \(label) → \(binary)")
        print("Tessera now starts at login and comes back after a crash. Grant it Accessibility if macOS asks.")
        return 0
    }

    static func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func usage() -> Int32 {
        FileHandle.standardError.write(Data("""
        usage: tessera service install [--binary <path>] [--env KEY=VALUE]... [-- <run options>]
               tessera service uninstall | status | restart

        """.utf8))
        return 64
    }
}
