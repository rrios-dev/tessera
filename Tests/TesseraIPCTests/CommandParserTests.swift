import Testing
import TesseraCore
@testable import TesseraIPC

struct CommandParserTests {
    @Test func parsesAeroSpaceStyleCommands() throws {
        #expect(try CommandParser.parse(["focus", "left"]) == .focus(.left))
        #expect(try CommandParser.parse(["move", "down"]) == .move(.down))
        #expect(try CommandParser.parse(["workspace", "3"]) == .workspace("3"))
        #expect(try CommandParser.parse(["workspace", "back-and-forth"]) == .workspaceBackAndForth)
        #expect(try CommandParser.parse(["move-node-to-workspace", "web"]) == .moveNodeToWorkspace("web"))
        #expect(try CommandParser.parse(["layout", "monocle"]) == .layout(.monocle))
        #expect(try CommandParser.parse(["layout", "floating"]) == .toggleFloating)
        #expect(try CommandParser.parse(["resize", "height", "+50"]) == .resize(.height, points: 50))
        #expect(try CommandParser.parse(["resize", "width", "-20"]) == .resize(.width, points: -20))
        #expect(try CommandParser.parse(["fullscreen"]) == .toggleFullscreen)
        #expect(try CommandParser.parse(["focus", "--window-id", "42"]) == .focusWindow(42))
    }

    @Test func rejectsMalformedCommands() {
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["focus"]) }
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["focus", "sideways"]) }
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["resize", "depth", "5"]) }
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["teleport"]) }
    }
}

/// Audit B1, B2: hostile input is rejected before it reaches the engine.
struct CommandParserBoundsTests {
    @Test func rejectsHugeResizes() throws {
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["resize", "width", "9223372036854775807"]) }
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["resize", "width", "-10001"]) }
        #expect(try CommandParser.parse(["resize", "width", "+10000"]) == .resize(.width, points: 10_000))
    }

    @Test func rejectsWorkspaceNamesOutsideTheGrammar() {
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["workspace", "a b"]) }
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["workspace", String(repeating: "9", count: 17)]) }
        #expect(throws: CommandParser.Failure.self) { try CommandParser.parse(["move-node-to-workspace", "../x"]) }
    }
}
