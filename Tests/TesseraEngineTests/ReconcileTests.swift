import Foundation
import Testing
@testable import TesseraEngine
import TesseraCore
import TesseraFakes
import TesseraPorts
import TesseraIPC

/// Placing windows, reading them back and learning what they accept.
@MainActor
struct ReconcileTests {
    func twoApps(_ h: Harness) -> (WindowID, WindowID) {
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        h.platform.launch(pid: 20, bundleID: "com.example.b")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 20, notify: false)
        return (a, b)
    }

    @Test func aMinimumIsLearnedAndTheOthersMakeRoom() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, minSize: Size(width: 300, height: 1500), notify: false)
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1500 && h.frame(a)?.height == 948 })
        #expect(h.engine.world.facts[b]?.minSize?.height == 1500)
        #expect(h.frame(a)!.maxY == h.frame(b)!.minY, "no hole between them")
        // Facts outlive the window: stored under bundle, version, subrole and scale (D6).
        let store = try #require(try SecureFile.readJSON(FactStore.self, from: h.engine.paths.facts))
        #expect(store.records.values.contains { $0.facts.minSize?.height == 1500 })
    }

    @Test func rememberedFactsApplyToANewWindowOfTheSameKind() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, minSize: Size(width: 300, height: 1500), notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.facts[b] != nil })
        h.platform.close(b)
        let c = h.platform.open(pid: 10)
        #expect(await h.until { h.engine.world.facts[c]?.minSize?.height == 1500 }, "known before any refusal")
    }

    // C1: nothing is learned from a failed write.
    @Test func failedWritesTeachNothing() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, frame: Rect(0, 30, 400, 400), notify: false)
        h.platform.apps[10]?.writeFailure = .cannotComplete
        try h.start()
        // Both attempts made and failed…
        #expect(await h.until(5) { h.engine.requested[a]?.attempts == 2 && h.engine.inFlight.isEmpty })
        await h.settle(0.1)
        // …and nothing learned from them.
        #expect(h.engine.world.facts[a] == nil)
        #expect(h.engine.factCandidates[a] == nil)
    }

    @Test func aDisplayLimitIsNotAWindowMaximum() throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        try h.start()
        h.engine.dispatch(.windowObserved(WindowObservation(id: a, pid: 10, space: 3)))
        // Asked for 2000 points of height past the display's bottom, macOS gave 540.
        let target = Rect(0, 2000, 1080, 2000)
        let result = Rect(0, 2000, 1080, 560)
        h.engine.learn(a, requested: target, observed: result)
        h.engine.learn(a, requested: target, observed: result)
        #expect(h.engine.world.facts[a]?.maxSize == nil)
    }

    @Test func contradictedFactsAreForgotten() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows[a] != nil })
        h.engine.dispatch(.factsLearned(a, WindowFacts(minSize: Size(width: 900, height: 2000))))
        // The window is seen, twice, far smaller than that "minimum".
        h.engine.checkContradiction(a, frame: Rect(0, 30, 400, 400))
        #expect(h.engine.world.facts[a]?.minSize != nil)
        h.engine.checkContradiction(a, frame: Rect(0, 30, 400, 400))
        #expect(h.engine.world.facts[a] == .flexible)
    }

    // C2: a window whose answers keep changing is left alone after a bounded number of writes.
    @Test func aRefusalLoopBacksOff() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        h.platform.windows[b]?.cyclingMinHeights = [1300, 1600, 1400, 1700]
        try h.start()
        await h.settle(0.6)
        let writes = h.platform.writeCount(b)
        #expect(writes <= Harness.timing.writeLimit + 2, "\(writes) writes")
        #expect(h.engine.backoff[b] != nil)
        await h.settle(0.3)
        #expect(h.platform.writeCount(b) == writes, "no more writes during the backoff")
        #expect(h.ui.noticeKeys().contains("window-refuses"))
    }

    // C4: the Dock clamp is blamed on the screen only when two apps agree.
    @Test func edgeClampNeedsTwoAppsToAgree() async throws {
        let platform = FakePlatform()
        platform.dockClamp = 1
        let h = try Harness(platform: platform)
        let (a, b) = twoApps(h)
        h.platform.frontmost = 10
        try h.start()
        #expect(await h.until { h.frame(b)?.maxY == 2477 })
        await h.settle(0.2)
        #expect(h.engine.edgeClamp.insets == .zero, "one app alone proves nothing")
        h.engine.execute(.swapWindows(a, b))
        #expect(await h.until { h.engine.edgeClamp.insets.bottom == 1 })
        #expect(await h.until { h.frame(a)?.maxY == 2477 && h.frame(b)?.minY == 30 })
        let store = try #require(try SecureFile.readJSON(EdgeClampStore.self, from: h.engine.paths.edgeClamp))
        #expect(store.insets.values.first?.bottom == 1)
    }

    @Test func edgeClampIsCapped() {
        var clamp = EdgeClamp(insets: Insets(top: 0, left: 0, bottom: 9, right: 0))
        #expect(clamp.insets.bottom == EdgeClamp.maximum)
        let area = Rect(0, 30, 1080, 2448)
        // Already at the cap: no further shortfall is accepted.
        let outcome = clamp.observe(target: Rect(0, 30, 1080, 2445), result: Rect(0, 30, 1080, 2443), current: Rect(0, 30, 1080, 2445), pid: 1)
        #expect(outcome == .none)
        _ = area
    }

    // C5: completions for an app that quit are ignored.
    @Test func windowsOfAnAppThatQuitMidScanNeverComeBack() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 1 })
        h.platform.launch(pid: 30, bundleID: "com.example.c")
        _ = h.platform.open(pid: 30)
        // The app quits in the same instant: the scan that was scheduled must not resurrect it.
        h.engine.release(pid: 30)
        await h.settle(0.2)
        #expect(!h.engine.world.windows.values.contains { $0.pid == 30 })
        #expect(h.engine.drivers[30] == nil)
    }

    @Test func releasingAnAppCleansEveryMap() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.observed[a] != nil && h.engine.lastWrite[a] != nil })
        h.platform.quit(pid: 10)
        #expect(await h.until { h.engine.world.windows[a] == nil })
        await h.settle()
        #expect(h.engine.observed[a] == nil && h.engine.requested[a] == nil && h.engine.lastWrite[a] == nil)
    }

    // C6: a window that drifted without a notification is found and put back.
    @Test func alignmentCheckRepairsASilentDrift() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 2448) })
        h.platform.silentlyMove(a, to: Rect(40, 60, 700, 700))
        h.platform.advanceClock(by: 20)
        h.engine.checkAlignment()
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 2448) })
        #expect(Metrics.value(.alignmentRetries) > 0)
    }

    // C8: a focus that could not be given is not given minutes later.
    @Test func staleFocusRequestsExpire() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1224 })
        h.platform.setMinimized(b, true)
        #expect(await h.until { h.engine.world.windows[b]?.mode == .minimized })
        h.engine.execute(.focusWindow(b))
        h.platform.advanceClock(by: 5)
        h.platform.setMinimized(b, false)
        #expect(await h.until { h.engine.world.windows[b]?.mode == .tiled })
        await h.settle()
        #expect(!h.platform.focusRequests.contains(b))
    }

    // Drag a tiled window onto another: they swap; the target tile is highlighted meanwhile (E8).
    @Test func draggingOntoAnotherTileSwapsAndHighlights() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(a)?.y == 30 && h.frame(b)?.y == 1254 })
        await h.settle()
        h.platform.emit(.mouseDown)
        h.platform.userMoves(a, to: Rect(0, 1500, 1080, 1224))
        #expect(await h.until { h.engine.draggedByUser.contains(a) })
        h.platform.emit(.mouseDragged(Point(x: 500, y: 1600)))
        #expect(h.ui.dropTargets.last == .some(Rect(0, 1254, 1080, 1224)))
        h.platform.emit(.mouseUp(Point(x: 500, y: 1600)))
        #expect(h.ui.dropTargets.last == .some(nil))
        #expect(await h.until { h.frame(a)?.y == 1254 && h.frame(b)?.y == 30 })
    }

    @Test func overflowIsExplainedOnce() async throws {
        let h = try Harness { $0.settings.overflow = .accordion }
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, minSize: Size(width: 900, height: 2000), notify: false)
        _ = h.platform.open(pid: 10, minSize: Size(width: 900, height: 2000), notify: false)
        try h.start()
        #expect(await h.until { h.ui.noticeKeys().contains("overflow") })
        await h.settle(0.2)
        #expect(h.ui.noticeKeys().filter { $0 == "overflow" }.count == 1)
    }

    @Test func windowsOnEveryDesktopFloat() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, allSpaces: true, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows[a]?.mode == .floating })
    }

    @Test func closingAWindowGivesItsTileBack() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1224 })
        h.platform.close(a)
        #expect(await h.until { h.frame(b) == Rect(0, 30, 1080, 2448) })
    }

    @Test func windowsClosedWithoutBeingDestroyedAreRetired() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1224 })
        h.platform.close(a, destroy: false)
        #expect(await h.until { h.frame(b) == Rect(0, 30, 1080, 2448) })
    }
}

