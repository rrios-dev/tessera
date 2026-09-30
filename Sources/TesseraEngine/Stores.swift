public import Foundation
public import TesseraCore

/// Window facts that outlive a restart, keyed the way plan §4.3 says a window type behaves the
/// same: bundle, version, subrole and screen scale; forgotten after 30 days (audit D6).
public struct FactStore: Codable, Sendable, Equatable {
    public struct Key: Hashable, Codable, Sendable {
        public var bundleID: String
        public var version: String
        public var subrole: String
        public var scale: Int

        public init(bundleID: String, version: String?, subrole: String?, scale: Int) {
            self.bundleID = bundleID
            self.version = version ?? "?"
            self.subrole = subrole ?? "?"
            self.scale = scale
        }

        var text: String { "\(bundleID)|\(version)|\(subrole)|@\(scale)x" }
    }

    public struct Record: Codable, Sendable, Equatable {
        public var facts: WindowFacts
        public var learnedAt: Date
    }

    public static let lifetime: TimeInterval = 30 * 24 * 3600
    public var records: [String: Record] = [:]

    public init() {}

    public func facts(for key: Key, now: Date) -> WindowFacts? {
        guard let record = records[key.text], now.timeIntervalSince(record.learnedAt) < Self.lifetime else { return nil }
        return record.facts
    }

    public mutating func remember(_ facts: WindowFacts, for key: Key, now: Date) {
        records[key.text] = Record(facts: facts, learnedAt: now)
    }

    public mutating func forget(_ key: Key) { records[key.text] = nil }

    public mutating func prune(now: Date) {
        records = records.filter { now.timeIntervalSince($0.value.learnedAt) < Self.lifetime }
    }
}

/// The model saved a moment after it changes, so a restart (or launchd bringing Tessera back
/// after a crash) keeps every desktop's tree instead of re-tiling from scratch (audit F6).
public struct WorldSnapshot: Codable, Sendable {
    public var bootSession: String
    public var world: World
}

/// Unclean starts in the last few minutes. Three within five minutes is a crash loop: the
/// engine then starts in safe mode, restores every window and moves nothing (audit A3).
public struct CrashGuard: Codable, Sendable, Equatable {
    public var starts: [Date] = []

    public static let window: TimeInterval = 300
    public static let limit = 3

    public init() {}

    /// Records a start. Returns true when this start completes a crash loop.
    public mutating func recordStart(now: Date) -> Bool {
        starts = starts.filter { now.timeIntervalSince($0) < Self.window } + [now]
        return starts.count >= Self.limit
    }

    public mutating func recordCleanExit() { starts.removeAll() }
}

/// The learned edge clamp per screen arrangement, so it is measured once, not once per run.
public struct EdgeClampStore: Codable, Sendable, Equatable {
    public var insets: [String: Insets] = [:]

    public init() {}

    public static func key(frame: Rect, usable: Rect) -> String {
        "\(frame.x),\(frame.y),\(frame.width)x\(frame.height)|\(usable.x),\(usable.y),\(usable.width)x\(usable.height)"
    }
}

/// Frames of every window as Tessera first saw them in this run (audit E11).
public struct OriginalLayout: Codable, Sendable, Equatable {
    public var bootSession: String
    public var capturedAt: Date
    public var frames: [WindowID: Rect] = [:]
    public var pids: [WindowID: Int32] = [:]
}
