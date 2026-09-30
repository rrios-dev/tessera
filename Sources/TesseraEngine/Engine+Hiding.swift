import Foundation
import TesseraCore
import TesseraPorts

extension Engine {
    // MARK: - Hiding

    /// Where a hidden window goes: past a corner of the primary screen whose far side touches no
    /// other screen, so the window cannot show up on another display (C3).
    func hidingOrigin(for size: Size) -> Point? {
        guard let primary = primaryScreen?.frame else { return nil }
        let others = screens.dropFirst().map(\.frame)
        let candidates = [
            Point(x: primary.maxX - 1, y: primary.maxY - 1),                    // bottom right
            Point(x: primary.minX - size.width + 1, y: primary.maxY - 1),       // bottom left
            Point(x: primary.maxX - 1, y: primary.minY - size.height + 1),      // top right
            Point(x: primary.minX - size.width + 1, y: primary.minY - size.height + 1),
        ]
        return candidates.first { origin in
            let parked = Rect(origin: origin, size: size)
            return !others.contains { $0.intersects(parked) }
        } ?? candidates[0]
    }

    func isParked(_ frame: Rect) -> Bool {
        guard let primary = primaryScreen?.frame, let overlap = frame.intersection(primary) else { return true }
        return overlap.width <= 8 || overlap.height <= 8
    }

    func hide(_ id: WindowID) {
        guard !shuttingDown else { return }
        guard let driver = driver(for: id), let record = world.windows[id] else { return }
        guard !inFlight.contains(id) else {
            deferredRender = true
            return
        }
        guard let current = observed[id] else { return }
        // A window already parked near the corner is not written again (C6).
        if journal.hidden[id] != nil, isParked(current) { return }
        // Hiding moves the window on purpose: the next placement starts a fresh attempt count.
        requested[id] = nil
        if journal.hidden[id] == nil {
            // The journal is written before the window moves (plan §8).
            journal.hidden[id] = Journal.Entry(pid: record.pid, frame: current, bundleID: appInfo[record.pid]?.bundleID)
            saveJournal()
        }
        guard let origin = hidingOrigin(for: current.size) else { return }
        inFlight.insert(id)
        let generation = generation[record.pid]
        driver.setPosition(id, to: origin) { [weak self] result in
            self?.onMain { [weak self] in
                guard let self else { return }
                self.inFlight.remove(id)
                self.renderIfDeferred()
                guard self.generation[record.pid] == generation else { return }
                self.lastWrite[id] = self.port.now()
                if result.permissionLost { self.enterNoPermission(initially: false) }
                if let frame = result.frame { self.observed[id] = frame }
            }
        }
    }

    /// Floating windows come back to the frame they were hidden from.
    func unhide(_ id: WindowID) {
        guard let entry = journal.hidden[id] else { return }
        restore(id, entry: entry) { _ in }
    }

    /// Writes a journaled window back to its original frame and removes the entry only when the
    /// read-back confirms it (audit A1).
    func restore(_ id: WindowID, entry: Journal.Entry, attempt: Int = 0, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let driver = drivers[entry.pid] ?? port.makeDriver(pid: entry.pid)
        guard !inFlight.contains(id) else {
            // A write to it is still under way (hiding it, say): try again once it has landed.
            // Bounded by time, not by a handful of tries: under load a write can take a while.
            let delay = max(timing.echoWindow, 0.05)
            guard Double(attempt) * delay < timing.shutdownWait else {
                completion(false)
                return
            }
            after(delay) { [weak self] in
                guard let self else { return }
                self.restore(id, entry: entry, attempt: attempt + 1, completion: completion)
            }
            return
        }
        inFlight.insert(id)
        let refresh: @Sendable (@escaping @Sendable () -> Void) -> Void = { next in
            // A driver that has not listed its windows yet does not know the element.
            driver.windows { _ in next() }
        }
        refresh {
            driver.setFrame(id, to: entry.frame, from: nil) { [weak self] result in
                self?.onMain { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(id)
                    self.renderIfDeferred()
                    self.lastWrite[id] = self.port.now()
                    if let frame = result.frame { self.observed[id] = frame }
                    let confirmed = result.failures.isEmpty && result.frame.map { self.matches($0, entry.frame) } == true
                    if confirmed, self.journal.hidden[id] == entry {
                        self.journal.hidden[id] = nil
                        self.saveJournal()
                        Metrics.count(.restoresConfirmed)
                    } else if !confirmed {
                        Metrics.count(.restoresPending)
                    }
                    completion(confirmed)
                }
            }
        }
    }

    /// The window is back: same size, and its origin where it was (macOS may nudge it by the
    /// edge clamp).
    func matches(_ frame: Rect, _ original: Rect) -> Bool {
        abs(frame.x - original.x) <= 3 && abs(frame.y - original.y) <= 3
            && abs(frame.width - original.width) <= 3 && abs(frame.height - original.height) <= 3
    }

