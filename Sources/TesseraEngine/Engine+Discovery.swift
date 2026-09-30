import Foundation
import TesseraCore
import TesseraPorts

extension Engine {
    // MARK: - Adoption

    func isManaged(_ app: RunningApp) -> Bool {
        guard app.isRegular, app.pid != getpid() else { return false }
        if let only = options.onlyPIDs { return only.contains(app.pid) }
        // The test app never belongs to the owner's engine (audit A2).
        if app.executableName == "DummyWindowApp" { return false }
        if let bundle = app.bundleID {
            if options.excludedBundleIDs.contains(bundle) || localConfig.exclude.contains(bundle) { return false }
        }
        return true
    }

    func adopt(_ app: RunningApp, scan: Bool = true) {
        appInfo[app.pid] = app
        guard drivers[app.pid] == nil else { return }
        generationCounter += 1
        generation[app.pid] = generationCounter
        drivers[app.pid] = port.makeDriver(pid: app.pid)
        port.observe(pid: app.pid)
        if scan { rescan(app.pid) }
    }

    /// The app quit: forget its windows through the one path that cleans every map (C5).
    func release(pid: Int32) {
        generationCounter += 1
        generation[pid] = generationCounter
        guard drivers.removeValue(forKey: pid) != nil else { return }
        port.stopObserving(pid: pid)
        appInfo[pid] = nil
        rescanScheduled.remove(pid)
        lastUnresponsiveScan[pid] = nil
        for record in world.windows.values where record.pid == pid { forgetWindow(record.id) }
        // Hidden windows of a quit app no longer exist; nothing to restore.
        let before = journal.hidden.count
        journal.hidden = journal.hidden.filter { $0.value.pid != pid }
        if journal.hidden.count != before { saveJournal() }
    }

    /// Frees everything Tessera kept about a window.
    func forgetWindow(_ id: WindowID) {
        dispatch(.windowGone(id))
        observed[id] = nil
        requested[id] = nil
        lastWrite[id] = nil
        writeLog[id] = nil
        backoff[id] = nil
        driftBudget[id] = nil
        factCandidates[id] = nil
        contradictions[id] = nil
        alignment[id] = nil
        refusedTarget[id] = nil
        positionCorrected[id] = nil
        firstSeen[id] = nil
        rejected.remove(id)
        wasOnScreen.remove(id)
        draggedByUser.remove(id)
        subroles[id] = nil
        inFlight.remove(id)
        if pendingFocus?.id == id { pendingFocus = nil }
        if journal.hidden.removeValue(forKey: id) != nil { saveJournal() }
    }

    // MARK: - Scanning

    func rescanAll() { drivers.keys.sorted().forEach(rescan) }

    /// Re-reads an app's windows; coalesced so a burst of notifications costs one scan.
    func rescan(_ pid: Int32) {
        guard drivers[pid] != nil, rescanScheduled.insert(pid).inserted else { return }
        after(timing.rescanCoalesce) { [weak self] in self?.performScan(pid) }
    }

    func performScan(_ pid: Int32) {
        rescanScheduled.remove(pid)
        guard let driver = drivers[pid] else { return }
        // An app that stopped answering is asked again only every few seconds, so its timeouts
        // do not queue up behind each other (C7).
        if driver.isUnresponsive {
            let now = port.now()
            if let last = lastUnresponsiveScan[pid], now.timeIntervalSince(last) < timing.unresponsiveRetry { return }
            lastUnresponsiveScan[pid] = now
        }
        Metrics.count(.rescans)
        let isHidden = appInfo[pid]?.isHidden ?? false
        let generation = generation[pid]
        driver.windows { [weak self] snapshots in
            self?.onMain { [weak self] in
                guard let self, self.generation[pid] == generation else { return }
                guard let snapshots else {
                    self.log.info("pid \(pid) did not answer the window query", .ax)
                    if driver.isUnresponsive, self.warnedOnce.insert("unresponsive-\(pid)").inserted {
                        let name = self.appInfo[pid]?.executableName ?? "pid \(pid)"
                        self.notify(Notice("app-unresponsive", .warning, L10n.t(
                            "\(name) no responde: sus ventanas se ordenarán cuando vuelva.",
                            "\(name) is not responding: its windows are tiled when it answers again."
                        ), onScreen: false))
                    }
                    return
                }
                self.lastUnresponsiveScan[pid] = nil
                self.absorb(snapshots, pid: pid, appHidden: isHidden)
            }
        }
    }