extension ReconcileTests {
    /// Found live: a quick burst of commands wrote windows often and successfully, and the loop
    /// guard froze them for a minute. Only refusals count.
    @Test func aBurstOfCommandsNeverTriggersTheLoopGuard() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1224 })
        h.engine.execute(.focusWindow(a))
        for index in 0..<12 {
            h.engine.execute(.resize(.height, points: index.isMultiple(of: 2) ? 100 : -100))
            #expect(await h.until { h.engine.inFlight.isEmpty })
        }
        #expect(h.engine.backoff.isEmpty)
        #expect(await h.until { h.frame(a)!.maxY == h.frame(b)!.minY && h.frame(b)!.maxY == 2478 })
    }
}

extension ReconcileTests {
    /// C3: with a second screen, only primary-screen windows are Tessera's, and a hidden window
    /// goes past a corner whose far side touches no other screen.
    @Test func aSecondScreenIsLeftAloneAndNeverReceivesHiddenWindows() async throws {
        let platform = FakePlatform()
        platform.dockClamp = 0
        // The second screen sits to the right of the portrait one, bottom-aligned.
        platform.screenList.append(ScreenInfo(frame: Rect(1080, 1120, 2560, 1440), usableArea: Rect(1080, 1120, 2560, 1440)))
        let h = try Harness(native: false, platform: platform)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        let elsewhere = h.platform.open(pid: 10, frame: Rect(1500, 1300, 800, 600), notify: false)
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1224 })
        #expect(h.engine.world.windows[elsewhere] == nil)
        #expect(h.frame(elsewhere) == Rect(1500, 1300, 800, 600))
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { h.engine.journal.hidden[a] != nil && h.engine.inFlight.isEmpty })
        let parked = try #require(h.frame(a))
        #expect(!parked.intersects(Rect(1080, 1120, 2560, 1440)), "parked at \(parked): not on the second screen")
        #expect(parked.maxX <= 1, "past the bottom-left corner")
    }

    @Test func repeatedStateQueriesShareOneAnswer() throws {
        let h = try Harness()
        try h.start()
        let request = try JSONEncoder().encode(IPCRequest(query: "state"))
        let first = h.engine.answer(request)
        let second = h.engine.answer(request)
        #expect(first == second)
    }
}

