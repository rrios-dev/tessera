public import TesseraCore

/// Parses the CLI grammar, which follows AeroSpace's command names where they overlap.
public enum CommandParser {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public static let usage = """
    focus left|right|up|down | focus --window-id <id>
    move left|right|up|down
    workspace <name> | workspace-back-and-forth
    move-node-to-workspace <name>
    layout tiles|accordion|monocle|toggle-orientation|floating|tiling
    fullscreen
    balance-sizes
    resize width|height +N|-N
    """

    public static func parse(_ arguments: [String]) throws(Failure) -> Command {
        guard let verb = arguments.first else { throw Failure(description: "missing command") }
        let rest = Array(arguments.dropFirst())

        func single() throws(Failure) -> String {
            guard rest.count == 1 else { throw Failure(description: "\(verb) takes exactly one argument") }
            return rest[0]
        }
        func direction() throws(Failure) -> Direction {
            let word = try single()
            guard let direction = Direction(rawValue: word) else { throw Failure(description: "unknown direction '\(word)'") }
            return direction
        }

        switch verb {
        case "focus":
            if rest.count == 2, rest[0] == "--window-id" {
                guard let id = WindowID(rest[1]) else { throw Failure(description: "invalid window id '\(rest[1])'") }
                return .focusWindow(id)
            }
            return .focus(try direction())
        case "move": return .move(try direction())
        case "workspace":
            let name = try single()
            if name == "back-and-forth" { return .workspaceBackAndForth }
            return .workspace(try workspaceName(name))
        case "workspace-back-and-forth": return .workspaceBackAndForth
        case "move-node-to-workspace": return .moveNodeToWorkspace(try workspaceName(try single()))
        case "fullscreen": return .toggleFullscreen
        case "balance-sizes": return .balanceSizes
        case "layout":
            switch try single() {
            case "tiles": return .layout(.tiles)
            case "accordion": return .layout(.accordion)
            case "monocle": return .layout(.monocle)
            case "toggle-orientation", "horizontal", "vertical": return .toggleOrientation
            case "floating", "tiling": return .toggleFloating
            case let other: throw Failure(description: "unknown layout '\(other)'")
            }
        case "resize":
            guard rest.count == 2, let dimension = Dimension(rawValue: rest[0]),
                  let amount = Int(rest[1].hasPrefix("+") ? String(rest[1].dropFirst()) : rest[1])
            else { throw Failure(description: "usage: resize width|height +N|-N") }
            guard abs(amount) <= Command.maxResize else { throw Failure(description: "resize by at most \(Command.maxResize) points") }
            return .resize(dimension, points: amount)
        default:
            throw Failure(description: "unknown command '\(verb)'")
        }
    }

    static func workspaceName(_ name: String) throws(Failure) -> String {
        guard Command.isValidWorkspaceName(name) else {
            throw Failure(description: "workspace names are 1–16 letters, digits, '-' or '_'")
        }
        return name
    }

    /// App-level actions, answered by the engine rather than the model.
    public static let actions = ["pause", "resume", "toggle-pause", "gather", "retile", "reload-config", "revert-layout", "retry", "forget-sizes"]
}