    func absorb(_ snapshots: [WindowSnapshot], pid: Int32, appHidden: Bool) {
        // Every window needs its own destroy subscription for its tile to be freed instantly.
        if snapshots.contains(where: { world.windows[$0.id] == nil }) { port.observeWindows(pid: pid) }
        log.debug("scan pid \(pid): \(snapshots.map { "\($0.id):\($0.subrole ?? "nil")" }.joined(separator: " "))", .ax)
        let active = port.activeSpace()
        let bundle = appInfo[pid]?.bundleID
        let forcedFloat = bundle.map { options.floatingBundleIDs.contains($0) || localConfig.float.contains($0) } ?? false
        var listed: Set<WindowID> = []
        for snapshot in snapshots {
            listed.insert(snapshot.id)
            guard snapshot.isManageable else {
                rejected.insert(snapshot.id)
                continue
            }
            // With more than one screen, only windows on the primary one are Tessera's (C3).
            if screens.count > 1, let frame = snapshot.frame, let primary = primaryScreen,
               !primary.frame.contains(Point(x: frame.midX, y: frame.midY)), journal.hidden[snapshot.id] == nil {
                if world.windows[snapshot.id] != nil { forgetWindow(snapshot.id) }
                continue
            }
            let spaces = port.spaces(of: snapshot.id)
            let space: SpaceID? = active.flatMap { spaces.contains($0) ? $0 : nil } ?? spaces.first ?? active
            let hiddenByUs = journal.hidden[snapshot.id] != nil
            subroles[snapshot.id] = snapshot.subrole
            let isNew = world.windows[snapshot.id] == nil
            dispatch(.windowObserved(WindowObservation(
                id: snapshot.id, pid: pid, space: space,
                isNativeFullscreen: snapshot.isFullscreen,
                isMinimized: snapshot.isMinimized,
                isAppHidden: appHidden && !hiddenByUs,
                prefersFloating: forcedFloat || (options.tileAll ? snapshot.subrole != WindowSnapshot.standardSubrole : snapshot.prefersFloating),
                isOnAllSpaces: spaces.count > 1
            )))
            if isNew {
                firstSeen[snapshot.id] = port.now()
                recallFacts(for: snapshot.id, pid: pid, subrole: snapshot.subrole)
            }
            if let frame = snapshot.frame {
                captureOriginal(snapshot.id, pid: pid, frame: frame)
                noteObserved(snapshot.id, frame: frame)
            }
        }
        retireVanished(pid: pid, listed: listed)
    }

    /// Some apps close a window by ordering it out without destroying it, so the window server
    /// still lists it. A window of the active Space that the app no longer reports and that is
    /// not on screen has closed as far as the user can tell: it gives its tile back.
    func retireVanished(pid: Int32, listed: Set<WindowID>) {
        guard let active = world.activeSpace else { return }
        let candidates = world.windows.values.filter { $0.pid == pid && $0.space == active && !listed.contains($0.id) }
        guard !candidates.isEmpty else { return }
        let onScreen = port.presence(of: candidates.map(\.id)).onScreen
        for record in candidates where !onScreen.contains(record.id) && journal.hidden[record.id] == nil
            && (record.mode == .tiled || record.mode == .floating) {
            forgetWindow(record.id)
        }
    }

    /// Liveness: a window is gone once the window server no longer knows its id (plan §5).
    func audit() {
        Metrics.count(.audits)
        let tracked = Array(world.windows.keys)
        let presence = port.presence(of: tracked)
        for id in tracked where !presence.existing.contains(id) { forgetWindow(id) }
        // A tiled window of the visible Space that stopped being drawn without Tessera hiding it
        // may have been closed without being destroyed: re-read its app, once, on the transition.
        guard let active = world.activeSpace else { return }
        var suspects: Set<Int32> = []
        for record in world.windows.values where record.space == active && (record.mode == .tiled || record.mode == .floating) {
            if !presence.onScreen.contains(record.id), wasOnScreen.contains(record.id), journal.hidden[record.id] == nil,
               !inFlight.contains(record.id) {
                suspects.insert(record.pid)
            }
        }
        wasOnScreen = presence.onScreen
        suspects.forEach(rescan)
        // Panels and popovers come and go: the set only has to be good enough to avoid rescans,
        // so it is bounded rather than tracked (C5).
        if rejected.count > 2000 { rejected.removeAll() }
    }

    /// The window server can keep listing a closed window for a few milliseconds: look again
    /// shortly after anything that may have closed one, instead of waiting for the 2 s tick.
    func auditSoon() {
        // A close posts several notifications at once: only the latest burst runs.
        auditBurst += 1
        let burst = auditBurst
        for delay in timing.auditBurst {
            after(delay) { [weak self] in
                guard let self, self.auditBurst == burst, self.status.isActive else { return }
                self.audit()
            }
        }
    }

    /// Safety net for lost notifications: a managed app drawing a window Tessera does not know
    /// gets rescanned.
    func discoverMissed() {
        let unknownOwners = Set(port.onScreenOwners().compactMap { id, pid in
            world.windows[id] == nil && drivers[pid] != nil && !rejected.contains(id) ? pid : nil
        })
        for pid in unknownOwners {
            port.observe(pid: pid)
            port.observeWindows(pid: pid)
            rescan(pid)
        }
    }

