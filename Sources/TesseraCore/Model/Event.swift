public struct SpaceDescriptor: Codable, Sendable, Hashable {
    public var id: SpaceID
    public var kind: SpaceKind

    public init(id: SpaceID, kind: SpaceKind) {
        self.id = id
        self.kind = kind
    }
}

/// What the platform saw about one window. Tessera's own hides never produce observations
/// with `isAppHidden` or `isMinimized`: the engine filters them out.
public struct WindowObservation: Codable, Sendable, Hashable {
    public var id: WindowID
    public var pid: Int32
    public var space: SpaceID?
    public var isNativeFullscreen: Bool
    public var isMinimized: Bool
    public var isAppHidden: Bool
    /// Dialogs, panels, fixed-size utility windows.
    public var prefersFloating: Bool
    /// "Assign to all desktops": on more than one Space. Such a window floats (plan I10), or
    /// it would be moved between trees on every Space switch.
    public var isOnAllSpaces: Bool

    public init(
        id: WindowID, pid: Int32, space: SpaceID?, isNativeFullscreen: Bool = false,
        isMinimized: Bool = false, isAppHidden: Bool = false, prefersFloating: Bool = false,
        isOnAllSpaces: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.space = space
        self.isNativeFullscreen = isNativeFullscreen
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
        self.prefersFloating = prefersFloating
        self.isOnAllSpaces = isOnAllSpaces
    }
}

public enum Event: Codable, Sendable, Hashable {
    case spacesChanged([SpaceDescriptor], active: SpaceID?)
    case windowObserved(WindowObservation)
    case windowGone(WindowID)
    case focusChanged(WindowID?)
    case factsLearned(WindowID, WindowFacts)
    case command(Command)
}
