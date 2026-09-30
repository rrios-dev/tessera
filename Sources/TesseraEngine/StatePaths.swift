import Darwin
public import Foundation
import TesseraIPC

/// Where one engine keeps its state. The owner's engine uses the default directory; tests and
/// benchmarks pass their own (`--state-dir`, `TESSERA_HOME`), so they never touch the owner's
/// socket, journal or log (audit A2).
public struct StatePaths: Sendable {
    public let directory: URL
    public let isDefault: Bool

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tessera", isDirectory: true)
    }

    public init(directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let directory {
            self.directory = directory
            isDefault = false
        } else if let home = environment["TESSERA_HOME"], !home.isEmpty {
            self.directory = URL(fileURLWithPath: home, isDirectory: true)
            isDefault = false
        } else {
            self.directory = Self.defaultDirectory
            isDefault = true
        }
    }

    public var socket: String { LineSocket.path(stateDirectory: isDefault ? nil : directory) }
    public var lock: URL { file("engine.lock") }
    public var journal: URL { file("journal.json") }
    public var world: URL { file("world.json") }
    public var facts: URL { file("facts.json") }
    public var edgeClamp: URL { file("edge-clamp.json") }
    public var starts: URL { file("starts.json") }
    public var originalLayout: URL { file("original-layout.json") }
    public var enhancedUI: URL { file("enhanced-ui.json") }
    public var log: URL { file("tessera.log") }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Creates the directory owner-only (0700): window frames and pids are nobody else's business.
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        // Files written by earlier versions (0644) are tightened too, not only new ones.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG { chmod(path, 0o600) }
        }
    }
}

/// Files written atomically and owner-only (0600) (audit A4).
enum SecureFile {
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(value), to: url)
    }

    /// Nil when absent; throws when present but unreadable (the caller quarantines it).
    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Moves a corrupt file aside so it can be inspected and is never read again.
    @discardableResult
    static func quarantine(_ url: URL, now: Date) -> URL? {
        let stamp = Int(now.timeIntervalSince1970)
        let destination = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        return rename(url.path, destination.path) == 0 ? destination : nil
    }
}

/// An exclusive `flock` on `engine.lock`: one engine per state directory.
final class StateLock {
    private let descriptor: Int32

    enum Failure: Error, CustomStringConvertible {
        case held(URL)
        case cannotOpen(URL)

        var description: String {
            switch self {
            case .held(let url): "another Tessera engine is running with \(url.deletingLastPathComponent().path)"
            case .cannotOpen(let url): "cannot open \(url.path)"
            }
        }
    }

    init(_ url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.cannotOpen(url) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Failure.held(url)
        }
        ftruncate(descriptor, 0)
        let pid = Data("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
