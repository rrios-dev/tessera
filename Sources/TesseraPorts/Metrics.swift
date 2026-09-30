import Foundation

/// Counters for the work Tessera does, so efficiency is measured rather than guessed
/// (`tessera debug stats`). Incrementing costs a few nanoseconds under a lock.
public enum Metrics {
    public enum Counter: String, CaseIterable, Sendable {
        case auditTicks, audits, rescans, renders, windowListCopies, skyLightCalls
        case axWindowQueries, axWrites, axReads, journalWrites, screenReads
        case notifyCreated, notifyDestroyed, notifyFocus, notifyChanged, notifyMoved, notifySpace, notifyApp
        case writeFailures, writeBackoffs, factsLearned, factsInvalidated, alignmentChecks, alignmentRetries
        case restoresConfirmed, restoresPending, ipcRequests, ipcRejected, keysPosted, keysRefused
    }

    nonisolated(unsafe) private static var values: [Counter: Int] = [:]
    private static let lock = NSLock()

    public static func count(_ counter: Counter, _ amount: Int = 1) {
        lock.lock()
        values[counter, default: 0] += amount
        lock.unlock()
    }

    /// Tests start from zero.
    public static func reset() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }

    public static func value(_ counter: Counter) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[counter] ?? 0
    }

    public static func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: Counter.allCases.map { ($0.rawValue, values[$0] ?? 0) })
    }
}