extension ReconcileTests {
    /// Found live: a terminal-like window never takes its exact size, and the alignment check
    /// kept rewriting it until it drifted out of the area.
    @Test func alignmentLeavesWindowsThatRefusedTheirTargetAlone() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.term")
        let grid = h.platform.open(pid: 10, minSize: Size(width: 60, height: 40), quantum: Size(width: 7, height: 17), notify: false)
        try h.start()
        #expect(await h.until { h.engine.refusedTarget[grid] != nil })
        await h.settle(0.2)
        let writes = h.platform.writeCount(grid)
        for _ in 0..<4 {
            h.platform.advanceClock(by: 20)
            h.engine.checkAlignment()
            await h.settle(0.05)
        }
        #expect(h.platform.writeCount(grid) == writes, "no rewrites of a refused target")
    }

    /// Found live (groups mode): an app's stale "focused window" report pulled the view into a
    /// hidden group. Only a report that holds is followed.
    @Test func aPassingFocusReportForAHiddenGroupIsNotFollowed() async throws {
        let h = try Harness(native: false)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1224 })
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { h.engine.journal.hidden[a] != nil })
        await h.settle(0.1)
        // The app reports `a` for an instant, then `b`.
        h.platform.frontmost = 10
        h.platform.apps[10]?.focused = a
        h.platform.emit(.appActivated(pid: 10))
        h.platform.apps[10]?.focused = b
        await h.settle(0.1)
        #expect(h.engine.world.activeWorkspace?.name == "1")
        // A report that holds is followed (Cmd-Tab to a window of a hidden group).
        h.platform.apps[10]?.focused = a
        h.platform.emit(.appActivated(pid: 10))
        #expect(await h.until { h.engine.world.activeWorkspace?.name == "2" })
    }
}

