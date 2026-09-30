import Foundation
import Testing
@testable import TesseraEngine
import TesseraConfig
import TesseraCore
import TesseraFakes
import TesseraIPC
import TesseraPorts

/// Native desktops, synthesized keys, hotkeys, configuration and the CLI socket's handler.
@MainActor
struct DesktopAndInputTests {
    func started(_ platform: FakePlatform? = nil, configure: (inout Engine.Options) -> Void = { _ in }) throws -> Harness {
        let h = try Harness(platform: platform, configure: configure)
        try h.start()
        return h
    }

    // B1: only 1…N reaches the keyboard.
    @Test func outOfRangeDesktopsNeverPostKeys() throws {
        let h = try started()
        for name in ["-100000000", "0", "3", "17", "web"] {
            h.engine.execute(.workspace(name))
        }
        #expect(h.platform.postedKeys.isEmpty)
        #expect(h.ui.noticeKeys().filter { $0 == "desktop-missing" }.count == 5)
    }

    @Test func directJumpPostsControlDigit() throws {
        let h = try started()
        h.engine.execute(.workspace("2"))
        #expect(h.platform.postedKeys.count == 1)
        #expect(h.platform.postedKeys.first?.keyCode == KeyCode.digits[1])
        #expect(h.platform.postedKeys.first?.flags == .control)
    }

    // B3: never under Secure Input, never over the login window.
    @Test func secureInputBlocksSynthesizedKeys() throws {
        let h = try started()
        h.platform.secureInput = true
        h.engine.execute(.workspace("2"))
        #expect(h.platform.postedKeys.isEmpty)
        #expect(h.ui.noticeKeys().contains("secure-input"))
    }

    @Test func loginWindowBlocksSynthesizedKeys() throws {
        let h = try started()
        h.platform.launch(pid: 1, bundleID: "com.apple.loginwindow")
        h.platform.frontmost = 1
        h.engine.execute(.workspace("2"))
        #expect(h.platform.postedKeys.isEmpty)
    }

    @Test func disabledShortcutsAreExplainedNotGuessed() throws {
        let platform = FakePlatform()
        platform.dockClamp = 0
        platform.symbolic = [:]
        let h = try started(platform)
        h.engine.execute(.workspace("2"))
        #expect(h.platform.postedKeys.isEmpty, "Control-Arrow would reach the focused app")
        #expect(h.ui.noticeKeys().contains("shortcuts-off"))
    }

    // E6: arrow steps count full-screen Spaces too.
    @Test func arrowStepsCrossFullScreenSpaces() throws {
        let platform = FakePlatform(spaces: [
            SpaceDescriptor(id: 3, kind: .desktop), SpaceDescriptor(id: 90, kind: .fullscreen), SpaceDescriptor(id: 7, kind: .desktop),
        ])
        platform.dockClamp = 0
        platform.symbolic = FakePlatform.defaultSymbolicHotkeys(directJumps: false)
        let h = try started(platform)
        h.engine.execute(.workspace("2"))
        #expect(h.platform.postedKeys.map(\.keyCode) == [KeyCode.rightArrow, KeyCode.rightArrow])
        #expect(h.platform.postedKeys.allSatisfy { $0.flags == [.control, .function] })
    }

    @Test func backAndForthFollowsDesktopChangesMadeByHand() async throws {
        let h = try started()
        // The user swipes to desktop 2 with the trackpad.
        h.platform.switchSpace(to: 7)
        #expect(await h.until { h.engine.desktopNumber() == 2 })
        h.engine.execute(.workspaceBackAndForth)
        #expect(h.platform.postedKeys.first?.keyCode == KeyCode.digits[0])
    }

    @Test func movingAWindowToAnotherDesktopExplainsHow() throws {
        let h = try started()
        for _ in 0..<5 { h.engine.execute(.moveNodeToWorkspace("2")) }
        let explained = h.ui.notices.filter { $0.key == "move-by-hand" }
        #expect(explained.count == 5)
        #expect(explained.filter(\.onScreen).count == 3, "shown three times, then only listed")
    }

    // E1: the menu's state names desktops, not groups, in native mode.
    @Test func uiStateListsNativeDesktops() async throws {
        let h = try started()
        #expect(h.ui.state?.nativeWorkspaces == true)
        #expect(h.ui.state?.desktopCount == 2)
        #expect(h.ui.state?.desktopNumber == 1)
        h.platform.switchSpace(to: 7)
        #expect(await h.until { h.ui.state?.desktopNumber == 2 })
        h.engine.perform(.jumpToDesktop(1))
        #expect(h.platform.postedKeys.first?.keyCode == KeyCode.digits[0])
    }

    // E5: VoiceOver moves every chord to Control+Option+Command, live.
    @Test func voiceOverSwitchesTheKeymap() async throws {
        let platform = FakePlatform()
        platform.dockClamp = 0
        platform.voiceOver = true
        let h = try started(platform)
        #expect(h.platform.registeredChords.allSatisfy { $0.flags.contains(.command) })
        h.platform.voiceOver = false
        h.platform.emit(.voiceOverChanged(false))
        #expect(h.platform.registeredChords.allSatisfy { $0.flags.contains([.control, .option]) })
        #expect(!h.platform.registeredChords.contains { $0.flags == [.control, .option, .command] })
        #expect(h.ui.noticeKeys().contains("keymap-voiceover"))
    }

    @Test func toggleFloatingDoesNotTakeTheInputSourceShortcut() {
        let toggle = Keymap.defaults().first { $0.name == "toggle-floating" }!
        #expect(toggle.chord == KeyChord(KeyCode.space, [.control, .option, .shift]))
        #expect(Keymap.clashes(Keymap.defaults(), with: FakePlatform.defaultSymbolicHotkeys()).isEmpty)
    }

