import ApplicationServices
import Foundation
import TesseraCore
import TesseraPorts

/// Hosts every app's `AXObserver` run-loop source on one dedicated thread. That thread never
/// talks to an app: creating observers and subscribing windows happens on each app's own queue
/// (audit C7), so one hung app cannot delay another app's notifications. Callbacks only forward
/// a small event to the engine.
final class AXObserverHub: @unchecked Sendable {
    typealias Handler = @Sendable (WindowEvent) -> Void

    private let handler: Handler
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var observers: [Int32: AXObserver] = [:]
    private var windowIDs: [AXUIElement: (pid: Int32, id: WindowID)] = [:]

    static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXMovedNotification, kAXResizedNotification,
    ]

    init(handler: @escaping Handler) {
        self.handler = handler
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // A source keeps the run loop alive before any observer is added.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(runLoop, keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "tessera.ax-observers"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func isObserving(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observers[pid] != nil
    }

    /// Creates the app's observer. Call on the app's queue: it sends messages to the app.
    /// - Returns: false while the app is still launching and refuses registration.
    func register(pid: Int32, app: AXUIElement) -> Bool {
        guard !isObserving(pid) else { return true }
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &observer) == .success, let observer else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let created = AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon)
        guard created == .success || created == .notificationAlreadyRegistered else { return false }
        for name in Self.appNotifications where name != kAXWindowCreatedNotification {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        lock.lock()
        observers[pid] = observer
        lock.unlock()
        perform { CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        return true
    }

    /// Subscribes windows not subscribed yet. Call on the app's queue.
    func subscribe(pid: Int32, windows: [(element: AXUIElement, id: WindowID)]) {
        lock.lock()
        let observer = observers[pid]
        let fresh = windows.filter { windowIDs[$0.element] == nil }
        for window in fresh { windowIDs[window.element] = (pid, window.id) }
        lock.unlock()
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in fresh {
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, window.element, name as CFString, refcon)
            }
        }
    }

    func forget(pid: Int32) {
        lock.lock()
        windowIDs = windowIDs.filter { $0.value.pid != pid }
        let observer = observers.removeValue(forKey: pid)
        lock.unlock()
        guard let observer else { return }
        perform { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode) }
    }

    private func perform(_ body: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(runLoop)
    }

    private func windowID(_ element: AXUIElement, remove: Bool) -> WindowID? {
        lock.lock()
        defer { lock.unlock() }
        return remove ? windowIDs.removeValue(forKey: element)?.id : windowIDs[element]?.id
    }

    private static let callback: AXObserverCallback = { _, element, name, refcon in
        guard let refcon else { return }
        let hub = Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
        var pid: Int32 = 0
        AXUIElementGetPid(element, &pid)
        let event: WindowEvent
        switch name as String {
        case kAXWindowCreatedNotification: event = .windowCreated(pid: pid)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification: event = .focusChanged(pid: pid)
        case kAXUIElementDestroyedNotification: event = .windowDestroyed(pid: pid, window: hub.windowID(element, remove: true))
        case kAXMovedNotification, kAXResizedNotification: event = .windowMoved(pid: pid, window: hub.windowID(element, remove: false))
        default: event = .windowChanged(pid: pid)
        }
        hub.handler(event)
    }
}