extension ReconcileTests {
    /// Found live: a grid window kept its own size and landed a point off its tile, outside the
    /// area. Its size is respected; its origin is put back.
    @Test func aSizeKeepingWindowIsPutBackAtItsTileOrigin() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.term")
        let grid = h.platform.open(pid: 10, minSize: Size(width: 60, height: 40), quantum: Size(width: 7, height: 17), notify: false)
        h.platform.windows[grid]?.snapNudge = Point(x: -1, y: -1)
        try h.start()
        #expect(await h.until { h.frame(grid)?.origin == Point(x: 0, y: 30) && h.engine.positionCorrected[grid] != nil })
        #expect(h.frame(grid).map { Rect(0, 30, 1080, 2448).contains($0) } == true)
    }

    /// Found live: the throttled `debug state` answered with the model from before a command.
    @Test func stateReflectsACommandImmediately() async throws {
        let h = try Harness()
        let (a, _) = twoApps(h)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 })
        let request = try JSONEncoder().encode(IPCRequest(query: "state"))
        let before = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(request))
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.toggleFullscreen)
        let after = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(request))
        #expect(before.state?.spaces.first?.workspaces.first?.zoomed == nil)
        #expect(after.state?.spaces.first?.workspaces.first?.zoomed == a)
    }
}

extension ReconcileTests {
    /// Found live: a grid window whose first write was ignored was taken for "keeps its own
    /// size" and left where it opened, over the others.
    @Test func aWindowThatIgnoredTheFirstWriteIsStillPlaced() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.term")
        let grid = h.platform.open(pid: 10, frame: Rect(100, 100, 400, 300), minSize: Size(width: 60, height: 40),
                                   quantum: Size(width: 7, height: 17), notify: false)
        h.platform.windows[grid]?.ignoredWrites = 1
        try h.start()
        #expect(await h.until { (h.frame(grid)?.width ?? 0) > 1000 })
        let frame = try #require(h.frame(grid))
        #expect(Rect(0, 30, 1080, 2448).contains(frame))
        #expect(frame.origin == Point(x: 0, y: 30))
    }
}


