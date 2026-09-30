public import Foundation

/// Every delay and budget the engine uses, named (audit F9). Budgets are compared against the
/// port's clock, so tests can jump over a minute-long backoff; delays are real.
public struct Timing: Sendable {
    /// Notifications for one app within this window cost one scan.
    public var rescanCoalesce: TimeInterval = 0.03
    /// A read this soon after Tessera's own write shows an intermediate frame.
    public var echoWindow: TimeInterval = 0.3
    /// A refused size is re-read after this long before anything is learned from it (C1).
    public var settleRead: TimeInterval = 0.12
    /// After the mouse button goes up, the window settles for this long before the drop is read.
    public var dropSettle: TimeInterval = 0.12
    /// The Space notification can precede SkyLight's answer: look again at these delays.
    public var spaceChecks: [TimeInterval] = [0, 0.35, 0.9]
    /// A close can leave the window listed for a few milliseconds: audit again at these delays.
    public var auditBurst: [TimeInterval] = [0.05, 0.15, 0.4]
    public var fastAudit: TimeInterval = 2
    public var slowAudit: TimeInterval = 30
    /// Without activity for this long the audit slows down.
    public var idleAfter: TimeInterval = 10
    /// A focus request that cannot be honoured within this long is dropped (C8).
    public var pendingFocusTTL: TimeInterval = 0.5
    /// Outside moves of a tiled window are undone at most twice in this window.
    public var driftWindow: TimeInterval = 10
    public var driftLimit = 2
    /// More than `writeLimit` writes to one window within `writeWindow` is a loop (C2).
    public var writeWindow: TimeInterval = 5
    public var writeLimit = 6
    public var backoffStart: TimeInterval = 60
    public var backoffMax: TimeInterval = 300
    public var permissionPoll: TimeInterval = 2
    /// A window untouched for this long is checked against its target (I9, C6).
    public var alignmentCalm: TimeInterval = 1
    public var alignmentRetryAfter: TimeInterval = 10
    public var alignmentMaxRetries = 3
    public var worldSaveDebounce: TimeInterval = 2
    /// "Revert to the original layout" is offered this long after start (E11).
    public var revertWindow: TimeInterval = 600
    /// Holding the base modifiers this long shows the shortcut overlay.
    public var cheatsheetHold: TimeInterval = 0.8
    public var shutdownWait: TimeInterval = 2
    /// An app that stopped answering is asked again at most this often.
    public var unresponsiveRetry: TimeInterval = 5
    /// A new window is left this long to finish opening before its refusals teach anything.
    public var openingGrace: TimeInterval = 2

    public init() {}

    public static let production = Timing()

    /// Every delay multiplied by `factor`; counts unchanged. For tests.
    public func scaled(_ factor: Double) -> Timing {
        var copy = self
        copy.rescanCoalesce *= factor
        copy.echoWindow *= factor
        copy.settleRead *= factor
        copy.dropSettle *= factor
        copy.spaceChecks = spaceChecks.map { $0 * factor }
        copy.auditBurst = auditBurst.map { $0 * factor }
        copy.fastAudit *= factor
        copy.slowAudit *= factor
        copy.idleAfter *= factor
        copy.pendingFocusTTL *= factor
        copy.permissionPoll *= factor
        copy.worldSaveDebounce *= factor
        copy.cheatsheetHold *= factor
        copy.shutdownWait *= factor
        copy.openingGrace *= factor
        return copy
    }
}
