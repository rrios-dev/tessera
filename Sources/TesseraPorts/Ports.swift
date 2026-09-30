public import Foundation
public import TesseraCore

/// Everything Tessera does to one app's windows. Implementations serialise calls per app so a
/// slow or hung app never blocks the engine; completions may run on any thread.
public protocol AppDriver: AnyObject, Sendable {
    var pid: Int32 { get }
    /// True after repeated timeouts; cleared by the next answer.
    var isUnresponsive: Bool { get }
    /// Current windows, or nil when the app did not answer (never read that as "no windows").
    func windows(completion: @escaping @Sendable ([WindowSnapshot]?) -> Void)
    func frame(of id: WindowID, completion: @escaping @Sendable (Rect?) -> Void)
    /// Writes only what changed relative to `current` and reads the frame back.
    func setFrame(_ id: WindowID, to rect: Rect, from current: Rect?, completion: @escaping @Sendable (WriteResult) -> Void)
    func setPosition(_ id: WindowID, to point: Point, completion: @escaping @Sendable (WriteResult) -> Void)
    func raise(_ id: WindowID)
    func focus(_ id: WindowID)
    func focusedWindow(completion: @escaping @Sendable (WindowID?) -> Void)
    /// Restores `AXEnhancedUserInterface` on an app a previous run may have left off.
    func setEnhancedUserInterface(_ on: Bool)
}

/// The operating system as the engine sees it. The live implementation talks to macOS; the fake
/// one simulates windows, Spaces, screens and settings deterministically for tests.
@MainActor
public protocol SystemPort: AnyObject {
    // Permission
    func isTrusted(prompt: Bool) -> Bool

    // Apps
    func runningApps() -> [RunningApp]
    func frontmostPID() -> Int32?
    func frontmostBundleID() -> String?
    func makeDriver(pid: Int32) -> any AppDriver

    // Window server (no permission needed)
    func presence(of ids: [WindowID]) -> (existing: Set<WindowID>, onScreen: Set<WindowID>)
    func bounds(of ids: [WindowID]) -> [WindowID: Rect]
    func onScreenOwners() -> [WindowID: Int32]

    // Spaces (read-only SkyLight; ADR 0001)
    var spacesAvailable: Bool { get }
    func activeSpace() -> SpaceID?
    /// Every Space of every display, in Mission Control order.
    func spaces() -> [SpaceDescriptor]
    /// All Spaces a window is on; more than one for "assign to all desktops".
    func spaces(of window: WindowID) -> [SpaceID]

    // Screens: the primary (menu bar) screen first.
    func screens() -> [ScreenInfo]

    /// Every Space of the primary display in Mission Control order, desktops and full-screen
    /// Spaces alike: Control-Arrow steps over both.
    func spaceOrder() -> [SpaceID]

    // Settings and input environment
    func secureInputActive() -> Bool
    /// macOS's keyboard shortcuts (`com.apple.symbolichotkeys`), by id.
    func symbolicHotkeys() -> [Int: SymbolicHotkey]
    /// Names of other tiling window managers that are running (they would fight Tessera).
    func otherTilersRunning() -> [String]
    func stageManagerEnabled() -> Bool
    func edgeTilingEnabled() -> Bool
    func voiceOverEnabled() -> Bool
    /// Synthesizes one key press (down and up).
    func postKey(_ keyCode: Int, flags: KeyFlags)
    func mouseLocation() -> Point
    /// Changes on every boot: window ids and pids from another boot mean nothing.
    func bootSessionID() -> String
    func now() -> Date

    /// Whether the process with this audit token is signed by the same team as Tessera. True
    /// when Tessera itself has no team (an ad hoc development build): there is nothing to match.
    func peerSharesTeam(auditToken: Data) -> Bool

    /// Starts journaling the apps whose `AXEnhancedUserInterface` Tessera turns off around a
    /// write, in `url`, and turns it back on for any app a previous run left off (audit F11).
    /// - Returns: the pids restored.
    func armEnhancedUIJournal(at url: URL) -> [Int32]

    // Hotkeys: returns, per chord, whether macOS accepted it. Presses arrive as `.hotkeyPressed`.
    func registerHotkeys(_ chords: [KeyChord]) -> [Bool]
    func unregisterHotkeys()

    // Observation: events arrive through `onEvent`.
    var onEvent: (@MainActor (SystemEvent) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
    func observe(pid: Int32)
    func observeWindows(pid: Int32)
    func stopObserving(pid: Int32)
}