/// The owner's report of 2026-09-26: after a game opened, every window was full size, some could
/// not be minimised and none could be resized with the mouse.
extension ReconcileTests {
    @Test func windowsThatDoNotFitFloatAndStayWhereTheUserPutsThem() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.launcher")
        let a = h.platform.open(pid: 10, minSize: Size(width: 900, height: 1500), notify: false)
        let b = h.platform.open(pid: 10, minSize: Size(width: 900, height: 1500), notify: false)
        try h.start()
        #expect(await h.until(5) { h.engine.world.windows.values.contains { $0.mode == .floating } })
        #expect(await h.until { h.ui.noticeKeys().contains("overflow-float") })
        let floating = h.engine.world.windows.values.first { $0.mode == .floating }!.id
        let tiled = floating == a ? b : a
        #expect(await h.until(5) { h.frame(tiled) == Rect(0, 30, 1080, 2448) }, "the other one keeps the desktop")
        // The user moves and resizes the floating one: Tessera leaves it there.
        await h.settle(0.1)
        h.platform.userMoves(floating, to: Rect(50, 400, 950, 1600))
        await h.settle(0.3)
        #expect(h.frame(floating) == Rect(50, 400, 950, 1600))
    }

    /// Owner, 2026-09-26: a width change in a column floated the browsers out of the tiling.
    /// A resize never takes a window out: what the tiling cannot express goes back.
    @Test func aResizeTheTilingCannotExpressKeepsTheWindowTiled() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(a)?.height == 1224 })
        await h.settle(0.1)
        // Narrower and taller: the column can share the height, not the width.
        h.platform.emit(.mouseDown)
        h.platform.userMoves(a, to: Rect(0, 30, 700, 1500))
        #expect(await h.until { h.engine.draggedByUser.contains(a) })
        h.platform.emit(.mouseUp(Point(x: 600, y: 1520)))
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 1500) && h.frame(b)?.minY == 1530 })
        #expect(h.engine.world.windows[a]?.mode == .tiled)
        #expect(h.ui.noticeKeys().contains("resize-limited"))
    }

    @Test func aResizeTheTilingCanHonourSharesTheSpace() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(a)?.height == 1224 })
        await h.settle(0.1)
        h.platform.emit(.mouseDown)
        h.platform.userMoves(a, to: Rect(0, 30, 1080, 1500))
        #expect(await h.until { h.engine.draggedByUser.contains(a) })
        h.platform.emit(.mouseUp(Point(x: 500, y: 1520)))
        #expect(await h.until { h.frame(b)?.minY == 1530 && h.frame(a)?.height == 1500 })
        #expect(h.engine.world.windows[a]?.mode == .tiled)
    }

    @Test func aMovingWindowThatTurnsOutMinimisedIsNotWrittenBack() async throws {
        let h = try Harness()
        let (a, _) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(a)?.height == 1224 })
        await h.settle(0.1)
        let writes = h.platform.writeCount(a)
        // The minimise animation moves the window, then the app reports it minimised.
        h.platform.userMoves(a, to: Rect(300, 2000, 200, 100))
        h.platform.windows[a]?.isMinimized = true
        await h.settle(0.5)
        #expect(h.engine.world.windows[a]?.mode == .minimized)
        #expect(h.platform.writeCount(a) == writes, "no write fought the minimise")
    }

    @Test func nothingIsLearnedWhileAWindowIsStillOpening() async throws {
        var timing = Harness.timing
        timing.openingGrace = 30
        let h = try Harness(timing: timing)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, minSize: Size(width: 300, height: 1500), notify: false)
        try h.start()
        #expect(await h.until { h.engine.requested[b]?.attempts == 2 }, "left alone while opening")
        #expect(h.engine.world.facts[b] == nil)
        #expect(h.engine.backoff[b] == nil, "refusals while opening do not trip the loop guard")
        // Once the window has had time to open, its refusals teach its real minimum.
        h.platform.advanceClock(by: 31)
        h.engine.requested[b] = nil
        h.engine.scheduleRender()
        #expect(await h.until(3) { h.engine.world.facts[b]?.minSize?.height == 1500 })
    }

    @Test func learnedSizesCanBeForgotten() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, minSize: Size(width: 300, height: 1500), notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.facts[b] != nil })
        h.engine.perform(.forgetSizes)
        #expect(h.engine.world.facts[b] == .flexible)
        #expect(h.engine.factStore.records.isEmpty)
        #expect(h.ui.noticeKeys().contains("sizes-forgotten"))
    }
}


