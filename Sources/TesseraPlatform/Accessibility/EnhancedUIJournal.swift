import Foundation

/// Apps whose `AXEnhancedUserInterface` is off right now because Tessera is writing to them.
/// Written synchronously from the apps' queues, so a crash between the two writes still leaves a
/// record the next run uses to turn it back on (audit F11).
final class EnhancedUIJournal: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var pids: Set<Int32> = []

    init(url: URL) {
        self.url = url
    }

    /// The pids a previous run left off; clears the file.
    func takePending() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Int32].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return list
    }

    func mark(_ pid: Int32, off: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if off { pids.insert(pid) } else { pids.remove(pid) }
        if pids.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(pids.sorted()) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