    /// Reads the focused window on the app's own queue: a slow app never blocks the engine.
    func refreshFocus(confirmed: Bool = false) {
        guard let pid = port.frontmostPID(), let driver = drivers[pid] else { return }
        driver.focusedWindow { [weak self] id in
            guard let id else { return }
            self?.onMain { [weak self] in
                guard let self, self.world.windows[id] != nil, self.world.focused != id else { return }
                if let request = self.lastFocusRequest, request.id != id,
                   self.port.now().timeIntervalSince(request.at) < self.timing.echoWindow * 2 {
                    // Still the answer to an earlier request: following it would undo what the
                    // user just asked for (a window sent to another group dragging the view along).
                    return
                }
                if self.isInHiddenWorkspace(id), !confirmed {
                    // Focus on a window of a hidden group switches groups. macOS reports an app's
                    // last focused window for a moment when the app is activated; only a report
                    // that holds after the app settles is followed (found live).
                    self.after(self.timing.settleRead) { [weak self] in self?.refreshFocus(confirmed: true) }
                    return
                }
                self.dispatch(.focusChanged(id))
            }
        }
    }

    func isInHiddenWorkspace(_ id: WindowID) -> Bool {
        guard let record = world.windows[id], record.space == world.activeSpace,
              let space = world.activeSpaceState else { return false }
        return record.workspace != space.activeWorkspace
    }

    // MARK: - Screens and Spaces

    /// The usable area can read differently mid-transition between Spaces or when the Dock
    /// changes; re-read it and use the edge clamp learned for that arrangement (C4).
    func refreshScreen(force: Bool) {
        let current = port.screens()
        guard force || current != screens else { return }
        let before = screens.first
        screens = current
        if let primary = current.first, force || before?.usableArea != primary.usableArea || before?.frame != primary.frame {
            let key = EdgeClampStore.key(frame: primary.frame, usable: primary.usableArea)
            edgeClamp = EdgeClamp(insets: edgeClampStore.insets[key] ?? .zero)
            requested.removeAll()
            alignment.removeAll()
        }
        if current.count > 1 { preflight() }
        scheduleRender()
    }

    /// The Space notification can arrive before SkyLight reports the new Space: look again once
    /// the transition has settled.
    func scheduleSpaceChecks() {
        for delay in timing.spaceChecks {
            after(delay) { [weak self] in self?.spaceMayHaveChanged() }
        }
    }

    func spaceMayHaveChanged() {
        Metrics.count(.notifySpace)
        noteActivity()
        refreshScreen(force: false)
        refreshSpaces()
        // Three checks per transition cover a late SkyLight update; only the one that sees the
        // new Space rescans.
        guard world.activeSpace != lastScannedSpace else { return }
        lastScannedSpace = world.activeSpace
        trackDesktopChange()
        rescanAll()
        rescueSweep(reason: "space change")
        publishUI()
    }

    func refreshSpaces() {
        let descriptors = port.spaces()
        let order = port.spaceOrder()
        let desktops = Set(descriptors.filter { $0.kind == .desktop }.map(\.id))
        desktopOrder = order.isEmpty ? descriptors.filter { $0.kind == .desktop }.map(\.id) : order.filter(desktops.contains)
        if descriptors.isEmpty {
            dispatch(.spacesChanged([SpaceDescriptor(id: 1, kind: .desktop)], active: 1))
        } else {
            dispatch(.spacesChanged(descriptors, active: port.activeSpace()))
        }
    }

    // MARK: - Facts that outlive a run (D6)

    func factKey(pid: Int32, subrole: String?) -> FactStore.Key? {
        guard let bundle = appInfo[pid]?.bundleID else { return nil }
        return FactStore.Key(bundleID: bundle, version: appInfo[pid]?.version, subrole: subrole, scale: primaryScreen?.scale ?? 2)
    }

    func recallFacts(for id: WindowID, pid: Int32, subrole: String?) {
        guard world.facts[id] == nil, let key = factKey(pid: pid, subrole: subrole),
              let facts = factStore.facts(for: key, now: port.now()) else { return }
        dispatch(.factsLearned(id, facts))
    }

    func rememberFacts(_ facts: WindowFacts, for id: WindowID) {
        guard let pid = world.windows[id]?.pid, let key = factKey(pid: pid, subrole: subroles[id]) else { return }
        if facts == .flexible { factStore.forget(key) } else { factStore.remember(facts, for: key, now: port.now()) }
        guard !options.dryRun else { return }
        try? SecureFile.writeJSON(factStore, to: paths.facts)
    }
}

extension Rect {
    var midX: Int { x + width / 2 }
    var midY: Int { y + height / 2 }
}
