public import Foundation
public import TesseraCore

/// Where every window Tessera hid came from, written before the window moves, so a crash or a
/// forced quit never leaves windows parked in a corner (plan §8).
///
/// An entry leaves the journal only when a read-back shows the window back where it was, or when
/// the window no longer exists (audit A1). Entries from another boot are discarded: window ids
/// and pids do not survive a restart (A4).
public struct Journal: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var pid: Int32
        public var frame: Rect
        public var bundleID: String?

        public init(pid: Int32, frame: Rect, bundleID: String? = nil) {
            self.pid = pid
            self.frame = frame
            self.bundleID = bundleID
        }
    }

    public var bootSession: String
    public var hidden: [WindowID: Entry] = [:]

    public init(bootSession: String) {
        self.bootSession = bootSession
    }

    /// Journals written before boot sessions were recorded (≤ 0.1) carry none; their entries are
    /// kept and filtered by whether the windows still exist.
    static let legacySession = "legacy"

    enum CodingKeys: String, CodingKey { case bootSession, hidden }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bootSession = try container.decodeIfPresent(String.self, forKey: .bootSession) ?? Self.legacySession
        // Window ids are object keys, as text, so the file stays readable.
        let raw = try container.decodeIfPresent([String: Entry].self, forKey: .hidden) ?? [:]
        hidden = Dictionary(uniqueKeysWithValues: raw.compactMap { key, entry in WindowID(key).map { ($0, entry) } })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bootSession, forKey: .bootSession)
        try container.encode(Dictionary(uniqueKeysWithValues: hidden.map { (String($0.key), $0.value) }), forKey: .hidden)
    }

    public enum LoadResult: Equatable {
        case fresh(Journal)
        case loaded(Journal)
        /// The file was unreadable and was moved aside to this path.
        case quarantined(Journal, URL?)
        /// Written during another boot: its ids mean nothing now.
        case staleBoot(Journal)
    }

    public static func load(from url: URL, bootSession: String, now: Date) -> LoadResult {
        do {
            guard let journal = try SecureFile.readJSON(Journal.self, from: url) else { return .fresh(Journal(bootSession: bootSession)) }
            if journal.bootSession == legacySession {
                var adopted = journal
                adopted.bootSession = bootSession
                return .loaded(adopted)
            }
            guard journal.bootSession == bootSession else { return .staleBoot(Journal(bootSession: bootSession)) }
            return .loaded(journal)
        } catch {
            return .quarantined(Journal(bootSession: bootSession), SecureFile.quarantine(url, now: now))
        }
    }

    public func save(to url: URL) throws {
        try SecureFile.writeJSON(self, to: url)
    }
}
