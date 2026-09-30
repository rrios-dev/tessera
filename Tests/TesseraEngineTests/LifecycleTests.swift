import Foundation
import Testing
@testable import TesseraEngine
import TesseraCore
import TesseraFakes
import TesseraPorts

/// Start, stop, permissions, pause, crash loops and everything that must survive a restart.
@MainActor
struct LifecycleTests {
    @Test func tilesEveryWindowOfTheActiveDesktop() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(h.engine.status == .active)
        #expect(await h.until { h.frames([a, b]) == [Rect(0, 30, 1080, 1224), Rect(0, 1254, 1080, 1224)] })
        #expect(h.violations().isEmpty)
    }

    // A1: an entry leaves the journal only when the window is confirmed back.
    @Test func journalKeepsWindowsItCouldNotConfirmAndTheNextRunRestoresThem() async throws {
        let h = try Harness(native: false)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, frame: Rect(100, 200, 500, 400), notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        h.platform.frontmost = 10
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1224 })
        let placed = h.frame(a)!
        // Send `a` to group 2: it is hidden past the corner and journaled first.
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { h.engine.journal.hidden[a] != nil && (h.frame(a)?.x ?? 0) >= 1079 })
        #expect(h.engine.journal.hidden[a]?.frame == placed)

        // The user goes to another native desktop and quits: Accessibility cannot reach `a` there.
        h.platform.active = 7
        await h.stop()
        #expect((h.frame(a)?.x ?? 0) >= 1079, "still parked")
        let saved = try #require(try SecureFile.readJSON(Journal.self, from: h.engine.paths.journal))
        #expect(saved.hidden[a]?.frame == placed, "an unconfirmed restore stays in the journal")

        // Next run, back on the desktop: the saved layout still puts `a` in group 2, so it stays
        // hidden and journaled until that group is shown, which confirms and clears the entry.
        h.platform.active = 3
        try h.restart()
        await h.settle()
        #expect(h.engine.journal.hidden[a] != nil)
        h.engine.execute(.workspace("2"))
        #expect(await h.until { h.engine.journal.hidden[a] == nil })
        #expect(h.frame(a)?.origin == placed.origin, "back on screen, confirmed")
        #expect(await h.until { h.engine.journal.hidden[b] != nil }, "group 1 is the hidden one now")
    }

    @Test func rescueSweepRestoresWindowsTheModelNoLongerHides() async throws {
        let h = try Harness(native: false)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 && h.engine.lastWrite[a] != nil })
        await h.settle(0.05)
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { (h.frame(a)?.x ?? 0) >= 1079 })
        let placed = h.engine.journal.hidden[a]!.frame
        h.platform.active = 7
        await h.stop()
        // A crash before the layout was saved: only the journal knows where `a` came from.
        try? FileManager.default.removeItem(at: h.engine.paths.world)
        h.platform.active = 3
        try h.restart()
        #expect(await h.until { h.engine.journal.hidden.isEmpty })
        #expect(h.frame(a)?.origin == placed.origin || h.engine.world.activeWorkspace?.root.contains(a) == true)
        #expect((h.frame(a)?.x ?? 2000) < 1079, "back on screen")
    }

    @Test func quitRestoresHiddenWindowsAndEmptiesTheJournal() async throws {
        let h = try Harness(native: false)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 && h.engine.lastWrite[a] != nil })
        await h.settle(0.05)
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { (h.frame(a)?.x ?? 0) >= 1079 })
        let original = h.engine.journal.hidden[a]!.frame
        await h.stop()
        #expect(h.frame(a) == original)
        #expect(try SecureFile.readJSON(Journal.self, from: h.engine.paths.journal)?.hidden.isEmpty == true)
    }

    @Test func journalEntriesOfClosedWindowsAreDropped() async throws {
        let h = try Harness(native: false)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 && h.engine.lastWrite[a] != nil })
        await h.settle(0.05)
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { h.engine.journal.hidden[a] != nil })
        h.platform.close(a)
        #expect(await h.until { h.engine.journal.hidden.isEmpty })
    }

    // A2: one engine per state directory; dry runs never write the journal.
    @Test func secondEngineOnTheSameStateDirectoryRefusesToStart() throws {
        let h = try Harness()
        try h.start()
        let other = Engine(options: h.options, port: FakePlatform(), ui: RecordingUI(), timing: Harness.timing, log: Log(url: nil, echoToStandardError: false))
        #expect(throws: Engine.StartError.self) { try other.start() }
    }

    @Test func dryRunNeverTouchesTheJournal() async throws {
        let h = try Harness(native: false) { $0.dryRun = true }
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        await h.settle()
        #expect(h.platform.writes.isEmpty, "dry run moves nothing")
        #expect(!FileManager.default.fileExists(atPath: h.engine.paths.journal.path))
    }

    @Test func testAppIsNeverManagedByTheOwnersEngine() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "dev.rrios.tessera.dummy", executable: "DummyWindowApp")
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        await h.settle()
        #expect(h.engine.world.windows.isEmpty)
    }

    // A4: owner-only files, boot-scoped and quarantined when corrupt.
    @Test func stateFilesAreOwnerOnly() async throws {
        let h = try Harness(native: false)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 && h.engine.lastWrite[a] != nil })
        await h.settle(0.05)
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { FileManager.default.fileExists(atPath: h.engine.paths.journal.path) })
        let file = try FileManager.default.attributesOfItem(atPath: h.engine.paths.journal.path)[.posixPermissions] as? Int
        let folder = try FileManager.default.attributesOfItem(atPath: h.directory.path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        #expect(folder == 0o700)
    }

    @Test func journalFromAnotherBootIsDiscarded() async throws {
        let h = try Harness()
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        var old = Journal(bootSession: "previous-boot")
        old.hidden[42] = Journal.Entry(pid: 1, frame: Rect(0, 0, 10, 10))
        try old.save(to: StatePaths(directory: h.directory).journal)
        try h.start()
        #expect(h.engine.journal.hidden.isEmpty)
        #expect(h.engine.journal.bootSession == h.platform.bootSession)
    }

    @Test func corruptJournalIsQuarantinedAndReported() throws {
        let h = try Harness()
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: StatePaths(directory: h.directory).journal)
        try h.start()
        #expect(h.ui.noticeKeys().contains("journal-corrupt"))
        let files = try FileManager.default.contentsOfDirectory(atPath: h.directory.path)
        #expect(files.contains { $0.hasPrefix("journal.corrupt-") })
    }

    // A3: three unclean starts in five minutes is a crash loop.
    @Test func crashLoopStartsInSafeModeAndRetryResumes() async throws {
        let h = try Harness(native: false)
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        var guardState = CrashGuard()
        _ = guardState.recordStart(now: Date().addingTimeInterval(-60))
        _ = guardState.recordStart(now: Date().addingTimeInterval(-30))
        try SecureFile.writeJSON(guardState, to: StatePaths(directory: h.directory).starts)
        var journal = Journal(bootSession: h.platform.bootSession)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, frame: Rect(1079, 2559, 400, 300), notify: false)
        journal.hidden[a] = Journal.Entry(pid: 10, frame: Rect(50, 60, 400, 300))
        try journal.save(to: StatePaths(directory: h.directory).journal)

        try h.start()
        #expect(h.engine.status == .safeMode)
        #expect(h.ui.noticeKeys().contains("safe-mode"))
        #expect(await h.until { h.frame(a) == Rect(50, 60, 400, 300) }, "safe mode restores hidden windows")
        #expect(h.platform.registeredChords.isEmpty)

        h.engine.perform(.retry)
        #expect(h.engine.status == .active)
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 2448) })
    }

    @Test func cleanExitResetsTheCrashGuard() async throws {
        let h = try Harness()
        try h.start()
        await h.stop()
        let saved = try SecureFile.readJSON(CrashGuard.self, from: h.engine.paths.starts)
        #expect(saved?.starts.isEmpty == true)
    }

    // E3: no permission → wait, prompt once, resume by itself.
    @Test func withoutPermissionItWaitsAndResumesWhenGranted() async throws {
        let h = try Harness()
        h.platform.trusted = false
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(h.engine.status == .noPermission)
        #expect(h.platform.trustPrompts == 1)
        await h.settle()
        #expect(h.platform.writes.isEmpty)
        h.platform.trusted = true
        #expect(await h.until { h.engine.status == .active })
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 2448) })
        #expect(h.ui.noticeKeys().contains("permission-restored"))
    }

    @Test func revokedPermissionIsNoticed() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        await h.settle()
        h.platform.trusted = false
        #expect(await h.until { h.engine.status == .noPermission })
        #expect(h.ui.noticeKeys().contains("permission-lost"))
        #expect(h.platform.registeredChords.isEmpty, "hotkeys that could do nothing are released")
    }

    // E4: pause keeps windows where the user puts them; resume re-tiles.
    @Test func pauseLeavesWindowsAloneAndResumeRetiles() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 2448) })
        h.engine.togglePause()
        #expect(h.engine.status == .paused(.user))
        #expect(h.platform.registeredChords.count == 1, "only the pause chord stays")
        h.platform.userMoves(a, to: Rect(200, 300, 400, 400))
        await h.settle()
        #expect(h.frame(a) == Rect(200, 300, 400, 400))
        h.platform.press(h.platform.registeredChords[0])
        #expect(h.engine.status == .active)
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 2448) })
    }

    @Test func retileGathersHiddenGroupsIntoViewWithoutPausing() async throws {
        let h = try Harness(native: false)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 && h.engine.lastWrite[a] != nil })
        await h.settle(0.05)
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { h.engine.journal.hidden[a] != nil })
        h.engine.perform(.gather)
        #expect(h.engine.status == .active)
        #expect(await h.until { h.engine.journal.hidden.isEmpty && h.frame(a)?.height == 1224 && h.frame(b)?.height == 1224 })
        #expect(h.engine.world.activeSpaceState?.workspaces.count == 1)
    }

    // E7: other tilers and Stage Manager pause Tessera until they go away.
    @Test func anotherTilerPausesTesseraUntilItQuits() async throws {
        let h = try Harness()
        h.platform.tilers = ["AeroSpace"]
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, frame: Rect(10, 40, 300, 300), notify: false)
        try h.start()
        #expect(h.engine.status == .paused(.conflict(["AeroSpace"])))
        #expect(h.ui.noticeKeys().contains("conflict"))
        await h.settle()
        #expect(h.frame(a) == Rect(10, 40, 300, 300), "no fight")
        h.platform.tilers = []
        h.platform.emit(.appTerminated(pid: 99))
        #expect(h.engine.status == .active)
        #expect(await h.until { h.frame(a) == Rect(0, 30, 1080, 2448) })
    }

    @Test func stageManagerPausesTessera() throws {
        let h = try Harness()
        h.platform.stageManager = true
        try h.start()
        #expect(h.engine.status == .paused(.stageManager))
    }

    @Test func edgeTilingAndExtraScreensAreExplained() throws {
        let platform = FakePlatform()
        platform.dockClamp = 0
        platform.edgeTiling = true
        platform.screenList.append(ScreenInfo(frame: Rect(1080, 0, 2560, 1440), usableArea: Rect(1080, 25, 2560, 1415)))
        let h = try Harness(platform: platform)
        try h.start()
        #expect(h.ui.noticeKeys().contains("edge-tiling"))
        #expect(h.ui.noticeKeys().contains("second-screen"))
        #expect(h.ui.state?.screensBeyondPrimary == 1)
    }

    // E11: the layout from before Tessera touched anything can be restored for ten minutes.
    @Test func revertPutsWindowsBackWhereTheyWere() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, frame: Rect(100, 100, 500, 500), notify: false)
        let b = h.platform.open(pid: 10, frame: Rect(300, 700, 600, 400), notify: false)
        try h.start()
        #expect(await h.until { h.frame(b)?.height == 1224 })
        #expect(h.ui.state?.canRevert == true)
        h.engine.perform(.revertLayout)
        #expect(await h.until { h.frame(a) == Rect(100, 100, 500, 500) && h.frame(b) == Rect(300, 700, 600, 400) })
        #expect(h.engine.status == .paused(.user))
        h.platform.advanceClock(by: 601)
        #expect(!h.engine.canRevert)
    }

    // F6: the trees survive a restart.
    @Test func layoutSurvivesARestart() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        let b = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.frame(a)?.y == 30 })
        h.engine.execute(.swapWindows(a, b))
        #expect(await h.until { h.frame(b)?.y == 30 })
        await h.stop()
        try h.restart()
        await h.settle(0.2)
        #expect(h.frame(b)?.y == 30, "the swapped order is kept, not re-tiled from scratch")
        #expect(h.engine.world.activeWorkspace?.root.windows == [b, a])
    }

    // F11: the enhanced-UI journal is armed in the state directory.
    @Test func enhancedUserInterfaceJournalIsArmed() throws {
        let h = try Harness()
        try h.start()
        #expect(h.platform.enhancedUIJournal == h.engine.paths.enhancedUI)
    }
}