    /// Journaled windows that are not meant to be hidden any more — left by a crash, by a quit
    /// that could not confirm them, or on a Space the engine could not reach — go back where they
    /// were. Runs at start, on every Space change, app launch, unhide, resume and permission
    /// regained (plan §8 rescue sweep).
    func rescueSweep(reason: String) {
        guard !options.dryRun, !journal.hidden.isEmpty, port.isTrusted(prompt: false) else { return }
        // Entries whose window no longer exists have nothing left to restore.
        let presence = port.presence(of: Array(journal.hidden.keys))
        let gone = journal.hidden.keys.filter { !presence.existing.contains($0) }
        if !gone.isEmpty {
            gone.forEach { journal.hidden[$0] = nil }
            saveJournal()
        }
        let area = tilingArea.map { Renderer.render(world, area: $0) }
        for (id, entry) in journal.hidden where !inFlight.contains(id) {
            // Still hidden on purpose by this run: leave it.
            if status.isActive, area?.hidden.contains(id) == true { continue }
            if status.isActive, world.windows[id] != nil, world.windows[id]?.space != world.activeSpace { continue }
            log.info("rescue (\(reason)): restoring window \(id)", .journal)
            restore(id, entry: entry) { _ in }
        }
    }

    /// Restores every journaled window, waiting at most `timeout` for confirmations.
    func restoreAll(timeout: TimeInterval, completion: @escaping @MainActor @Sendable () -> Void) {
        let entries = journal.hidden
        guard !entries.isEmpty else {
            completion()
            return
        }
        let countdown = Countdown(entries.count, completion)
        for (id, entry) in entries {
            restore(id, entry: entry) { _ in countdown.tick() }
        }
        after(timeout) { countdown.finish() }
    }

    /// "Reordenar todas las ventanas": every ordinary window of this desktop back into the tiling
    /// — hidden groups gathered into the visible one, floated windows tiled again (dialogs and
    /// panels keep floating), backoffs cleared — and Tessera resumed if the user had paused it.
    /// It never pauses (owner, 2026-09-26: the old "gather" paused Tessera and left the windows
    /// looking unmanaged).
    public func retileAll() {
        if status == .paused(.user) { resume() }
        guard status.isActive else {
            notify(Notice("retile-blocked", .warning, L10n.t(
                "Tessera está en pausa por \(statusWord); no puede reordenar ahora.",
                "Tessera is paused (\(statusWord)); it cannot re-tile now."
            )))
            return
        }
        dispatch(.command(.gatherWindows))
        var retiled = 0
        // Every ordinary desktop, not only the visible one: windows floated on another desktop
        // come back too, and tile when that desktop is shown.
        for record in world.windows.values where record.mode == .floating && world.spaces[record.space]?.kind == .desktop
            && (subroles[record.id] ?? WindowSnapshot.standardSubrole) == WindowSnapshot.standardSubrole {
            dispatch(.command(.setFloating(record.id, false)))
            retiled += 1
        }
        requested.removeAll()
        backoff.removeAll()
        writeLog.removeAll()
        refusedTarget.removeAll()
        positionCorrected.removeAll()
        rescueSweep(reason: "retile")
        notify(Notice("retiled", .info, retiled == 0
            ? L10n.t("Ventanas reordenadas.", "Windows re-tiled.")
            : L10n.t("Ventanas reordenadas: \(retiled) vuelven al mosaico.", "Windows re-tiled: \(retiled) back in the tiling.")))
        scheduleRender()
    }

    // MARK: - First contact (E11)

    func captureOriginal(_ id: WindowID, pid: Int32, frame: Rect) {
        guard originalLayout.frames[id] == nil, journal.hidden[id] == nil, !isParked(frame),
              port.now().timeIntervalSince(startedAt) < timing.revertWindow else { return }
        originalLayout.frames[id] = frame
        originalLayout.pids[id] = pid
    }

    var canRevert: Bool {
        !originalLayout.frames.isEmpty && port.now().timeIntervalSince(startedAt) < timing.revertWindow && !options.dryRun
    }

    /// Pauses and puts every window back where it was when Tessera started.
    public func revertToOriginalLayout() {
        guard canRevert else { return }
        if status.isActive { setStatus(.paused(.user)); registerKeymap() }
        var reverted = 0
        for (id, frame) in originalLayout.frames {
            guard let pid = originalLayout.pids[id] else { continue }
            let entry = Journal.Entry(pid: pid, frame: frame)
            if journal.hidden[id] != nil { journal.hidden[id] = entry }
            reverted += 1
            restore(id, entry: entry) { _ in }
        }
        notify(Notice("reverted", .info, L10n.t(
            "\(reverted) ventanas vuelven a como estaban. Tessera queda en pausa.",
            "\(reverted) windows go back to how they were. Tessera stays paused."
        )))
    }
}

/// Calls its completion once: when every tick arrived, or when `finish` is called first.
@MainActor
final class Countdown: Sendable {
    private var remaining: Int
    private var completion: (@MainActor @Sendable () -> Void)?

    init(_ count: Int, _ completion: @escaping @MainActor @Sendable () -> Void) {
        remaining = count
        self.completion = completion
    }

    func tick() {
        remaining -= 1
        if remaining <= 0 { finish() }
    }

    func finish() {
        let pending = completion
        completion = nil
        pending?()
    }
}
