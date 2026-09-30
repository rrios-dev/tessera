public import TesseraCore
public import TesseraPorts
import AppKit
import ApplicationServices

/// Everything Tessera does to one app's windows, serialised on that app's own queue so a slow
/// or hung app never blocks the engine or any other app.
public final class AXApplication: AppDriver, @unchecked Sendable {
    public let pid: Int32
    let element: AXUIElement
    let queue: DispatchQueue
    // All of the following are touched only on `queue`.
    private var elements: [WindowID: AXUIElement] = [:]
    /// Attributes that do not change during a window's life, read once per window.
    private var staticTraits: [WindowID: (canResize: Bool, hasFullscreenButton: Bool)] = [:]
    /// Whether the app has `AXEnhancedUserInterface` on, re-read at most every few seconds.
    private var enhancedUI: (value: Bool, readAt: Date)?
    private var consecutiveTimeouts = 0
    private let unresponsiveLock = NSLock()
    private var unresponsive = false
    private weak var hub: AXObserverHub?

    /// Budget for layout writes; discovery uses the process-wide default.
    static let writeTimeout: Float = 0.35
    /// Budget for app-level calls (window list, observer registration).
    static let appTimeout: Float = 0.5

    public convenience init(pid: Int32) {
        self.init(pid: pid, hub: nil)
    }

    init(pid: Int32, hub: AXObserverHub?) {
        self.pid = pid
        self.hub = hub
        element = AXUIElementCreateApplication(pid)
        queue = DispatchQueue(label: "tessera.ax.\(pid)", qos: .userInitiated)
        AXUIElementSetMessagingTimeout(element, Self.appTimeout)
    }

    // MARK: Observation (on this app's queue, never on the observer thread)

    /// Registers the app's observer, retrying while the app is still launching.
    func startObserving(attempt: Int = 0) {
        queue.async { [self] in
            guard let hub else { return }
            if hub.register(pid: pid, app: element) {
                _ = readWindows()
            } else if attempt < 10 {
                queue.asyncAfter(deadline: .now() + 0.3) { [self] in startObserving(attempt: attempt + 1) }
            }
        }
    }

    /// Subscribes windows that appeared since the last read.
    func observeWindows() {
        queue.async { [self] in
            guard !isUnresponsive else { return }
            _ = readWindows()
        }
    }