    @Test func refusedHotkeysAreReported() throws {
        let platform = FakePlatform()
        platform.dockClamp = 0
        platform.refusedChords = [KeyChord(KeyCode.f, [.control, .option])]
        let h = try started(platform)
        #expect(h.ui.noticeKeys().contains("hotkeys-refused"))
    }

    @Test func hotkeysRunCommands() async throws {
        let h = try Harness()
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        let a = h.platform.open(pid: 10, notify: false)
        _ = h.platform.open(pid: 10, notify: false)
        try h.start()
        #expect(await h.until { h.engine.world.windows.count == 2 })
        h.engine.execute(.focusWindow(a))
        h.platform.press(KeyChord(KeyCode.m, [.control, .option]))
        #expect(h.engine.world.activeWorkspace?.layout == .monocle)
    }

    @Test func holdingTheModifiersShowsTheCheatsheet() async throws {
        let h = try started()
        h.platform.emit(.modifiersChanged([.control, .option]))
        #expect(await h.until { h.ui.cheatsheetShown.last == true })
        h.platform.emit(.modifiersChanged([]))
        #expect(h.ui.cheatsheetShown.last == false)
    }

    @Test func keymapTextFoldsDigitsAndArrows() {
        let lines = KeymapText.lines(Keymap.defaults())
        #expect(lines.count < Keymap.defaults().count)
        #expect(lines.contains { $0.contains("1…9") })
    }

    // E9: the local configuration file.
    @Test func localConfigurationApplies() async throws {
        let h = try Harness()
        try h.writeConfig("""
        [general]
        inner-gap = 10
        outer-gap = 10

        [apps]
        exclude = ["com.example.excluded"]
        float = ["com.example.floaty"]

        [keys]
        layout-monocle = "ctrl-alt-shift-m"
        """)
        h.platform.launch(pid: 10, bundleID: "com.example.a")
        h.platform.launch(pid: 20, bundleID: "com.example.excluded")
        h.platform.launch(pid: 30, bundleID: "com.example.floaty")
        let a = h.platform.open(pid: 10, notify: false)
        let excluded = h.platform.open(pid: 20, frame: Rect(5, 50, 300, 300), notify: false)
        let floaty = h.platform.open(pid: 30, notify: false)
        try h.start()
        #expect(await h.until { h.frame(a) == Rect(10, 40, 1060, 2428) })
        #expect(h.frame(excluded) == Rect(5, 50, 300, 300))
        #expect(h.engine.world.windows[excluded] == nil)
        #expect(h.engine.world.windows[floaty]?.mode == .floating)
        #expect(h.platform.registeredChords.contains(KeyChord(KeyCode.m, [.control, .option, .shift])))
    }

    @Test func brokenConfigurationIsReportedAndDefaultsApply() throws {
        let h = try Harness()
        try h.writeConfig("[general]\ninner-gap = lots\n")
        try h.start()
        #expect(h.ui.noticeKeys().contains("config-error"))
        #expect(h.engine.world.settings.innerGap == 0)
    }

    // B4 and the query handlers.
    @Test func mutatingRequestsAreRateLimited() throws {
        let h = try started()
        let request = try JSONEncoder().encode(IPCRequest(command: ["focus", "left"]))
        let replies = (0..<30).map { _ in try? JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(request)) }
        #expect(replies.contains { $0?.error == "rate limited" })
        #expect(replies.prefix(4).allSatisfy { $0?.ok == true })
    }

    @Test func queriesAnswer() throws {
        let h = try started()
        for query in ["stats", "state", "activity", "check"] {
            let reply = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(try JSONEncoder().encode(IPCRequest(query: query))))
            #expect(reply.error == nil, "\(query): \(reply.error ?? "")")
        }
        let stats = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(try JSONEncoder().encode(IPCRequest(query: "stats"))))
        #expect(stats.info?["version"]?.contains("Tessera") == true)
        #expect(stats.info?["status"] == "active")
        let malformed = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(Data("{".utf8)))
        #expect(malformed.error == "malformed request")
    }

    @Test func actionsOverTheSocket() throws {
        let h = try started()
        let pause = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(try JSONEncoder().encode(IPCRequest(action: "pause"))))
        #expect(pause.ok)
        #expect(h.engine.status == .paused(.user))
        let command = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(try JSONEncoder().encode(IPCRequest(command: ["balance-sizes"]))))
        #expect(command.error?.contains("paused") == true)
    }
}

extension DesktopAndInputTests {
    /// Audit B4: with a signed Tessera, only programs signed by the same team may send commands.
    @Test func commandsFromUnsignedClientsAreRefusedQueriesAreNot() throws {
        let h = try started()
        h.platform.peersTrusted = false
        let token = Data(repeating: 7, count: 32)
        let command = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(try JSONEncoder().encode(IPCRequest(command: ["balance-sizes"])), auditToken: token))
        #expect(command.ok == false && command.error?.contains("refused") == true)
        let action = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(try JSONEncoder().encode(IPCRequest(action: "pause")), auditToken: token))
        #expect(action.ok == false)
        #expect(h.engine.status == .active)
        let query = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(try JSONEncoder().encode(IPCRequest(query: "stats")), auditToken: token))
        #expect(query.ok)
        h.platform.peersTrusted = true
        let allowed = try JSONDecoder().decode(IPCResponse.self, from: h.engine.answer(try JSONEncoder().encode(IPCRequest(action: "pause")), auditToken: token))
        #expect(allowed.ok)
    }
}
