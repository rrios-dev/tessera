public import Foundation
public import MCPKit
public import TesseraCore
public import TesseraIPC

/// The app a window belongs to: its name and bundle identifier. Never its title.
public struct WindowOwner: Sendable, Equatable {
    public var name: String
    public var bundleID: String?

    public init(name: String, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }
}

/// The tools `tessera mcp` offers (ADR 0005): the layout to read, and the engine's own
/// commands to run, over the same socket and the same checks as the CLI.
public struct TesseraTools: Sendable {
    /// One request to the running engine.
    public let send: @Sendable (IPCRequest) async throws -> IPCResponse
    /// Who owns each window, from the window server.
    public let owners: @Sendable ([WindowID]) -> [WindowID: WindowOwner]
    /// Whether Tessera was reinstalled after this server started. macOS then no longer vouches
    /// for the running process's signature, and the engine refuses its commands.
    public let replaced: @Sendable () -> Bool

    public init(
        send: (@Sendable (IPCRequest) async throws -> IPCResponse)? = nil,
        owners: @escaping @Sendable ([WindowID]) -> [WindowID: WindowOwner],
        replaced: @escaping @Sendable () -> Bool = { false }
    ) {
        self.send = send ?? Self.socket
        self.owners = owners
        self.replaced = replaced
    }

    public static let reconnect = ExecutableIdentity.reconnectMessage(app: "Tessera", server: "tessera", refused: "refuses its commands")

    /// The engine's socket, as the CLI reaches it.
    @Sendable static func socket(_ request: IPCRequest) async throws -> IPCResponse {
        try await Task.detached {
            let reply = try LineSocket.request(try JSONEncoder().encode(request))
            return try JSONDecoder().decode(IPCResponse.self, from: reply)
        }.value
    }

    public static let instructions = """
        Tessera tiles the user's windows on macOS. get_layout shows desktops (Spaces), \
        Tessera's workspaces in each, and every window by id and app — never by title. \
        Commands act on the focused window unless they take a window_id: focus a window \
        first, then move or resize it. Native full-screen Spaces are left alone by design.
        """

    public var all: [Tool] {
        [getLayout, focusWindow, focus, moveWindow, moveToWorkspace, switchWorkspace, setLayout, resize, toggleFullscreen, balance, engine]
    }

    // MARK: Reading

    var getLayout: Tool {
        Tool(
            name: "get_layout",
            title: "Get the window layout",
            description: "Desktops, Tessera's workspaces in each, and every window with its id, app, frame and whether it is focused, tiled or floating. Windows are never shown by title.",
            inputSchema: Schema.object()
        ) { _ in
            let response = try await request(IPCRequest(query: "state"))
            guard let state = response.state else { throw ToolError("Tessera did not return its state.") }
            return Self.describe(state, owners: owners(Self.windows(in: state)))
        }
    }

    static func windows(in state: StateSnapshot) -> [WindowID] {
        state.spaces.flatMap { $0.workspaces.flatMap { $0.tiled + $0.floating } }
    }

    static func describe(_ state: StateSnapshot, owners: [WindowID: WindowOwner]) -> ToolResult {
        func window(_ id: WindowID, floating: Bool) -> (String, JSONValue) {
            let owner = owners[id]
            var line = "- \(id) \(owner?.name ?? "unknown app")"
            if let bundle = owner?.bundleID { line += " (\(bundle))" }
            if let frame = state.frames[String(id)] { line += " · \(frame.x),\(frame.y) \(frame.width)×\(frame.height)" }
            if floating { line += " · floating" }
            if state.hidden.contains(id) { line += " · hidden" }
            if state.focused == id { line += " · focused" }
            var object: [String: JSONValue] = [
                "id": .int(Int(id)), "app": owner.map { .string($0.name) } ?? .null,
                "bundleId": owner?.bundleID.map(JSONValue.string) ?? .null,
                "floating": .bool(floating), "focused": .bool(state.focused == id),
            ]
            if let frame = state.frames[String(id)] {
                object["frame"] = ["x": .int(frame.x), "y": .int(frame.y), "width": .int(frame.width), "height": .int(frame.height)]
            }
            return (line, .object(object))
        }

        var lines: [String] = []
        if let focused = state.focused { lines.append("Focused: window \(focused) (\(owners[focused]?.name ?? "unknown app"))") }
        if let area = state.area { lines.append("Usable area: \(area.x),\(area.y) \(area.width)×\(area.height)") }
        var spaces: [JSONValue] = []
        for space in state.spaces {
            let active = space.id == state.activeSpace
            lines.append("")
            lines.append("Desktop \(space.id) · \(space.kind.rawValue)\(active ? " · on screen" : "")"
                + (space.kind == .fullscreen ? " (native full screen: Tessera leaves it alone)" : ""))
            var workspaces: [JSONValue] = []
            for workspace in space.workspaces {
                let current = workspace.name == space.activeWorkspace
                lines.append("  Workspace \(workspace.name) · \(workspace.layout.rawValue)\(current ? " · active" : "")")
                let tiled = workspace.tiled.map { window($0, floating: false) }
                let floating = workspace.floating.map { window($0, floating: true) }
                for (line, _) in tiled + floating { lines.append("    " + line) }
                if tiled.isEmpty && floating.isEmpty { lines.append("    (empty)") }
                workspaces.append([
                    "name": .string(workspace.name), "layout": .string(workspace.layout.rawValue), "active": .bool(current),
                    "windows": .array((tiled + floating).map(\.1)),
                ])
            }
            spaces.append([
                "id": .string(String(space.id)), "kind": .string(space.kind.rawValue), "onScreen": .bool(active),
                "workspaces": .array(workspaces),
            ])
        }
        return .text(lines.joined(separator: "\n"), structured: [
            "focused": state.focused.map { .int(Int($0)) } ?? .null,
            "desktops": .array(spaces),
        ])
    }