    /// Sets the process-wide default timeout once, at start-up (plan §2).
    public static func configureGlobalTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
    }

    public var isUnresponsive: Bool {
        unresponsiveLock.lock()
        defer { unresponsiveLock.unlock() }
        return unresponsive
    }

    private func record(_ error: AXError) {
        if error == .cannotComplete {
            consecutiveTimeouts += 1
        } else if error == .success {
            consecutiveTimeouts = 0
        }
        unresponsiveLock.lock()
        unresponsive = consecutiveTimeouts >= 3
        unresponsiveLock.unlock()
    }

    // MARK: Reading

    public func windows(completion: @escaping @Sendable ([WindowSnapshot]?) -> Void) {
        queue.async { [self] in completion(readWindows()) }
    }

    func readWindows() -> [WindowSnapshot]? {
        Metrics.count(.axWindowQueries)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        record(error)
        guard error == .success, let list = value as? [AXUIElement] else { return nil }
        var snapshots: [WindowSnapshot] = []
        var fresh: [WindowID: AXUIElement] = [:]
        for window in list {
            AXUIElementSetMessagingTimeout(window, Self.writeTimeout)
            let snapshot = snapshot(of: window)
            guard let snapshot else { continue }
            fresh[snapshot.id] = window
            snapshots.append(snapshot)
        }
        elements = fresh
        staticTraits = staticTraits.filter { fresh[$0.key] != nil }
        hub?.subscribe(pid: pid, windows: fresh.map { ($0.value, $0.key) })
        return snapshots
    }

    /// One round trip for the changing attributes; the static ones are read once per window.
    func snapshot(of window: AXUIElement) -> WindowSnapshot? {
        let names = [kAXSubroleAttribute, "AXFullScreen", kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var values: CFArray?
        Metrics.count(.axReads)
        AXUIElementCopyMultipleAttributeValues(window, names, [], &values)
        let list = (values as? [AnyObject]) ?? []
        func value(_ index: Int) -> AnyObject? {
            guard index < list.count else { return nil }
            let item = list[index]
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
        var frame: Rect?
        if let position = value(3), let size = value(4) { frame = Self.rect(position: position, size: size) }
        guard let id = WindowIdentity.id(of: window, pid: pid, frame: frame) else { return nil }
        let traits: (canResize: Bool, hasFullscreenButton: Bool)
        if let known = staticTraits[id] {
            traits = known
        } else {
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
            traits = (settable.boolValue, copy(window, kAXFullScreenButtonAttribute) != nil)
            staticTraits[id] = traits
        }
        return WindowSnapshot(
            id: id,
            subrole: value(0) as? String,
            isFullscreen: (value(1) as? Bool) ?? false,
            isMinimized: (value(2) as? Bool) ?? false,
            frame: frame,
            canResize: traits.canResize,
            hasFullscreenButton: traits.hasFullscreenButton
        )
    }

    public func frame(of id: WindowID, completion: @escaping @Sendable (Rect?) -> Void) {
        queue.async { [self] in completion(elements[id].flatMap(readFrame(of:))) }
    }

    public func focusedWindow(completion: @escaping @Sendable (WindowID?) -> Void) {
        queue.async { [self] in
            guard let window = copy(element, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else {
                completion(nil)
                return
            }
            completion(WindowIdentity.id(of: window as! AXUIElement, pid: pid))
        }
    }

    // MARK: Writing

    /// Writes only what changes: position alone for a move, size alone when the top-left stays,
    /// and size, position, size when both change. Then reads the frame back. Every call's outcome
    /// is reported, so a failed write is never mistaken for the window refusing a size.
    public func setFrame(_ id: WindowID, to rect: Rect, from current: Rect? = nil, completion: @escaping @Sendable (WriteResult) -> Void) {
        queue.async { [self] in
            guard let window = elements[id] else {
                completion(WriteResult(frame: nil, failures: [.invalidElement]))
                return
            }
            var failures: [AXOutcome] = []
            withoutAnimations {
                if let current, current.size == rect.size {
                    failures += write(window, position: rect.origin)
                } else if let current, current.origin == rect.origin {
                    failures += write(window, size: rect.size)
                } else {
                    failures += write(window, size: rect.size)
                    failures += write(window, position: rect.origin)
                    failures += write(window, size: rect.size)
                }
            }
            completion(WriteResult(frame: readFrame(of: window), failures: failures))
        }
    }

    public func setPosition(_ id: WindowID, to point: Point, completion: @escaping @Sendable (WriteResult) -> Void) {
        queue.async { [self] in
            guard let window = elements[id] else {
                completion(WriteResult(frame: nil, failures: [.invalidElement]))
                return
            }
            var failures: [AXOutcome] = []
            withoutAnimations { failures += write(window, position: point) }
            completion(WriteResult(frame: readFrame(of: window), failures: failures))
        }
    }

    public func raise(_ id: WindowID) {
        queue.async { [self] in
            guard let window = elements[id] else { return }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    public func focus(_ id: WindowID) {
        queue.async { [self] in
            guard let window = elements[id] else { return }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: self.pid)?.activate()
            }
        }
    }

    public func setEnhancedUserInterface(_ on: Bool) {
        queue.async { [self] in
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
            enhancedUI = (on, Date())
        }
    }

    /// Fires when the app has `AXEnhancedUserInterface` on and Tessera turns it off around a write,
    /// so the host can journal it and restore it after a crash (audit F11).
    public nonisolated(unsafe) static var enhancedUIToggled: (@Sendable (Int32, Bool) -> Void)?

    // MARK: Helpers

    /// Apps with `AXEnhancedUserInterface` on animate frame changes; turn it off around the
    /// writes, except when VoiceOver runs (turning it off would disturb VoiceOver users).
    private func withoutAnimations(_ body: () -> Void) {
        if enhancedUI == nil || Date().timeIntervalSince(enhancedUI!.readAt) > 5 {
            enhancedUI = ((copy(element, "AXEnhancedUserInterface") as? Bool) ?? false, Date())
        }
        guard enhancedUI!.value, !NSWorkspace.shared.isVoiceOverEnabled else {
            body()
            return
        }
        Self.enhancedUIToggled?(pid, false)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        body()
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Self.enhancedUIToggled?(pid, true)
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        Metrics.count(.axReads)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        record(error)
        return error == .success ? value : nil
    }

    private func readFrame(of window: AXUIElement) -> Rect? {
        guard let position = copy(window, kAXPositionAttribute), let size = copy(window, kAXSizeAttribute) else { return nil }
        return Self.rect(position: position, size: size)
    }

    static func rect(position: AnyObject, size: AnyObject) -> Rect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return Rect(finite: CGRect(origin: point, size: extent))
    }

    private func write(_ window: AXUIElement, size: Size) -> [AXOutcome] {
        Metrics.count(.axWrites)
        var value = CGSize(width: size.width, height: size.height)
        guard let axValue = AXValueCreate(.cgSize, &value) else { return [.failure(-1)] }
        let error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
        record(error)
        return error == .success ? [] : [AXOutcomeMapping.outcome(error)]
    }

    private func write(_ window: AXUIElement, position: Point) -> [AXOutcome] {
        Metrics.count(.axWrites)
        var value = CGPoint(x: position.x, y: position.y)
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return [.failure(-1)] }
        let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue)
        record(error)
        return error == .success ? [] : [AXOutcomeMapping.outcome(error)]
    }
}
