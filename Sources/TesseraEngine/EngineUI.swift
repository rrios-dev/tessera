public import Foundation
public import TesseraConfig
public import TesseraCore

/// Something the engine tells the user: shown in the on-screen display, announced to VoiceOver
/// and kept in "Actividad reciente" (audit E2).
public struct Notice: Sendable, Equatable {
    public enum Kind: String, Sendable { case info, warning, error }

    /// Stable identifier, for de-duplication and tests.
    public var key: String
    public var kind: Kind
    public var text: String
    /// Also shown on screen (otherwise only listed and announced).
    public var onScreen: Bool

    public init(_ key: String, _ kind: Kind = .info, _ text: String, onScreen: Bool = true) {
        self.key = key
        self.kind = kind
        self.text = text
        self.onScreen = onScreen
    }
}

public struct ActivityEntry: Sendable, Equatable {
    public var at: Date
    public var notice: Notice
}

public enum PauseReason: Sendable, Equatable {
    case user
    case stageManager
    /// Other tiling window managers are running.
    case conflict([String])
}

public enum EngineStatus: Sendable, Equatable {
    case starting
    case active
    case paused(PauseReason)
    case noPermission
    /// Crash loop detected: every window restored, nothing moves until "Retry".
    case safeMode

    public var isActive: Bool { self == .active }
}

/// What the menu bar shows. The UI builds its menu lazily from the latest state.
public struct UIState: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public var name: String
        public var windows: Int
        public var isActive: Bool
    }

    public var status: EngineStatus = .starting
    public var nativeWorkspaces = true
    /// 1-based, as Mission Control numbers them; nil on a full-screen Space.
    public var desktopNumber: Int?
    public var desktopCount = 0
    public var groups: [Group] = []
    public var layout: LayoutMode?
    public var zoomed = false
    public var canRevert = false
    public var keymap: [KeyBinding] = []
    public var activity: [ActivityEntry] = []
    public var screensBeyondPrimary = 0

    public init() {}
}

public enum UIAction: Sendable, Equatable {
    case command(Command)
    case jumpToDesktop(Int)
    case togglePause
    case gather
    case revertLayout
    case retry
    case reloadConfig
    case forgetSizes
    case quit
}

/// The engine's view of the user interface; AppKit in the app, a recorder in tests.
@MainActor
public protocol EngineUI: AnyObject {
    var onAction: (@MainActor (UIAction) -> Void)? { get set }
    func update(_ state: UIState)
    func notify(_ notice: Notice)
    /// Highlights the tile a dragged window would swap with; nil hides it (audit E8).
    func showDropTarget(_ frame: Rect?)
    /// The shortcut overlay shown while the base modifiers are held (audit E5).
    func showCheatsheet(_ visible: Bool)
}

/// Records everything; used by tests and by `--no-menu` runs.
@MainActor
public final class RecordingUI: EngineUI {
    public var onAction: (@MainActor (UIAction) -> Void)?
    public private(set) var states: [UIState] = []
    public private(set) var notices: [Notice] = []
    public private(set) var dropTargets: [Rect?] = []
    public private(set) var cheatsheetShown: [Bool] = []

    public init() {}

    public var state: UIState? { states.last }
    public func update(_ state: UIState) { states.append(state) }
    public func notify(_ notice: Notice) { notices.append(notice) }
    public func showDropTarget(_ frame: Rect?) { dropTargets.append(frame) }
    public func showCheatsheet(_ visible: Bool) { cheatsheetShown.append(visible) }
    public func noticeKeys() -> [String] { notices.map(\.key) }
}
