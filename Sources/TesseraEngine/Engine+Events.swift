import Foundation
import TesseraCore
import TesseraPorts

extension Engine {
    /// Every notification from macOS arrives here, on the main actor.
    func handle(_ event: SystemEvent) {
        switch event {
        case .hotkeyPressed(let index):
            pressHotkey(index)
            return
        case .modifiersChanged(let flags):
            modifiersChanged(flags)
            return
        case .voiceOverChanged(let enabled):
            voiceOverChanged(enabled)
            return
        case .mouseDragged(let point):
            mouseDragged(to: point)
            return
        default:
            break
        }
        // Without the permission (or in safe mode) nothing is managed; only what keeps the
        // status right matters.
        switch status {
        case .noPermission, .starting:
            return
        case .safeMode:
            if case .activeSpaceChanged = event { rescueSweep(reason: "space change") }
            return
        default:
            break
        }
        noteActivity()

        switch event {
        case .window(let windowEvent):
            handle(windowEvent)
        case .appLaunched(let app):
            if isManaged(app) { adopt(app) }
            rescueSweep(reason: "app launch")
            preflight()
        case .appTerminated(let pid):
            release(pid: pid)
            preflight()
        case .appVisibilityChanged(let pid):
            if drivers[pid] != nil, let app = port.runningApps().first(where: { $0.pid == pid }) { appInfo[pid] = app }
            rescan(pid)
            rescueSweep(reason: "unhide")
        case .appActivated(let pid):
            Metrics.count(.notifyApp)
            log.debug("app \(pid) activated")
            // Focus the user moved elsewhere cancels a focus Tessera still owes (C8).
            if let pending = pendingFocus, world.windows[pending.id]?.pid != pid { pendingFocus = nil }
            refreshFocus()
        case .activeSpaceChanged:
            scheduleSpaceChecks()
        case .screensChanged:
            refreshScreen(force: false)
            preflight()
        case .mouseDown:
            log.debug("mouse down")
            mouseIsDown = true
            draggedByUser.removeAll()
            dragStart.removeAll()
        case .mouseUp(let point):
            mouseIsDown = false
            finishDrag(at: point)
        case .didWake:
            refreshScreen(force: false)
            registerKeymap()
            scheduleSpaceChecks()
        case .hotkeyPressed, .modifiersChanged, .voiceOverChanged, .mouseDragged:
            break
        }
    }

    func handle(_ event: WindowEvent) {
        switch event {
        case .windowCreated: Metrics.count(.notifyCreated)
        case .windowDestroyed: Metrics.count(.notifyDestroyed)
        case .focusChanged: Metrics.count(.notifyFocus)
        case .windowChanged: Metrics.count(.notifyChanged)
        case .windowMoved: Metrics.count(.notifyMoved)
        }
        switch event {
        case .windowCreated(let pid):
            port.observeWindows(pid: pid)
            rescan(pid)
        case .windowDestroyed(let pid, let window):
            if let window, world.windows[window] != nil {
                // The app said this very window is gone: free its tile now.
                forgetWindow(window)
            }
            rescan(pid)
            auditSoon()
        case .focusChanged(let pid):
            // Closing a window without destroying it sends no destroy notification, but it moves
            // the app's focus: re-read the app so the vanished window gives its tile back.
            rescan(pid)
            refreshFocus()
            auditSoon()
        case .windowChanged(let pid):
            rescan(pid)
        case .windowMoved(let pid, let window):
            // Moves and resizes never change which windows exist: read only this window, and not
            // at all when it is the echo of Tessera's own write.
            guard let window, world.windows[window] != nil, let driver = drivers[pid] else {
                rescan(pid)
                return
            }
            if inFlight.contains(window) || isEcho(window) { return }
            let generation = generation[pid]
            driver.frame(of: window) { [weak self] frame in
                guard let frame else { return }
                self?.onMain { [weak self] in
                    guard let self, self.generation[pid] == generation else { return }
                    self.noteObserved(window, frame: frame)
                }
            }
        }
    }

    func isEcho(_ window: WindowID) -> Bool {
        guard let written = lastWrite[window] else { return false }
        return port.now().timeIntervalSince(written) < timing.echoWindow
    }

    /// Anything the user or an app did: audits run every 2 s for a while, then every 30 s.
    func noteActivity() {
        lastActivity = port.now()
        if auditInterval > timing.fastAudit, status.isActive { scheduleAuditTimer(fast: true) }
    }

    func scheduleAuditTimer(fast: Bool) {
        auditTimer?.cancel()
        auditInterval = fast ? timing.fastAudit : timing.slowAudit
        auditTimer = Repeater(interval: auditInterval) { [weak self] in self?.auditTick() }
    }

    func auditTick() {
        Metrics.count(.auditTicks)
        // Revocation is noticed here even when no write happens to fail (audit E3).
        guard port.isTrusted(prompt: false) else {
            if status != .noPermission { enterNoPermission(initially: false) }
            return
        }
        preflight()
        guard status.isActive else { return }
        // Space and screen changes are event-driven; this is only the safety net for a lost one.
        if port.spacesAvailable, let active = port.activeSpace(), active != world.activeSpace {
            spaceMayHaveChanged()
        }
        audit()
        checkAlignment()
        if auditInterval <= timing.fastAudit {
            discoverMissed()
            if port.now().timeIntervalSince(lastActivity) > timing.idleAfter { scheduleAuditTimer(fast: false) }
        } else {
            rescueSweep(reason: "audit")
        }
        if canRevert == false, lastUIState?.canRevert == true { publishUI() }
    }
}