/// The owner's second report (2026-09-26): a floated browser could not be dragged back into the
/// vertical stack, and another was left half-applied, full height and 500 wide.
extension ReconcileTests {
    func floatedThird(_ h: Harness) async throws -> (WindowID, WindowID, WindowID) {
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        h.platform.launch(pid: 20, bundleID: "com.example.b")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 20, notify: false)
        let c = h.platform.open(pid: 10, frame: Rect(200, 300, 500, 500), notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 3 })
        h.engine.execute(.setFloating(c, true))
        #expect(await h.until { h.frame(a)?.height == 1224 && h.frame(b)?.height == 1224 })
        await h.settle(0.1)
        return (a, b, c)
    }

    @Test func draggingAFloatingWindowOntoTheStackInsertsIt() async throws {
        let h = try Harness()
        let (a, b, c) = try await floatedThird(h)
        let size = h.frame(c)!.size
        h.platform.emit(.mouseDown)
        h.platform.userMoves(c, to: Rect(origin: Point(x: 300, y: 900), size: size))
        #expect(await h.until { h.engine.draggedByUser.contains(c) })
        // Over the lower half of `a`'s tile: the highlight shows the slot below `a`.
        h.platform.emit(.mouseDragged(Point(x: 500, y: 1000)))
        #expect(h.ui.dropTargets.last == .some(Rect(0, 642, 1080, 612)))
        h.platform.emit(.mouseUp(Point(x: 500, y: 1000)))
        #expect(await h.until { h.engine.world.activeWorkspace?.root.windows == [a, c, b] })
        #expect(await h.until { h.frame(c) == Rect(0, 846, 1080, 816) })
        #expect(h.engine.world.windows[c]?.mode == .tiled)
    }

    @Test func holdingOptionKeepsADraggedWindowFloating() async throws {
        let h = try Harness()
        let (_, _, c) = try await floatedThird(h)
        let moved = Rect(origin: Point(x: 300, y: 900), size: h.frame(c)!.size)
        h.platform.emit(.mouseDown)
        h.platform.emit(.modifiersChanged([.option]))
        h.platform.userMoves(c, to: moved)
        #expect(await h.until { h.engine.draggedByUser.contains(c) })
        h.platform.emit(.mouseUp(Point(x: 500, y: 1000)))
        await h.settle(0.2)
        #expect(h.engine.world.windows[c]?.mode == .floating)
        #expect(h.frame(c) == moved)
    }

    @Test func dialogsAreNeverDroppedIntoTheTiling() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        let dialog = h.platform.open(pid: 10, frame: Rect(200, 300, 400, 300), subrole: "AXDialog", notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows[dialog]?.mode == .floating })
        await h.settle(0.1)
        h.platform.emit(.mouseDown)
        h.platform.userMoves(dialog, to: Rect(300, 900, 400, 300))
        h.platform.emit(.mouseUp(Point(x: 500, y: 1000)))
        await h.settle(0.2)
        #expect(h.engine.world.windows[dialog]?.mode == .floating)
        #expect(h.frame(dialog) == Rect(300, 900, 400, 300))
    }

    @Test func aSlowAppDuringLayoutChangesIsNotBackedOff() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        h.platform.windows[a]?.answersLate = true
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 })
        h.engine.execute(.focusWindow(a))
        for points in [120, -60, 90, -150, 200, -40, 70, -110, 30] {
            h.engine.execute(.resize(.height, points: points))
            await h.settle(0.03)
        }
        await h.settle(0.2)
        #expect(h.engine.backoff[a] == nil, "different targets answered late are not a loop")
        #expect(await h.until { h.frame(a)!.maxY == h.frame(b)!.minY })
    }

    @Test func touchingAWindowWithTheMouseEndsItsBackoff() async throws {
        let h = try Harness()
        let (a, _) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(a)?.height == 1224 })
        await h.settle(0.1)
        h.engine.backoff[a] = (h.platform.now().addingTimeInterval(60), 60)
        h.platform.emit(.mouseDown)
        h.platform.userMoves(a, to: Rect(0, 30, 1080, 1400))
        #expect(await h.until { h.engine.draggedByUser.contains(a) })
        h.platform.emit(.mouseUp(Point(x: 500, y: 1420)))
        #expect(await h.until { h.engine.backoff[a] == nil })
    }
}