    // MARK: Commands

    var focusWindow: Tool {
        Tool(
            name: "focus_window",
            title: "Focus a window",
            description: "Focuses a window by its id from get_layout, switching to its workspace if needed.",
            inputSchema: Schema.object(["window_id": Schema.integer("A window id from get_layout.", minimum: 0)], required: ["window_id"]),
            annotations: .action
        ) { arguments in
            let id = try windowID(arguments)
            try await requireWindow(id)
            return try await command(["focus", "--window-id", String(id)])
        }
    }

    var focus: Tool {
        Tool(
            name: "focus",
            title: "Move the focus",
            description: "Moves the focus to the neighbouring window in a direction.",
            inputSchema: Schema.object(["direction": Self.direction], required: ["direction"]),
            annotations: .action
        ) { arguments in
            try await command(["focus", try Self.choice(arguments, "direction", Direction.allCases.map(\.rawValue))])
        }
    }

    var moveWindow: Tool {
        Tool(
            name: "move_window",
            title: "Move a window",
            description: "Moves a window (the focused one, or window_id) one place in a direction within the layout.",
            inputSchema: Schema.object([
                "direction": Self.direction,
                "window_id": Schema.integer("A window id from get_layout. Default: the focused window.", minimum: 0),
            ], required: ["direction"]),
            annotations: .action
        ) { arguments in
            let direction = try Self.choice(arguments, "direction", Direction.allCases.map(\.rawValue))
            try await focusFirst(arguments)
            return try await command(["move", direction])
        }
    }

    var moveToWorkspace: Tool {
        Tool(
            name: "move_to_workspace",
            title: "Move a window to a workspace",
            description: "Moves a window (the focused one, or window_id) to another workspace of the same desktop.",
            inputSchema: Schema.object([
                "workspace": Schema.string("The workspace's name, as get_layout shows it."),
                "window_id": Schema.integer("A window id from get_layout. Default: the focused window.", minimum: 0),
            ], required: ["workspace"]),
            annotations: .action
        ) { arguments in
            let workspace = try arguments.string("workspace")
            try await focusFirst(arguments)
            return try await command(["move-node-to-workspace", workspace])
        }
    }

    var switchWorkspace: Tool {
        Tool(
            name: "switch_workspace",
            title: "Switch workspace",
            description: "Shows another workspace of the current desktop.",
            inputSchema: Schema.object(["workspace": Schema.string("The workspace's name, as get_layout shows it.")], required: ["workspace"]),
            annotations: .action
        ) { arguments in
            try await command(["workspace", try arguments.string("workspace")])
        }
    }

    var setLayout: Tool {
        Tool(
            name: "set_layout",
            title: "Change the layout",
            description: "tiles, accordion or monocle for the focused window's container; toggle-orientation turns rows into columns; floating toggles the focused window between floating and tiled.",
            inputSchema: Schema.object([
                "layout": Schema.string("The layout.", enum: ["tiles", "accordion", "monocle", "toggle-orientation", "floating"]),
            ], required: ["layout"]),
            annotations: .action
        ) { arguments in
            try await command(["layout", try Self.choice(arguments, "layout", ["tiles", "accordion", "monocle", "toggle-orientation", "floating"])])
        }
    }

