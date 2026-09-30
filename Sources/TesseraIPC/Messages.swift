public import TesseraCore

/// One request per line from the CLI to the engine.
public struct IPCRequest: Codable, Sendable {
    /// A command in CLI words, e.g. `["focus", "left"]`.
    public var command: [String]?
    /// `state` returns a title-free snapshot of the model; `stats` counters and engine info;
    /// `check` the invariant violations; `activity` the recent notices.
    public var query: String?
    /// An app-level action (`CommandParser.actions`).
    public var action: String?

    public init(command: [String]? = nil, query: String? = nil, action: String? = nil) {
        self.command = command
        self.query = query
        self.action = action
    }

    /// Commands that change something; rate-limited and, later, gated by the caller's code
    /// signature (audit B4).
    public var isMutating: Bool { command != nil || action != nil }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var state: StateSnapshot?
    /// Work counters (`tessera debug stats`).
    public var stats: [String: Int]?
    /// Version, status, uptime, last error (`tessera debug stats`).
    public var info: [String: String]?
    /// Lines of text: recent activity, invariant violations.
    public var lines: [String]?

    public init(ok: Bool, error: String? = nil, state: StateSnapshot? = nil, stats: [String: Int]? = nil, info: [String: String]? = nil, lines: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.state = state
        self.stats = stats
        self.info = info
        self.lines = lines
    }
}

/// What `tessera debug state` prints. Window ids only, never titles.
public struct StateSnapshot: Codable, Sendable, Equatable {
    public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
        public var name: String
        public var layout: LayoutMode
        public var tiled: [WindowID]
        public var floating: [WindowID]
        public var zoomed: WindowID?
    }

    public struct SpaceSnapshot: Codable, Sendable, Equatable {
        public var id: SpaceID
        public var kind: SpaceKind
        public var activeWorkspace: String
        public var workspaces: [WorkspaceSnapshot]
    }

    public var activeSpace: SpaceID?
    public var focused: WindowID?
    /// The area windows can really occupy: usable area minus the learned edge clamp.
    public var area: Rect?
    public var spaces: [SpaceSnapshot]
    /// Target frame of every window the active Space shows.
    public var frames: [String: Rect]
    /// Frames the window server draws for those windows.
    public var observed: [String: Rect]
    /// The same windows' frames as Accessibility reports them. macOS 26 draws a 1-point outline
    /// around some windows, so the window server's bounds can be one point larger on every side.
    public var accessibility: [String: Rect]?
    public var hidden: [WindowID]
    public var facts: [String: WindowFacts]
    /// Tiled windows whose drawn frame differs from the target.
    public var mismatches: [WindowID]
    /// Containers drawn as accordions because their windows fit neither way (overlap by design).
    public var overflowed: Int
    /// Containers drawn along the other axis because their windows did not fit side by side.
    public var reflowed: Int

    public init(world: World, render: Render, observed: [WindowID: Rect], area: Rect? = nil, accessibility: [WindowID: Rect]? = nil) {
        self.area = area
        self.accessibility = accessibility.map { Dictionary(uniqueKeysWithValues: $0.map { (String($0.key), $0.value) }) }
        activeSpace = world.activeSpace
        focused = world.focused
        spaces = world.spaces.values.sorted { $0.id < $1.id }.map { space in
            SpaceSnapshot(
                id: space.id, kind: space.kind, activeWorkspace: space.activeWorkspace,
                workspaces: space.workspaces.map {
                    WorkspaceSnapshot(name: $0.name, layout: $0.layout, tiled: $0.root.windows, floating: $0.floating, zoomed: $0.zoomed)
                }
            )
        }
        frames = Dictionary(uniqueKeysWithValues: render.frames.map { (String($0.key), $0.value) })
        self.observed = Dictionary(uniqueKeysWithValues: observed.map { (String($0.key), $0.value) })
        hidden = render.hidden.sorted()
        facts = Dictionary(uniqueKeysWithValues: world.facts.map { (String($0.key), $0.value) })
        overflowed = render.plan.overflowed
        reflowed = render.plan.reflowed
        mismatches = render.frames.compactMap { id, target in observed[id].map { $0 == target ? nil : id } ?? nil }.sorted()
    }
}
