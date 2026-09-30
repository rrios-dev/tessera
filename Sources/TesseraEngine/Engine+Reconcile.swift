import Foundation
import os
public import TesseraCore
import TesseraPorts

/// Intervals for Instruments (audit F4): a render, and each write from request to read-back.
let signposter = OSSignposter(subsystem: "dev.rrios.tessera", category: "reconcile")

extension Engine {
    // MARK: - Commands

    public func execute(_ command: Command) {
        noteActivity()
        guard status.isActive else {
            log.info("command \(command) ignored while \(status)")
            return
        }
        if nativeWorkspaces, handleNatively(command) { return }
        let before = world.focused
        dispatch(.command(command))
        // Activate the focused window when focus moved, or when the command changes what is in
        // front: raising inside its own app is not enough if another app's window is on top.
        let reordersFront: Bool
        switch command {
        case .toggleFullscreen, .layout, .focus, .focusWindow, .move, .swapWindows: reordersFront = true
        default: reordersFront = false
        }
        if let focused = world.focused, focused != before || reordersFront { pendingFocus = (focused, port.now()) }
        render()
    }

    // MARK: - Rendering

    func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.renderScheduled = false
                self?.render()
            }
        }
    }

    func render() {
        Metrics.count(.renders)
        let interval = signposter.beginInterval("render")
        defer { signposter.endInterval("render", interval) }
        publishUI()
        guard status.isActive, !shuttingDown, let area = tilingArea else { return }
        let render = Renderer.render(world, area: area)
        explainOverflow(render)
        guard !options.dryRun else { return }
        if !render.autoFloated.isEmpty, !resolvingDrop, !(mouseIsDown && !draggedByUser.isEmpty) {
            floatWhatDoesNotFit(render)
            return
        }
        // Never fight the user's hand: placement waits until the drop is resolved.
        if resolvingDrop || (mouseIsDown && !draggedByUser.isEmpty) { return }

        for (id, target) in render.frames { apply(target, to: id) }
        for id in render.hidden { hide(id) }
        // Floating windows of the visible workspace come back to where they were hidden from.
        if let workspace = world.activeWorkspace {
            for id in workspace.floating where journal.hidden[id] != nil { unhide(id) }
        }

        if render.front != lastFront {
            lastFront = render.front
            for id in render.front.reversed() { driver(for: id)?.raise(id) }
        }
        if let pending = pendingFocus {
            if port.now().timeIntervalSince(pending.at) > timing.pendingFocusTTL {
                // Could not be honoured in time: dropping it beats stealing focus later (C8).
                pendingFocus = nil
            } else if render.frames[pending.id] != nil || world.activeWorkspace?.floating.contains(pending.id) == true {
                pendingFocus = nil
                lastFocusRequest = (pending.id, port.now())
                driver(for: pending.id)?.focus(pending.id)
            }
        }
    }

    /// Windows that do not fit become ordinary floating windows, centred once at the size they
    /// insist on, and then belong to the user: moved, resized and minimised freely, back in the
    /// tiling with ⌃⌥⇧Space.
    func floatWhatDoesNotFit(_ render: Render) {
        let placements = render.autoFloated.compactMap { id in render.frames[id].map { (id, $0) } }
        for (id, _) in placements { dispatch(.command(.setFloating(id, true))) }
        for (id, frame) in placements {
            guard let driver = driver(for: id), !inFlight.contains(id) else { continue }
            inFlight.insert(id)
            driver.setFrame(id, to: frame, from: observed[id]) { [weak self] result in
                self?.onMain { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(id)
                    self.lastWrite[id] = self.port.now()
                    if let placed = result.frame { self.observed[id] = placed }
                }
            }
        }
        let names = placements.compactMap { world.windows[$0.0].flatMap { appInfo[$0.pid]?.executableName } }
        notify(Notice("overflow-float", .info, L10n.t(
            "No caben todas: \(names.joined(separator: ", ")) flota centrada. Muévela o redimensiónala a tu gusto; ⌃⌥⇧Espacio la devuelve al mosaico.",
            "They do not all fit: \(names.joined(separator: ", ")) floats, centred. Move or resize it as you like; ⌃⌥⇧Space puts it back in the tiling."
        )))
    }

    /// One notice when a workspace starts overflowing, so windows drawn on top of each other are
    /// never a silent mystery (audit D4).
    func explainOverflow(_ render: Render) {
        let flags = (render.plan.overflowed, render.plan.reflowed, render.autoFloated.count)
        defer { lastPlanFlags = flags }
        guard flags != lastPlanFlags else { return }
        if flags.2 > 0 {
            return
        } else if flags.0 > lastPlanFlags.overflowed {
            notify(Notice("overflow", .info, render.plan.stacked > 0
                ? L10n.t("No caben ni en fila ni en columna: apiladas.", "They fit neither side by side nor stacked: drawn on top of each other.")
                : L10n.t("No caben ni en fila ni en columna: en acordeón.", "They fit neither side by side nor stacked: shown as an accordion.")))
        } else if flags.1 > lastPlanFlags.reflowed {
            notify(Notice("reflow", .info, L10n.t("No caben lado a lado: apiladas.", "They do not fit side by side: stacked instead."), onScreen: false))
        }
    }

    // MARK: - Applying and reading back

    func apply(_ target: Rect, to id: WindowID) {
        guard let driver = driver(for: id), let pid = world.windows[id]?.pid else { return }
        guard !inFlight.contains(id) else {
            deferredRender = true
            return
        }
        let now = port.now()
        if let pause = backoff[id], now < pause.until { return }
        if observed[id] == target {
            confirmPlaced(id)
            return
        }
        var attempt = requested[id]
        if attempt?.target != target { attempt = (target, 0) }
        // The same target refused twice: accept what the window does (plan §4.4, terminal state).
        guard attempt!.attempts < 2 else {
            if warnedOnce.insert("terminal-\(id)-\(target)").inserted, let name = appInfo[pid]?.executableName {
                notify(Notice("window-keeps-size", .info, L10n.t(
                    "Una ventana de \(name) no acepta el tamaño exacto; se queda con el que prefiere dentro de su hueco.",
                    "A \(name) window does not take the exact size; it keeps the one it prefers inside its tile."
                ), onScreen: false))
            }
            return
        }
        // A window that keeps refusing what it is given is in a loop, whatever the cause: back
        // off (C2). Only refusals count: a burst of commands legitimately writes a window often.
        // Only refusals of this very target count: while a layout is changing (apps opening,
        // a game launching) a slow app answers late many times, which is not a loop (found live:
        // the browser was backed off in a half-applied size).
        let refusals = (writeLog[id] ?? []).filter { now.timeIntervalSince($0.at) < timing.writeWindow }
        writeLog[id] = refusals
        guard refusals.filter({ $0.target == target }).count < timing.writeLimit else {
            enterBackoff(id)
            return
        }
        attempt!.attempts += 1
        requested[id] = attempt
        inFlight.insert(id)
        log.debug("write \(id) → \(target) (attempt \(attempt!.attempts), mouse \(mouseIsDown ? "down" : "up"))", .ax)
        let generation = generation[pid]
        // The first attempt writes only what changed; a retry writes everything.
        let writeInterval = signposter.beginInterval("write", id: signposter.makeSignpostID(), "window \(id)")
        driver.setFrame(id, to: target, from: attempt!.attempts == 1 ? observed[id] : nil) { [weak self] result in
            self?.onMain { [weak self] in
                signposter.endInterval("write", writeInterval)
                guard let self else { return }
                self.inFlight.remove(id)
                self.renderIfDeferred()
                guard self.generation[pid] == generation, self.world.windows[id] != nil else { return }
                self.lastWrite[id] = self.port.now()
                self.written(id, target: target, result: result, pid: pid)
            }
        }
    }

    func written(_ id: WindowID, target: Rect, result: WriteResult, pid: Int32) {
        if result.permissionLost {
            enterNoPermission(initially: false)
            return
        }
        if let frame = result.frame { observed[id] = frame }
        guard result.failures.isEmpty, let frame = result.frame else {
            // A failed or timed-out write says nothing about the window's limits: learn nothing,
            // let the attempt count bound the retries (C1).
            Metrics.count(.writeFailures)
            log.info("write to \(id) failed: \(result.failures)", .ax)
            if result.failures.contains(.invalidElement) { rescan(pid) }
            // A busy app gets one more try shortly, instead of waiting for the next event.
            if (requested[id]?.attempts ?? 2) < 2 {
                after(max(timing.settleRead * 2, 0.05)) { [weak self] in self?.scheduleRender() }
            }
            return
        }
        if frame == target {
            factCandidates[id] = nil
            refusedTarget[id] = nil
            confirmPlaced(id)
            checkContradiction(id, frame: frame)
            return
        }
        writeLog[id, default: []].append((port.now(), target))
        refusedTarget[id] = target
        if let usable = primaryScreen?.usableArea {
            switch edgeClamp.observe(target: target, result: frame, current: tilingArea ?? usable, pid: pid) {
            case .learned:
                log.notice("learned edge clamp \(edgeClamp.insets)")
                notify(Notice("edge-clamp", .info, L10n.t(
                    "macOS deja las ventanas a \(edgeClamp.insets.bottom) pt del Dock: Tessera ajusta el área para que no quede hueco.",
                    "macOS keeps windows \(edgeClamp.insets.bottom) pt off the Dock: Tessera adjusts the area so no gap is left."
                ), onScreen: false))
                if let primary = primaryScreen {
                    edgeClampStore.insets[EdgeClampStore.key(frame: primary.frame, usable: primary.usableArea)] = edgeClamp.insets
                    if !options.dryRun { try? SecureFile.writeJSON(edgeClampStore, to: paths.edgeClamp) }
                }
                requested.removeAll()
                scheduleRender()
                return
            case .suspected, .none:
                break
            }
        }
        // Read again once the window has settled: an app still animating or busy answers with an
        // intermediate frame, and learning from that sticks a wrong limit on the window (C1).
        let generation = generation[pid]
        after(timing.settleRead) { [weak self] in
            guard let self, let driver = self.drivers[pid], self.generation[pid] == generation else { return }
            driver.frame(of: id) { [weak self] settled in
                self?.onMain { [weak self] in
                    guard let self, self.generation[pid] == generation, self.world.windows[id] != nil, !self.inFlight.contains(id) else { return }
                    guard let settled else { return }
                    self.observed[id] = settled
                    let factsBefore = self.world.facts[id]
                    if settled == frame {
                        self.learn(id, requested: target, observed: settled)
                    }
                    let stillLearning = self.factCandidates[id] != nil || self.world.facts[id] != factsBefore
                    if settled == frame, settled.size != target.size, !stillLearning, Self.keepsOwnSize(settled, in: target) {
                        // A stable answer just short of the tile with nothing left to learn (a
                        // terminal's grid): the window keeps a size of its own. Retrying only moves
                        // it around, so this is the terminal state, and its position is put back
                        // at the tile's corner (snapping can land it off, even outside the area).
                        self.requested[id] = (target, 2)
                        self.correctPosition(id, to: target, pid: pid)
                        return
                    }
                    // Something else moved it meanwhile: one more try, bounded by the attempts.
                    if settled != target { self.scheduleRender() }
                }
            }
        }
    }

    /// A window that stopped a grid cell or less short of its tile, within a few points of its
    /// corner, keeps its own size; one far from its tile simply has not been placed yet (an app
    /// still launching ignores the first write) and is written again.
    static func keepsOwnSize(_ frame: Rect, in target: Rect) -> Bool {
        abs(frame.x - target.x) <= 4 && abs(frame.y - target.y) <= 4
            && (0...24).contains(target.width - frame.width) && (0...24).contains(target.height - frame.height)
            && frame.size != target.size
    }

    /// Position-only writes for a window in the terminal "own size" state, at most twice per target.
    func correctPosition(_ id: WindowID, to target: Rect, pid: Int32) {
        guard observed[id]?.origin != target.origin, !inFlight.contains(id), let driver = drivers[pid] else { return }
        var state: (target: Rect, count: Int) = positionCorrected[id].flatMap { $0.target == target ? $0 : nil } ?? (target: target, count: 0)
        guard state.count < 2 else { return }
        state.count += 1
        positionCorrected[id] = state
        inFlight.insert(id)
        driver.setPosition(id, to: target.origin) { [weak self] result in
            self?.onMain { [weak self] in
                guard let self else { return }
                self.inFlight.remove(id)
                self.lastWrite[id] = self.port.now()
                if let corrected = result.frame { self.observed[id] = corrected }
            }
        }
    }

    func renderIfDeferred() {
        guard deferredRender else { return }
        deferredRender = false
        scheduleRender()
    }

    /// The window is where the layout wants it: a restore it stood for is confirmed (A1).
    func confirmPlaced(_ id: WindowID) {
        alignment[id] = nil
        if journal.hidden.removeValue(forKey: id) != nil {
            Metrics.count(.restoresConfirmed)
            saveJournal()
        }
    }

    func enterBackoff(_ id: WindowID) {
        let interval = min(timing.backoffMax, backoff[id].map { $0.interval * 2 } ?? timing.backoffStart)
        backoff[id] = (port.now().addingTimeInterval(interval), interval)
        writeLog[id] = nil
        requested[id] = nil
        Metrics.count(.writeBackoffs)
        log.notice("window \(id) keeps refusing its frame; left as it is for \(Int(interval)) s")
        if warnedOnce.insert("backoff-\(id)").inserted {
            let name = world.windows[id].flatMap { appInfo[$0.pid]?.executableName } ?? "?"
            notify(Notice("window-refuses", .warning, L10n.t(
                "Una ventana de \(name) no acepta su tamaño: Tessera la deja como está.",
                "A \(name) window does not accept its size: Tessera leaves it as it is."
            ), onScreen: false))
        }
    }

    /// Minimums and maximums are learned from what a window refused, only after the same answer
    /// twice in a row (plan §4.3), and never from what the display forced (C1).
    func learn(_ id: WindowID, requested target: Rect, observed result: Rect) {
        guard result.size != target.size else {
            factCandidates[id] = nil
            return
        }
        // An app still opening a window sizes it itself; what it refuses now says nothing about
        // its limits. Look again once it has settled (owner, 2026-09-26: a launching window
        // taught a 1225-point minimum and pushed the layout into overflow).
        if let seen = firstSeen[id], port.now().timeIntervalSince(seen) < timing.openingGrace {
            // Not written again meanwhile, and this refusal does not count towards the loop
            // guard: rewriting a window that is still opening only piles up refusals.
            requested[id] = (target, 2)
            if writeLog[id]?.isEmpty == false { writeLog[id]?.removeLast() }
            after(timing.openingGrace) { [weak self] in
                guard let self, self.world.windows[id] != nil else { return }
                self.requested[id] = nil
                self.scheduleRender()
            }
            return
        }
        let screen = primaryScreen?.frame
        let facts = world.facts[id] ?? WindowFacts()
        var candidate = WindowFacts(minSize: facts.minSize, maxSize: facts.maxSize, quantum: facts.quantum)
        var minimum = candidate.minSize ?? Size(width: 0, height: 0)
        var maximum = candidate.maxSize
        if result.width > target.width + 1 { minimum.width = max(minimum.width, result.width) }
        if result.height > target.height + 1 { minimum.height = max(minimum.height, result.height) }
        // macOS shrinks a window that would cross the display edge: that is the display's limit,
        // not the window's.
        let displayLimited = screen.map { !$0.contains(target) || result.maxX >= $0.maxX - 1 || result.maxY >= $0.maxY - 1 } ?? true
        if !displayLimited {
            // Shortfalls smaller than a grid cell are snapping slack, not a maximum.
            if result.width < target.width - 24 { maximum = Size(width: result.width, height: maximum?.height ?? 1 << 30) }
            if result.height < target.height - 24 { maximum = Size(width: maximum?.width ?? 1 << 30, height: result.height) }
        }
        candidate.minSize = minimum == Size(width: 0, height: 0) ? nil : minimum
        candidate.maxSize = maximum
        guard candidate != facts else { return }
        if factCandidates[id] == candidate {
            factCandidates[id] = nil
            requested[id] = nil
            Metrics.count(.factsLearned)
            log.info("learned facts for \(id): \(candidate)")
            dispatch(.factsLearned(id, candidate))
            rememberFacts(candidate, for: id)
        } else {
            factCandidates[id] = candidate
            requested[id]?.attempts = 0
            scheduleRender()
        }
    }

    /// A window observed smaller than its learned minimum or larger than its maximum proves the
    /// fact wrong; two such observations drop it (plan §4.3, C1).
    func checkContradiction(_ id: WindowID, frame: Rect) {
        guard let facts = world.facts[id] else { return }
        let belowMinimum = facts.minSize.map { frame.width < $0.width - 1 || frame.height < $0.height - 1 } ?? false
        let aboveMaximum = facts.maxSize.map { frame.width > $0.width + 1 || frame.height > $0.height + 1 } ?? false
        guard belowMinimum || aboveMaximum else { return }
        contradictions[id, default: 0] += 1
        guard contradictions[id]! >= 2 else { return }
        contradictions[id] = nil
        Metrics.count(.factsInvalidated)
        log.info("facts for \(id) contradicted twice; forgotten")
        dispatch(.factsLearned(id, .flexible))
        rememberFacts(.flexible, for: id)
    }

    func noteObserved(_ id: WindowID, frame: Rect) {
        // A read taken while Tessera was writing, or just after, shows an intermediate frame.
        if inFlight.contains(id) || isEcho(id) { return }
        let previous = observed[id]
        observed[id] = frame
        if previous != frame { checkContradiction(id, frame: frame) }
        if mouseIsDown, let previous, previous != frame, let record = world.windows[id],
           record.mode == .tiled || (record.mode == .floating && record.userFloating == true) {
            if draggedByUser.insert(id).inserted { dragStart[id] = previous }
            return
        }
        guard previous != nil, previous != frame, let target = requested[id]?.target, frame != target else { return }
        // Something outside Tessera moved a tiled window: put it back, within a drift budget.
        let now = port.now()
        let recent = (driftBudget[id] ?? []).filter { now.timeIntervalSince($0) < timing.driftWindow }
        guard recent.count < timing.driftLimit else { return }
        driftBudget[id] = recent + [now]
        requested[id]?.attempts = 0
        // Read the app again before correcting: a window being minimised or hidden moves too,
        // and writing it back would cancel the minimise (owner, 2026-09-26).
        if let pid = world.windows[id]?.pid { rescan(pid) }
        after(max(timing.rescanCoalesce * 4, 0.25)) { [weak self] in
            guard let self, self.world.windows[id]?.mode == .tiled else { return }
            self.scheduleRender()
        }
    }

    // MARK: - Runtime check that windows landed (I9, C6)

    /// On the audit tick, every settled window of the active workspace is compared with its
    /// target as the window server draws it; a mismatch gets one more write, a few times at most.
    func checkAlignment() {
        guard status.isActive, !mouseIsDown, !resolvingDrop, let area = tilingArea else { return }
        let render = Renderer.render(world, area: area)
        let now = port.now()
        let candidates = render.frames.keys.filter { id in
            !inFlight.contains(id) && backoff[id].map { now >= $0.until } ?? true
                && lastWrite[id].map { now.timeIntervalSince($0) >= timing.alignmentCalm } ?? true
        }
        guard !candidates.isEmpty else { return }
        Metrics.count(.alignmentChecks)
        let drawn = port.bounds(of: candidates)
        for id in candidates {
            guard let target = render.frames[id], let frame = drawn[id] else { continue }
            observed[id] = frame
            guard frame != target else {
                alignment[id] = nil
                confirmPlaced(id)
                continue
            }
            // A window that refused this very target (a size grid, a limit) is in a terminal
            // state: rewriting it only nudges it around (found live).
            if refusedTarget[id] == target {
                // Terminal: its size stays, but a drifted corner is put back.
                if let pid = world.windows[id]?.pid, Self.keepsOwnSize(frame, in: target) { correctPosition(id, to: target, pid: pid) }
                continue
            }
            var state = alignment[id].flatMap { $0.target == target ? $0 : nil } ?? (target, 0, .distantPast)
            guard state.retries < timing.alignmentMaxRetries, now.timeIntervalSince(state.last) >= timing.alignmentRetryAfter else { continue }
            state.retries += 1
            state.last = now
            alignment[id] = state
            Metrics.count(.alignmentRetries)
            log.info("window \(id) drawn at \(frame), expected \(target): retrying (\(state.retries)/\(timing.alignmentMaxRetries))")
            requested[id] = nil
            scheduleRender()
        }
    }

    /// macOS keeps a sliver of every window on screen (it will not let one go fully past the
    /// edge): a hidden window may show this many points in one dimension (plan I7 remnant k).
    static let hiddenRemnant = 2

    /// Invariants only the engine can check: I7 (hidden windows off screen), I9 (settled windows
    /// where planned), I11 (every window Tessera hid is journaled).
    func runtimeViolations(render: Render) -> [Invariants.Violation] {
        var result: [Invariants.Violation] = []
        guard let screen = primaryScreen else { return result }
        let now = port.now()
        let visible = screen.frame
        for id in render.hidden {
            guard let frame = port.bounds(of: [id])[id] ?? observed[id], journal.hidden[id] != nil || world.windows[id] != nil else { continue }
            if let overlap = frame.intersection(visible), min(overlap.width, overlap.height) > Self.hiddenRemnant {
                result.append(.init("I7", "hidden window \(id) shows \(overlap.width)×\(overlap.height) points"))
            }
            if journal.hidden[id] == nil, !inFlight.contains(id) { result.append(.init("I11", "hidden window \(id) is not journaled")) }
        }
        let drawn = port.bounds(of: Array(render.frames.keys))
        for (id, target) in render.frames {
            let settled = !inFlight.contains(id) && lastWrite[id].map { now.timeIntervalSince($0) >= timing.alignmentCalm } ?? true
            guard settled, backoff[id] == nil, (requested[id]?.attempts ?? 0) < 2 else { continue }
            if let frame = drawn[id], frame != target { result.append(.init("I9", "window \(id) drawn at \(frame), planned \(target)")) }
        }
        return result
    }
}