extension ReconcileTests {
    /// "Reordenar todas las ventanas": floated ordinary windows back into the tiling, dialogs left
    /// floating, a user pause lifted, never a pause.
    @Test func retileAllBringsFloatedWindowsBackAndResumes() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        let dialog = h.platform.open(pid: 10, frame: Rect(200, 300, 400, 300), subrole: "AXDialog", notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 3 })
        h.engine.execute(.setFloating(b, true))
        h.engine.togglePause()
        #expect(h.engine.status == .paused(.user))
        h.engine.perform(.gather)
        #expect(h.engine.status == .active)
        #expect(h.engine.world.windows[b]?.mode == .tiled)
        #expect(h.engine.world.windows[dialog]?.mode == .floating)
        #expect(await h.until { h.frame(a)?.height == 1224 && h.frame(b)?.height == 1224 })
        #expect(h.ui.noticeKeys().contains("retiled"))
    }
}

/// The owner's third report (2026-09-27): resizing lit the neighbour blue and, on release, the
/// window went back where it was.
extension ReconcileTests {
    @Test func theResizeAppliedIsTheOneAtReleaseNotTheLastNotification() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(a)?.height == 1224 })
        await h.settle(0.1)
        h.platform.emit(.mouseDown)
        // One notification mid-drag, then the rest of the drag arrives without one.
        h.platform.userMoves(a, to: Rect(0, 30, 1080, 1300))
        #expect(await h.until { h.engine.draggedByUser.contains(a) })
        h.platform.silentlyMove(a, to: Rect(0, 30, 1080, 1700))
        h.platform.emit(.mouseUp(Point(x: 500, y: 1720)))
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 1700) && h.frame(b)?.minY == 1730 })
    }

    @Test func resizingShowsNoSwapTarget() async throws {
        let h = try Harness()
        let (a, _) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(a)?.height == 1224 })
        await h.settle(0.1)
        h.platform.emit(.mouseDown)
        h.platform.userMoves(a, to: Rect(0, 30, 1080, 1600))
        #expect(await h.until { h.engine.draggedByUser.contains(a) })
        h.platform.emit(.mouseDragged(Point(x: 500, y: 1590)))
        #expect(!h.ui.dropTargets.contains { $0 != nil }, "a resize lights nothing up")
        h.platform.emit(.mouseUp(Point(x: 500, y: 1600)))
        #expect(await h.until { h.frame(a)?.height == 1600 })
    }

    @Test func movingStillShowsTheSwapTarget() async throws {
        let h = try Harness()
        let (a, b) = twoApps(h)
        try h.start()
        #expect(await h.until { h.frame(a)?.height == 1224 })
        await h.settle(0.1)
        h.platform.emit(.mouseDown)
        h.platform.userMoves(a, to: Rect(0, 900, 1080, 1224))
        #expect(await h.until { h.engine.draggedByUser.contains(a) })
        h.platform.emit(.mouseDragged(Point(x: 500, y: 1600)))
        #expect(h.ui.dropTargets.last == .some(h.frame(b)!))
    }
}