    var resize: Tool {
        Tool(
            name: "resize",
            title: "Resize a window",
            description: "Grows or shrinks a window (the focused one, or window_id) by a number of points.",
            inputSchema: Schema.object([
                "dimension": Schema.string("Which side.", enum: ["width", "height"]),
                "points": Schema.integer("Points to add; negative to shrink.", minimum: -4000, maximum: 4000),
                "window_id": Schema.integer("A window id from get_layout. Default: the focused window.", minimum: 0),
            ], required: ["dimension", "points"]),
            annotations: .action
        ) { arguments in
            let dimension = try Self.choice(arguments, "dimension", ["width", "height"])
            guard let points = try arguments.optionalInt("points", in: -4000...4000), points != 0 else {
                throw ToolError.invalid("points", "must be a non-zero number of points")
            }
            try await focusFirst(arguments)
            return try await command(["resize", dimension, points > 0 ? "+\(points)" : "\(points)"])
        }
    }

    var toggleFullscreen: Tool {
        Tool(
            name: "toggle_fullscreen",
            title: "Toggle full size",
            description: "Makes the focused window fill the desktop, or returns it to the layout. Tessera's own full size, not macOS's full-screen Space.",
            inputSchema: Schema.object(),
            annotations: .action
        ) { _ in try await command(["fullscreen"]) }
    }

    var balance: Tool {
        Tool(
            name: "balance_sizes",
            title: "Balance sizes",
            description: "Gives the windows of the focused container equal sizes.",
            inputSchema: Schema.object(),
            annotations: .action
        ) { _ in try await command(["balance-sizes"]) }
    }

    static let engineActions = ["retile", "pause", "resume", "revert-layout"]

    var engine: Tool {
        Tool(
            name: "engine",
            title: "Tessera engine",
            description: "retile lays every window out again; pause stops tiling until resume; revert-layout puts windows back where they were before Tessera arranged them.",
            inputSchema: Schema.object(["action": Schema.string("What to do.", enum: Self.engineActions)], required: ["action"]),
            annotations: .action
        ) { arguments in
            let action = try Self.choice(arguments, "action", Self.engineActions)
            let response = try await request(IPCRequest(action: action))
            // The state Tessera ends in, since actions change it: retile resumes a pause,
            // revert-layout pauses.
            let status = response.info?["status"].map { " Tessera is now \($0)." } ?? ""
            return .text("Done: \(action).\(status)")
        }
    }

    // MARK: Plumbing

    static let direction = Schema.string("The direction.", enum: Direction.allCases.map(\.rawValue))

    static func choice(_ arguments: Arguments, _ key: String, _ allowed: [String]) throws -> String {
        let value = try arguments.string(key)
        guard allowed.contains(value) else { throw ToolError.invalid(key, "must be one of: \(allowed.joined(separator: ", "))") }
        return value
    }

    func windowID(_ arguments: Arguments) throws -> WindowID {
        guard let id = try arguments.optionalInt("window_id", in: 0...Int(UInt32.max)) else { throw ToolError.missing("window_id") }
        return WindowID(id)
    }

    func focusFirst(_ arguments: Arguments) async throws {
        guard arguments["window_id"] != nil else { return }
        let id = try windowID(arguments)
        try await requireWindow(id)
        _ = try await request(IPCRequest(command: ["focus", "--window-id", String(id)]))
    }

    /// The engine ignores a focus request for a window it does not manage and answers ok, so
    /// the agent would be told "Done" for nothing (found by the live audit, 2026-10-14).
    func requireWindow(_ id: WindowID) async throws {
        let response = try await request(IPCRequest(query: "state"))
        guard let state = response.state, Self.windows(in: state).contains(id) else {
            throw ToolError("No window \(id) in Tessera's layout. get_layout lists the windows it manages.")
        }
    }

    func command(_ words: [String]) async throws -> ToolResult {
        _ = try await request(IPCRequest(command: words))
        return .text("Done: \(words.joined(separator: " ")).")
    }

    /// One engine request; its refusals become messages the model can act on.
    func request(_ request: IPCRequest) async throws -> IPCResponse {
        let response: IPCResponse
        do {
            response = try await send(request)
        } catch {
            throw ToolError("Tessera is not running. The user can start it from Tessera.app or with `tessera run`.")
        }
        guard response.ok else {
            if response.error?.contains("signed by Tessera's developer") == true, replaced() {
                throw ToolError(Self.reconnect)
            }
            throw ToolError("Tessera refused: \(Self.reason(response.error)).")
        }
        return response
    }

    /// The engine's reason as one clean sentence: no doubled "refused", no doubled stop.
    static func reason(_ error: String?) -> String {
        var text = (error ?? "no reason given").trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("refused:") { text = String(text.dropFirst("refused:".count)).trimmingCharacters(in: .whitespaces) }
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
