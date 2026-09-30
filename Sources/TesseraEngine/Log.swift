import Darwin
public import Foundation
import os

/// The engine's log (audit F4): timestamped lines with a level and a category in the state
/// directory's `tessera.log` (0600, rotated at 5 MB), mirrored to the unified log under
/// `dev.rrios.tessera` with dynamic content marked private. Identical lines within 10 s are
/// collapsed. Window titles are never logged anywhere.
@MainActor
public final class Log {
    public enum Level: String, Sendable { case debug, info, notice, error }
    public enum Category: String, Sendable, CaseIterable { case engine, ax, ipc, journal, keys, spaces }

    private let url: URL?
    private let echoToStandardError: Bool
    private var handle: FileHandle?
    private var loggers: [Category: Logger] = [:]
    private var recent: [String: (at: Date, suppressed: Int)] = [:]
    public private(set) var lastError: String?
    public var verbose = false

    static let rotationSize: UInt64 = 5 * 1024 * 1024

    public init(url: URL?, echoToStandardError: Bool = true) {
        self.url = url
        self.echoToStandardError = echoToStandardError
        for category in Category.allCases { loggers[category] = Logger(subsystem: "dev.rrios.tessera", category: category.rawValue) }
        open()
    }

    private func open() {
        guard let url else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        chmod(url.path, 0o600)
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeeded() {
        guard let url, let size = try? handle?.offset(), size > Self.rotationSize else { return }
        try? handle?.close()
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        open()
    }

    public func debug(_ message: @autoclosure () -> String, _ category: Category = .engine) {
        guard verbose else { return }
        write(.debug, category, message())
    }

    public func info(_ message: String, _ category: Category = .engine) { write(.info, category, message) }
    public func notice(_ message: String, _ category: Category = .engine) { write(.notice, category, message) }

    public func error(_ message: String, _ category: Category = .engine) {
        lastError = message
        write(.error, category, message)
    }

    private func write(_ level: Level, _ category: Category, _ message: String) {
        let now = Date()
        let key = "\(category.rawValue)|\(message)"
        if let seen = recent[key], now.timeIntervalSince(seen.at) < 10 {
            recent[key] = (seen.at, seen.suppressed + 1)
            return
        }
        var text = message
        if let seen = recent[key], seen.suppressed > 0 { text += " (repeated \(seen.suppressed) more times)" }
        recent[key] = (now, 0)
        if recent.count > 512 { recent = recent.filter { now.timeIntervalSince($0.value.at) < 10 } }

        let logger = loggers[category]!
        switch level {
        case .debug: logger.debug("\(text, privacy: .private)")
        case .info: logger.info("\(text, privacy: .private)")
        case .notice: logger.notice("\(text, privacy: .private)")
        case .error: logger.error("\(text, privacy: .private)")
        }
        let line = "\(Self.timestamp(now)) \(level.rawValue.uppercased()) [\(category.rawValue)] \(text)\n"
        if let handle {
            handle.write(Data(line.utf8))
            rotateIfNeeded()
        }
        if echoToStandardError { FileHandle.standardError.write(Data(line.utf8)) }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
