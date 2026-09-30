public enum Direction: String, Codable, Sendable, Hashable, CaseIterable {
    case left, right, up, down

    public var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    /// True when moving toward larger coordinates.
    public var isForward: Bool { self == .right || self == .down }
}

public enum Dimension: String, Codable, Sendable, Hashable {
    case width, height

    public var axis: Axis { self == .width ? .horizontal : .vertical }
}

/// What a user can ask for, from a hotkey or the CLI. Names follow AeroSpace's commands.
public enum Command: Codable, Sendable, Hashable {
    case focus(Direction)
    /// Focus a specific window, bringing its workspace forward if needed.
    case focusWindow(WindowID)
    case move(Direction)
    case workspace(String)
    case workspaceBackAndForth
    case moveNodeToWorkspace(String)
    case layout(LayoutMode)
    case toggleOrientation
    case toggleFloating
    case toggleFullscreen
    case balanceSizes
    case resize(Dimension, points: Int)
    /// Exchange two tiled windows of the active workspace (drag one onto the other).
    case swapWindows(WindowID, WindowID)
    /// The user resized a tiled window with the mouse to `frame`: share the space accordingly.
    case resizeWindow(WindowID, to: Rect)
    /// Float or tile a specific window, as the user's own choice (kept until changed).
    case setFloating(WindowID, Bool)
    /// Every window of the desktop into the visible group, Tessera full screen off.
    case gatherWindows
    /// Tile a window next to another one (a floating window dropped onto the tiling): in the
    /// anchor's container, before it or after it.
    case insertWindow(WindowID, beside: WindowID, after: Bool)
}

extension Command {
    /// Resizes beyond this are clamped: no screen is this large, and the weight arithmetic
    /// (points × 10⁶) must never overflow.
    public static let maxResize = 10_000

    /// Workspace names: short, printable, safe in a menu and a file name.
    public static func isValidWorkspaceName(_ name: String) -> Bool {
        guard (1...16).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || scalar == "_" || scalar == "-"
        }
    }
}
