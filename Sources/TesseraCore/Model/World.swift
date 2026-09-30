/// A native macOS Space, as SkyLight identifies it (`ManagedSpaceID`).
public typealias SpaceID = UInt64

public enum SpaceKind: String, Codable, Sendable, Hashable {
    /// An ordinary desktop: Tessera tiles it.
    case desktop
    /// A Space macOS created for an app in native full screen: Tessera leaves it alone.
    case fullscreen
}

public enum LayoutMode: String, Codable, Sendable, Hashable, CaseIterable {
    case tiles, accordion, monocle
}

public enum WindowMode: String, Codable, Sendable, Hashable {
    case tiled
    case floating
    /// In a native full-screen Space; macOS owns its frame.
    case nativeFullscreen
    case minimized
    /// Its app was hidden by the user (Cmd-H).
    case appHidden
}

public struct WindowRecord: Codable, Sendable, Hashable {
    public var id: WindowID
    public var pid: Int32
    public var space: SpaceID
    public var workspace: String
    public var mode: WindowMode
    /// The user's own float/tile choice (toggle-floating). Wins over every heuristic until the
    /// window closes, so a tiled dialog stays tiled and a floated window comes back floating
    /// after being minimised or hidden.
    public var userFloating: Bool?

    public init(id: WindowID, pid: Int32, space: SpaceID, workspace: String, mode: WindowMode, userFloating: Bool? = nil) {
        self.id = id
        self.pid = pid
        self.space = space
        self.workspace = workspace
        self.mode = mode
        self.userFloating = userFloating
    }
}

/// A Tessera desktop inside a native Space. Every Space has at least one.
public struct Workspace: Codable, Sendable, Hashable {
    public var name: String
    public var root: Container
    public var layout: LayoutMode
    /// Windows that float, front to back.
    public var floating: [WindowID]
    /// Most recently focused first.
    public var mru: [WindowID]
    /// Tessera full screen: this window covers the whole desktop, the tiling stays behind it.
    public var zoomed: WindowID?

    public init(name: String, layout: LayoutMode = .tiles) {
        self.name = name
        self.root = Container()
        self.layout = layout
        self.floating = []
        self.mru = []
        self.zoomed = nil
    }

    public var windows: [WindowID] { root.windows + floating }
    public var isEmpty: Bool { root.isEmpty && floating.isEmpty }
}

public struct SpaceState: Codable, Sendable, Hashable {
    public var id: SpaceID
    public var kind: SpaceKind
    public var workspaces: [Workspace]
    public var activeWorkspace: String
    /// The workspace shown before the current one, for `workspace-back-and-forth`.
    public var previousWorkspace: String?

    public init(id: SpaceID, kind: SpaceKind, firstWorkspace: String = "1", layout: LayoutMode = .tiles) {
        self.id = id
        self.kind = kind
        self.workspaces = [Workspace(name: firstWorkspace, layout: layout)]
        self.activeWorkspace = firstWorkspace
    }

    public func workspace(named name: String) -> Workspace? { workspaces.first { $0.name == name } }

    public mutating func modifyWorkspace(named name: String, _ body: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.name == name }) else { return }
        body(&workspaces[index])
    }

    public mutating func ensureWorkspace(named name: String, layout: LayoutMode) {
        guard workspace(named: name) == nil else { return }
        workspaces.append(Workspace(name: name, layout: layout))
        workspaces.sort { $0.name.localizedStandardLess(than: $1.name) }
    }
}

/// What a container does when its windows' minimums do not fit side by side nor stacked.
/// The default floats the window with the largest minimum: stacking everything at full size
/// left the owner with windows they could neither resize nor tell apart (2026-09-26).
public enum OverflowPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Overlap as an accordion (up to `maxAccordionStrips` windows), else `stack`.
    case accordion
    /// Every window gets the whole container, the most recently focused in front.
    case stack
    /// Take the window with the largest minimum out of the tiling (auto-floated, centred) until
    /// the rest fits.
    case floatLargest
    /// Keep the split and let windows extend past the area.
    case allow

    /// More strips than this and an accordion stops being readable.
    public static let maxAccordionStrips = 4
}

public struct WorldSettings: Codable, Sendable, Hashable {
    public var defaultLayout: LayoutMode
    public var innerGap: Int
    public var outerGap: Int
    public var accordionPadding: Int
    public var overflow: OverflowPolicy

    /// Gaps above this are almost certainly a typo; they are clamped rather than obeyed.
    public static let maxGap = 200

    public init(defaultLayout: LayoutMode = .tiles, innerGap: Int = 0, outerGap: Int = 0, accordionPadding: Int = 30, overflow: OverflowPolicy = .floatLargest) {
        self.defaultLayout = defaultLayout
        self.innerGap = min(max(innerGap, 0), Self.maxGap)
        self.outerGap = min(max(outerGap, 0), Self.maxGap)
        self.accordionPadding = min(max(accordionPadding, 0), Self.maxGap)
        self.overflow = overflow
    }
}

/// Everything Tessera knows, as one immutable value. Only `Reducer` produces new worlds.
public struct World: Codable, Sendable, Hashable {
    public var spaces: [SpaceID: SpaceState] = [:]
    public var activeSpace: SpaceID?
    public var windows: [WindowID: WindowRecord] = [:]
    public var facts: [WindowID: WindowFacts] = [:]
    public var focused: WindowID?
    public var settings: WorldSettings

    public init(settings: WorldSettings = WorldSettings()) {
        self.settings = settings
    }

    public var activeSpaceState: SpaceState? { activeSpace.flatMap { spaces[$0] } }

    public var activeWorkspace: Workspace? {
        guard let space = activeSpaceState else { return nil }
        return space.workspace(named: space.activeWorkspace)
    }

    public func workspace(of window: WindowID) -> Workspace? {
        guard let record = windows[window] else { return nil }
        return spaces[record.space]?.workspace(named: record.workspace)
    }

    mutating func modifyWorkspace(space: SpaceID, name: String, _ body: (inout Workspace) -> Void) {
        spaces[space]?.modifyWorkspace(named: name, body)
    }
}

extension String {
    /// "2" < "10", like Finder. Implemented without Foundation.
    func localizedStandardLess(than other: String) -> Bool {
        switch (Int(self), Int(other)) {
        case let (left?, right?): left < right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): self < other
        }
    }
}
