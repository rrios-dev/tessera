import Foundation
import MCPKit
import Testing
import TesseraCore
import TesseraIPC
@testable import TesseraMCP

/// What an agent reads and asks through `tessera mcp`, against a recorded engine.
@Suite(.serialized)
struct TesseraToolsTests {
    static let state = """
    {"activeSpace":5,"focused":123,"area":{"x":0,"y":25,"width":1080,"height":2535},
     "spaces":[{"id":5,"kind":"desktop","activeWorkspace":"1","workspaces":[
        {"name":"1","layout":"tiles","tiled":[123,456],"floating":[789]},
        {"name":"2","layout":"accordion","tiled":[],"floating":[]}]},
       {"id":9,"kind":"fullscreen","activeWorkspace":"1","workspaces":[{"name":"1","layout":"tiles","tiled":[],"floating":[]}]}],
     "frames":{"123":{"x":0,"y":25,"width":1080,"height":1260},"456":{"x":0,"y":1285,"width":1080,"height":1275}},
     "observed":{},"hidden":[],"facts":{},"mismatches":[],"overflowed":0,"reflowed":0}
    """

    final class Engine: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [IPCRequest] = []
        var reply: IPCResponse = IPCResponse(ok: true)
        var sent: [[String]] { lock.withLock { requests.map { $0.command ?? [$0.action ?? $0.query ?? ""] } } }
        func record(_ request: IPCRequest) -> IPCResponse {
            lock.withLock { requests.append(request) }
            if request.query == "state" {
                return IPCResponse(ok: true, state: try? JSONDecoder().decode(StateSnapshot.self, from: Data(TesseraToolsTests.state.utf8)))
            }
            return reply
        }
    }

    private func tools(_ engine: Engine) -> TesseraTools {
        TesseraTools(send: { engine.record($0) }, owners: { ids in
            let known: [WindowID: WindowOwner] = [
                123: WindowOwner(name: "Safari", bundleID: "com.apple.Safari"),
                456: WindowOwner(name: "Terminal", bundleID: "com.apple.Terminal"),
            ]
            return known.filter { ids.contains($0.key) }
        })
    }

    private func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    @Test func layoutNamesWindowsByAppNeverByTitle() async throws {
        let engine = Engine()
        let result = try await tools(engine).getLayout.run(Arguments())
        let output = text(result)
        #expect(output.contains("Focused: window 123 (Safari)"))
        #expect(output.contains("Desktop 5 · desktop · on screen"))
        #expect(output.contains("  Workspace 1 · tiles · active"))
        #expect(output.contains("    - 123 Safari (com.apple.Safari) · 0,25 1080×1260 · focused"))
        #expect(output.contains("    - 789 unknown app · floating"))
        #expect(output.contains("  Workspace 2 · accordion"))
        #expect(output.contains("(native full screen: Tessera leaves it alone)"))
        #expect(result.structured?["focused"] == 123)
        #expect(engine.sent == [["state"]])
    }

    @Test func windowCommandsFocusTheWindowFirst() async throws {
        let engine = Engine()
        let tools = tools(engine)
        _ = try await tools.moveWindow.run(Arguments(["direction": "left", "window_id": 456]))
        _ = try await tools.moveToWorkspace.run(Arguments(["workspace": "2"]))
        _ = try await tools.resize.run(Arguments(["dimension": "width", "points": -40, "window_id": 123]))
        _ = try await tools.resize.run(Arguments(["dimension": "height", "points": 25]))
        #expect(engine.sent == [
            ["state"], ["focus", "--window-id", "456"], ["move", "left"],
            ["move-node-to-workspace", "2"],
            ["state"], ["focus", "--window-id", "123"], ["resize", "width", "-40"],
            ["resize", "height", "+25"],
        ])
    }

    @Test func layoutsAndEngineActions() async throws {
        let engine = Engine()
        let tools = tools(engine)
        _ = try await tools.setLayout.run(Arguments(["layout": "toggle-orientation"]))
        _ = try await tools.switchWorkspace.run(Arguments(["workspace": "2"]))
        _ = try await tools.engine.run(Arguments(["action": "retile"]))
        #expect(engine.sent == [["layout", "toggle-orientation"], ["workspace", "2"], ["retile"]])
    }

    @Test func badArgumentsAreExplained() async throws {
        let tools = tools(Engine())
        await #expect(throws: ToolError.invalid("direction", "must be one of: left, right, up, down")) {
            try await tools.focus.run(Arguments(["direction": "sideways"]))
        }
        await #expect(throws: ToolError.invalid("points", "must be a non-zero number of points")) {
            try await tools.resize.run(Arguments(["dimension": "width", "points": 0]))
        }
        await #expect(throws: ToolError.self) { try await tools.engine.run(Arguments(["action": "uninstall"])) }
    }

    @Test func refusalsAndAStoppedEngineReachTheAgentAsText() async throws {
        let engine = Engine()
        engine.reply = IPCResponse(ok: false, error: "rate limited")
        await #expect(throws: ToolError("Tessera refused: rate limited.")) {
            try await tools(engine).balance.run(Arguments())
        }
        let stopped = TesseraTools(send: { _ in throw CocoaError(.fileNoSuchFile) }, owners: { _ in [:] })
        await #expect(throws: ToolError("Tessera is not running. The user can start it from Tessera.app or with `tessera run`.")) {
            try await stopped.getLayout.run(Arguments())
        }
    }

    @Test func aWindowThatIsNotThereIsNotReportedAsDone() async throws {
        let engine = Engine()
        await #expect(throws: ToolError("No window 999999 in Tessera's layout. get_layout lists the windows it manages.")) {
            try await tools(engine).focusWindow.run(Arguments(["window_id": 999999]))
        }
        await #expect(throws: ToolError.self) {
            try await tools(engine).moveWindow.run(Arguments(["direction": "up", "window_id": 999999]))
        }
        #expect(engine.sent == [["state"], ["state"]], "nothing is sent to the engine but the lookups")
        _ = try await tools(engine).focusWindow.run(Arguments(["window_id": 789]))
        #expect(engine.sent.last == ["focus", "--window-id", "789"], "a floating window counts")
    }

    @Test func reasonsReadAsOneSentence() {
        #expect(TesseraTools.reason("refused: only programs signed by Tessera's developer may send commands") == "only programs signed by Tessera's developer may send commands")
        #expect(TesseraTools.reason("there is no desktop 2: this display has 1. Add more in Mission Control.") == "there is no desktop 2: this display has 1. Add more in Mission Control")
        #expect(TesseraTools.reason(nil) == "no reason given")
    }

    @Test func engineActionsSayTheStateTesseraEndsIn() async throws {
        let engine = Engine()
        engine.reply = IPCResponse(ok: true, info: ["status": "active"])
        #expect(text(try await tools(engine).engine.run(Arguments(["action": "retile"]))) == "Done: retile. Tessera is now active.")
    }

    @Test func aServerOlderThanTheInstallIsToldToReconnect() async throws {
        let engine = Engine()
        engine.reply = IPCResponse(ok: false, error: "refused: only programs signed by Tessera's developer may send commands")
        let fresh = TesseraTools(send: { engine.record($0) }, owners: { _ in [:] }, replaced: { false })
        await #expect(throws: ToolError("Tessera refused: only programs signed by Tessera's developer may send commands.")) {
            try await fresh.balance.run(Arguments())
        }
        let stale = TesseraTools(send: { engine.record($0) }, owners: { _ in [:] }, replaced: { true })
        await #expect(throws: ToolError(TesseraTools.reconnect)) { try await stale.balance.run(Arguments()) }
    }

    @Test func onlyTheLayoutIsReadOnly() {
        let all = tools(Engine()).all
        #expect(all.filter(\.annotations.readOnly).map(\.name) == ["get_layout"])
        #expect(Set(all.map(\.name)).count == all.count)
    }
}