extension LifecycleTests {
    @Test func journalsFromTheFirstVersionAreStillRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("journal.json")
        try Data(#"{"hidden":{"4242":{"pid":7,"frame":{"x":1,"y":2,"width":300,"height":200}}}}"#.utf8).write(to: url)
        guard case .loaded(let journal) = Journal.load(from: url, bootSession: "boot-9", now: Date()) else {
            Issue.record("a legacy journal must load")
            return
        }
        #expect(journal.hidden[4242]?.frame == Rect(1, 2, 300, 200))
        #expect(journal.bootSession == "boot-9")
        try journal.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""4242""#), "ids stay readable object keys")
    }
}

extension LifecycleTests {
    @Test func filesFromEarlierVersionsAreTightened() throws {
        let h = try Harness()
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        let old = h.directory.appendingPathComponent("journal.json")
        FileManager.default.createFile(atPath: old.path, contents: Data(#"{"hidden":{}}"#.utf8), attributes: [.posixPermissions: 0o644])
        try h.start()
        #expect(try FileManager.default.attributesOfItem(atPath: old.path)[.posixPermissions] as? Int == 0o600)
    }
}

extension LifecycleTests {
    /// Found by a flaky run: a render after the shutdown had restored a window hid it again.
    @Test func nothingIsHiddenOnceQuittingStarted() async throws {
        let h = try Harness(native: false)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 && h.engine.lastWrite[a] != nil })
        h.engine.execute(.focusWindow(a))
        h.engine.execute(.moveNodeToWorkspace("2"))
        #expect(await h.until { (h.frame(a)?.x ?? 0) >= 1079 && h.engine.inFlight.isEmpty })
        let original = h.engine.journal.hidden[a]!.frame
        await h.stop()
        // A render arriving now must not touch anything.
        h.engine.render()
        h.engine.hide(a)
        await h.settle(0.1)
        #expect(h.frame(a) == original)
        #expect(h.engine.journal.hidden.isEmpty)
    }
}
