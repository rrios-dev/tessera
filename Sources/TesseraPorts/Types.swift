public import Foundation
public import TesseraCore

/// A window as the Accessibility API describes it.
public struct WindowSnapshot: Sendable, Equatable {
    public var id: WindowID
    public var subrole: String?
    public var isFullscreen: Bool
    public var isMinimized: Bool
    public var frame: Rect?
    public var canResize: Bool
    public var hasFullscreenButton: Bool

    public init(
        id: WindowID, subrole: String?, isFullscreen: Bool = false, isMinimized: Bool = false,
        frame: Rect?, canResize: Bool = true, hasFullscreenButton: Bool = true
    ) {
        self.id = id
        self.subrole = subrole
        self.isFullscreen = isFullscreen
        self.isMinimized = isMinimized
        self.frame = frame
        self.canResize = canResize
        self.hasFullscreenButton = hasFullscreenButton
    }

    public static let standardSubrole = "AXStandardWindow"

    /// Standard windows tile; dialogs, panels and fixed-size windows float.
    public var prefersFloating: Bool {
        subrole != Self.standardSubrole || !canResize || !hasFullscreenButton
    }

    public var isManageable: Bool {
        subrole == Self.standardSubrole || subrole == "AXDialog" || subrole == "AXFloatingWindow"
    }
}

/// The outcome of one Accessibility call, reduced to what the engine acts on.
public enum AXOutcome: Sendable, Equatable {
    case success
    /// The Accessibility permission was revoked.
    case apiDisabled
    /// Timeout, app busy or not ready.
    case cannotComplete
    /// The window no longer exists or is unknown to the app.
    case invalidElement
    case failure(Int32)
}

/// A frame write and the frame read back afterwards.
public struct WriteResult: Sendable, Equatable {
    /// The frame read back after the writes; nil when the read failed.
    public var frame: Rect?
    /// Outcomes of the calls that did not succeed.
    public var failures: [AXOutcome]

    public init(frame: Rect?, failures: [AXOutcome] = []) {
        self.frame = frame
        self.failures = failures
    }

    /// Every write and the read-back succeeded: the frame is a trustworthy observation.
    public var isClean: Bool { failures.isEmpty && frame != nil }
    public var permissionLost: Bool { failures.contains(.apiDisabled) }
}

public struct RunningApp: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var executableName: String?
    public var version: String?
    public var isRegular: Bool
    public var isHidden: Bool

    public init(pid: Int32, bundleID: String?, executableName: String?, version: String? = nil, isRegular: Bool = true, isHidden: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.executableName = executableName
        self.version = version
        self.isRegular = isRegular
        self.isHidden = isHidden
    }
}

public struct ScreenInfo: Sendable, Equatable {
    /// Global points, top-left origin.
    public var frame: Rect
    /// Excludes the menu bar and the Dock.
    public var usableArea: Rect
    /// Backing scale factor (2 on Retina); part of the key under which window facts persist.
    public var scale: Int

    public init(frame: Rect, usableArea: Rect, scale: Int = 2) {
        self.frame = frame
        self.usableArea = usableArea
        self.scale = scale
    }
}

/// What the Accessibility observers report, already mapped to window ids where possible.
public enum WindowEvent: Sendable, Equatable {
    case windowCreated(pid: Int32)
    /// Minimised, restored, app hidden or shown.
    case windowChanged(pid: Int32)
    /// Moved or resized: only that window needs reading.
    case windowMoved(pid: Int32, window: WindowID?)
    case focusChanged(pid: Int32)
    /// `window` is known when the destroyed element was subscribed.
    case windowDestroyed(pid: Int32, window: WindowID?)
}

/// A macOS keyboard shortcut from `com.apple.symbolichotkeys`.
public struct SymbolicHotkey: Sendable, Equatable {
    public var enabled: Bool
    public var keyCode: Int
    /// Carbon-style modifier mask as stored by macOS (Control = 0x40000).
    public var modifiers: Int

    public init(enabled: Bool, keyCode: Int, modifiers: Int) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct KeyFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyFlags(rawValue: 1)
    public static let option = KeyFlags(rawValue: 2)
    public static let shift = KeyFlags(rawValue: 4)
    public static let command = KeyFlags(rawValue: 8)
    public static let function = KeyFlags(rawValue: 16)
}

/// Everything the operating system tells the engine, delivered on the main actor.
public enum SystemEvent: Sendable, Equatable {
    case window(WindowEvent)
    case appLaunched(RunningApp)
    case appTerminated(pid: Int32)
    /// The user hid or showed an app (Cmd-H).
    case appVisibilityChanged(pid: Int32)
    case appActivated(pid: Int32)
    case activeSpaceChanged
    case screensChanged
    case mouseDown
    case mouseDragged(Point)
    case mouseUp(Point)
    case modifiersChanged(KeyFlags)
    case voiceOverChanged(Bool)
    /// A registered hotkey, by its index in the last `registerHotkeys` call.
    case hotkeyPressed(Int)
    case didWake
}
