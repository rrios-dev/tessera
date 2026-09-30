public import Foundation
public import TesseraCore
public import TesseraPorts

/// A deterministic macOS for engine tests: apps, windows with minimums, maximums and size grids,
/// Spaces, screens, the Dock's 1-point clamp (ADR 0002), the display clamp, permissions,
/// Secure Input, symbolic hotkeys and synthesized keys. Everything the engine does is recorded.
@MainActor
public final class FakePlatform: SystemPort {
    public struct Window: Sendable, Equatable {
        public var id: WindowID
        public var pid: Int32
        public var frame: Rect
        public var subrole: String? = WindowSnapshot.standardSubrole
        public var minSize: Size?
        public var maxSize: Size?
        public var quantum: Size?
        public var spaces: [SpaceID]
        public var isMinimized = false
        public var isFullscreen = false
        public var canResize = true
        public var hasFullscreenButton = true
        /// Closed by ordering out without being destroyed: the window server still lists it.
        public var orderedOut = false
        /// A misbehaving window whose minimum height changes on every write, cycling through
        /// these values: whatever Tessera learns is wrong by the next write (audit C2).
        public var cyclingMinHeights: [Int] = []
        /// Snapping its size also moves its origin by this much (seen live on a grid window).
        public var snapNudge: Point?
        /// Writes answered "done" without changing anything, as by an app still launching.
        public var ignoredWrites = 0
        /// Applies each write but reports the frame it had before, like a busy browser answering
        /// late: every read-back looks like a refusal.
        public var answersLate = false
        var writeCount = 0

        public init(id: WindowID, pid: Int32, frame: Rect, spaces: [SpaceID], minSize: Size? = nil, maxSize: Size? = nil, quantum: Size? = nil) {
            self.id = id
            self.pid = pid
            self.frame = frame
            self.spaces = spaces
            self.minSize = minSize
            self.maxSize = maxSize
            self.quantum = quantum
        }
    }

    public struct App: Sendable {
        public var info: RunningApp
        /// Answers nothing: window queries return nil, writes time out.
        public var unresponsive = false
        /// Every write fails with this outcome and changes nothing.
        public var writeFailure: AXOutcome?
        public var focused: WindowID?
        public var enhancedUserInterface = false
    }

    public var onEvent: (@MainActor (SystemEvent) -> Void)?

    public var apps: [Int32: App] = [:]
    public var windows: [WindowID: Window] = [:]
    public var screenList: [ScreenInfo]
    public var spaceList: [SpaceDescriptor]
    public var active: SpaceID
    public var trusted = true
    public var secureInput = false
    public var symbolic: [Int: SymbolicHotkey] = FakePlatform.defaultSymbolicHotkeys()
    public var tilers: [String] = []
    public var stageManager = false
    public var edgeTiling = false
    public var voiceOver = false
    public var frontmost: Int32?
    public var dockClamp = 1
    public var bootSession = "boot-1"
    public var clockOffset: TimeInterval = 0
    public var mouse = Point(x: 0, y: 0)
    public var refusedChords: Set<KeyChord> = []

    // Recorded effects.
    public private(set) var postedKeys: [(keyCode: Int, flags: KeyFlags)] = []
    public private(set) var registeredChords: [KeyChord] = []
    public private(set) var writes: [(window: WindowID, target: Rect)] = []
    public private(set) var raised: [WindowID] = []
    public private(set) var focusRequests: [WindowID] = []
    public private(set) var trustPrompts = 0
    public private(set) var monitoring = false
    public private(set) var observed: Set<Int32> = []
    private var subscribed: Set<WindowID> = []
    private var nextID: WindowID = 1000

    public init(
        screen: ScreenInfo = ScreenInfo(frame: Rect(x: 0, y: 0, width: 1080, height: 2560), usableArea: Rect(x: 0, y: 30, width: 1080, height: 2448)),
        spaces: [SpaceDescriptor] = [SpaceDescriptor(id: 3, kind: .desktop), SpaceDescriptor(id: 7, kind: .desktop)]
    ) {
        screenList = [screen]
        spaceList = spaces
        active = spaces[0].id
    }

    /// macOS's defaults with "Switch to Desktop 1…9" on as Control-1…9 (what the owner uses).
    public static func defaultSymbolicHotkeys(directJumps: Bool = true) -> [Int: SymbolicHotkey] {
        var result: [Int: SymbolicHotkey] = [
            79: SymbolicHotkey(enabled: true, keyCode: KeyCode.leftArrow, modifiers: 0x840000),
            81: SymbolicHotkey(enabled: true, keyCode: KeyCode.rightArrow, modifiers: 0x840000),
            60: SymbolicHotkey(enabled: true, keyCode: KeyCode.space, modifiers: 0x40000),
            61: SymbolicHotkey(enabled: true, keyCode: KeyCode.space, modifiers: 0xC0000),
        ]
        for (index, code) in KeyCode.digits.enumerated() {
            result[118 + index] = SymbolicHotkey(enabled: directJumps, keyCode: code, modifiers: 0x40000)
        }
        return result
    }

    // MARK: - Scripting the simulated system

    public func emit(_ event: SystemEvent) { onEvent?(event) }

    @discardableResult
    public func launch(pid: Int32, bundleID: String, executable: String? = nil, version: String? = "1.0") -> RunningApp {
        let info = RunningApp(pid: pid, bundleID: bundleID, executableName: executable ?? bundleID, version: version)
        apps[pid] = App(info: info)
        emit(.appLaunched(info))
        return info
    }

    public func quit(pid: Int32) {
        apps[pid] = nil
        windows = windows.filter { $0.value.pid != pid }
        emit(.appTerminated(pid: pid))
    }

    /// Opens a window on the active Space (or `space`) and tells the engine.
    @discardableResult
    public func open(
        pid: Int32, frame: Rect = Rect(x: 100, y: 100, width: 600, height: 400), space: SpaceID? = nil,
        minSize: Size? = nil, maxSize: Size? = nil, quantum: Size? = nil, subrole: String? = WindowSnapshot.standardSubrole,
        allSpaces: Bool = false, notify: Bool = true
    ) -> WindowID {
        nextID += 1
        var window = Window(id: nextID, pid: pid, frame: frame, spaces: allSpaces ? spaceList.map(\.id) : [space ?? active],
                            minSize: minSize, maxSize: maxSize, quantum: quantum)
        window.subrole = subrole
        window.frame = accepted(window, frame)
        windows[nextID] = window
        apps[pid]?.focused = nextID
        if notify { emit(.window(.windowCreated(pid: pid))) }
        return nextID
    }

    public func close(_ id: WindowID, destroy: Bool = true) {
        guard let window = windows[id] else { return }
        if destroy {
            windows[id] = nil
            emit(.window(.windowDestroyed(pid: window.pid, window: subscribed.contains(id) ? id : nil)))
        } else {
            windows[id]?.orderedOut = true
            emit(.window(.focusChanged(pid: window.pid)))
        }
    }

    public func switchSpace(to space: SpaceID) {
        active = space
        emit(.activeSpaceChanged)
    }

    /// The user drags or resizes a window by hand (anywhere: macOS does not clamp a drag).
    public func userMoves(_ id: WindowID, to frame: Rect) {
        guard let window = windows[id] else { return }
        windows[id]?.frame = frame
        emit(.window(.windowMoved(pid: window.pid, window: subscribed.contains(id) ? id : nil)))
    }

    public func advanceClock(by seconds: TimeInterval) { clockOffset += seconds }

    /// Changes a window without telling anyone, as when a notification is lost.
    public func silentlyMove(_ id: WindowID, to frame: Rect) {
        guard let window = windows[id] else { return }
        windows[id]?.frame = accepted(window, frame)
    }

    public func setMinimized(_ id: WindowID, _ minimized: Bool) {
        guard let window = windows[id] else { return }
        windows[id]?.isMinimized = minimized
        emit(.window(.windowChanged(pid: window.pid)))
    }

    /// Writes made to one window so far.
    public func writeCount(_ id: WindowID) -> Int { writes.filter { $0.window == id }.count }

    /// Windows the user can see on the active Space.
    public func visible(_ id: WindowID) -> Bool {
        guard let window = windows[id], let app = apps[window.pid] else { return false }
        return window.spaces.contains(active) && !window.isMinimized && !app.info.isHidden && !window.orderedOut
    }

    /// What macOS does with a requested frame: minimum, maximum and grid; never above the menu
    /// bar; the Dock keeps windows `dockClamp` points above it; never taller than the display.
    func accepted(_ window: Window, _ rect: Rect) -> Rect {
        var frame = rect
        func clamp(_ value: Int, min lower: Int?, max upper: Int?, step: Int?, base: Int?) -> Int {
            var result = value
            if let upper { result = Swift.min(result, upper) }
            if let step, step > 1 { let origin = base ?? 0; result = origin + Swift.max(0, (result - origin) / step) * step }
            if let lower { result = Swift.max(result, lower) }
            return Swift.max(1, result)
        }
        frame.width = clamp(frame.width, min: window.minSize?.width, max: window.maxSize?.width, step: window.quantum?.width, base: window.minSize?.width)
        frame.height = clamp(frame.height, min: window.minSize?.height, max: window.maxSize?.height, step: window.quantum?.height, base: window.minSize?.height)
        let primary = screenList[0]
        // Hidden windows parked past the far corner are left where they are asked to be.
        let parked = frame.minX >= primary.frame.maxX - 8 || frame.minY >= primary.frame.maxY - 8 || frame.maxX <= primary.frame.minX + 8
        if !parked {
            frame.y = Swift.max(frame.y, primary.usableArea.minY)
            let floor = primary.usableArea.maxY - dockClamp
            if frame.maxY > floor, frame.minY < floor {
                frame.height = Swift.max(window.minSize?.height ?? 1, floor - frame.y)
            }
            // A window is never taller than the display below the menu bar (ADR 0002's 2000 → 540
            // is this limit); it may extend past the bottom edge, as when dragged there.
            frame.height = Swift.min(frame.height, primary.frame.height - primary.usableArea.minY)
        }
        return frame
    }

    func snapshot(_ window: Window) -> WindowSnapshot {
        WindowSnapshot(
            id: window.id, subrole: window.subrole, isFullscreen: window.isFullscreen, isMinimized: window.isMinimized,
            frame: window.frame, canResize: window.canResize, hasFullscreenButton: window.hasFullscreenButton
        )
    }

    // MARK: - Driver back-end (runs on the main actor, like the real apps' queues hop to main)

    func listWindows(_ pid: Int32) -> [WindowSnapshot]? {
        guard let app = apps[pid], !app.unresponsive else { return nil }
        // Accessibility lists the windows of the active Space only (minimised ones included).
        let listed = windows.values.filter { $0.pid == pid && $0.spaces.contains(active) && !$0.orderedOut }.sorted { $0.id < $1.id }
        if observed.contains(pid) { listed.forEach { subscribed.insert($0.id) } }
        return listed.map(snapshot)
    }

    func write(_ id: WindowID, pid: Int32, target: Rect, positionOnly: Bool) -> WriteResult {
        guard trusted else { return WriteResult(frame: nil, failures: [.apiDisabled]) }
        guard let app = apps[pid] else { return WriteResult(frame: nil, failures: [.invalidElement]) }
        if app.unresponsive { return WriteResult(frame: nil, failures: [.cannotComplete]) }
        guard let window = windows[id], window.pid == pid, window.spaces.contains(active) else {
            return WriteResult(frame: nil, failures: [.invalidElement])
        }
        if let failure = app.writeFailure { return WriteResult(frame: window.frame, failures: [failure]) }
        writes.append((id, target))
        var current = window
        if current.ignoredWrites > 0 {
            windows[id]?.ignoredWrites -= 1
            return WriteResult(frame: current.frame)
        }
        if !current.cyclingMinHeights.isEmpty {
            current.minSize = Size(width: current.minSize?.width ?? 1, height: current.cyclingMinHeights[current.writeCount % current.cyclingMinHeights.count])
            current.writeCount += 1
            windows[id] = current
        }
        let requested = positionOnly ? Rect(origin: target.origin, size: current.frame.size) : target
        var result = accepted(current, requested)
        if !positionOnly, let nudge = current.snapNudge, result.size != requested.size {
            result.x += nudge.x
            result.y += nudge.y
        }
        let before = current.frame
        windows[id]?.frame = result
        return WriteResult(frame: current.answersLate ? before : windows[id]!.frame)
    }

    func readFrame(_ id: WindowID, pid: Int32) -> Rect? {
        guard let app = apps[pid], !app.unresponsive, let window = windows[id], window.spaces.contains(active) else { return nil }
        return window.frame
    }

    func focusWindow(_ id: WindowID, pid: Int32) {
        guard windows[id] != nil else { return }
        focusRequests.append(id)
        apps[pid]?.focused = id
        let changed = frontmost != pid
        frontmost = pid
        emit(.window(.focusChanged(pid: pid)))
        if changed { emit(.appActivated(pid: pid)) }
    }

    func raiseWindow(_ id: WindowID) { raised.append(id) }

    // MARK: - SystemPort

    public func isTrusted(prompt: Bool) -> Bool {
        if prompt && !trusted { trustPrompts += 1 }
        return trusted
    }

    public func runningApps() -> [RunningApp] { apps.values.map(\.info).sorted { $0.pid < $1.pid } }
    public func frontmostPID() -> Int32? { frontmost }
    public func frontmostBundleID() -> String? { frontmost.flatMap { apps[$0]?.info.bundleID } }
    public func makeDriver(pid: Int32) -> any AppDriver { FakeDriver(pid: pid, platform: self) }

    public func presence(of ids: [WindowID]) -> (existing: Set<WindowID>, onScreen: Set<WindowID>) {
        let existing = Set(ids.filter { windows[$0] != nil })
        return (existing, Set(existing.filter(visible)))
    }

    public func bounds(of ids: [WindowID]) -> [WindowID: Rect] {
        var result: [WindowID: Rect] = [:]
        for id in ids where visible(id) { result[id] = windows[id]!.frame }
        return result
    }

    public func onScreenOwners() -> [WindowID: Int32] {
        var result: [WindowID: Int32] = [:]
        for window in windows.values where visible(window.id) { result[window.id] = window.pid }
        return result
    }

    public var spacesAvailable = true
    public func activeSpace() -> SpaceID? { spacesAvailable ? active : nil }
    public func spaces() -> [SpaceDescriptor] { spacesAvailable ? spaceList : [] }
    public func spaces(of window: WindowID) -> [SpaceID] { windows[window]?.spaces ?? [] }
    public func spaceOrder() -> [SpaceID] { spaceList.map(\.id) }
    public func screens() -> [ScreenInfo] { screenList }
    public func secureInputActive() -> Bool { secureInput }
    public func symbolicHotkeys() -> [Int: SymbolicHotkey] { symbolic }
    public func otherTilersRunning() -> [String] { tilers }
    public func stageManagerEnabled() -> Bool { stageManager }
    public func edgeTilingEnabled() -> Bool { edgeTiling }
    public func voiceOverEnabled() -> Bool { voiceOver }
    public func postKey(_ keyCode: Int, flags: KeyFlags) { postedKeys.append((keyCode, flags)) }
    public func mouseLocation() -> Point { mouse }
    public func bootSessionID() -> String { bootSession }
    public func now() -> Date { Date().addingTimeInterval(clockOffset) }
    /// Whether IPC clients count as signed by Tessera's team.
    public var peersTrusted = true
    public func peerSharesTeam(auditToken: Data) -> Bool { peersTrusted }
    public var enhancedUIJournal: URL?
    public func armEnhancedUIJournal(at url: URL) -> [Int32] {
        enhancedUIJournal = url
        return []
    }

    public func registerHotkeys(_ chords: [KeyChord]) -> [Bool] {
        registeredChords = chords
        return chords.map { !refusedChords.contains($0) }
    }

    public func unregisterHotkeys() { registeredChords = [] }

    /// Presses a registered chord.
    public func press(_ chord: KeyChord) {
        guard let index = registeredChords.firstIndex(of: chord) else { return }
        emit(.hotkeyPressed(index))
    }

    public func startMonitoring() { monitoring = true }
    public func stopMonitoring() { monitoring = false }
    public func observe(pid: Int32) { observed.insert(pid) }
    public func observeWindows(pid: Int32) {
        for window in windows.values where window.pid == pid && window.spaces.contains(active) { subscribed.insert(window.id) }
    }
    public func stopObserving(pid: Int32) { observed.remove(pid) }
}

/// One simulated app's Accessibility connection. Completions arrive asynchronously on the main
/// queue, as the real ones arrive on each app's queue.
final class FakeDriver: AppDriver, @unchecked Sendable {
    let pid: Int32
    private weak var platform: FakePlatform?

    init(pid: Int32, platform: FakePlatform) {
        self.pid = pid
        self.platform = platform
    }

    var isUnresponsive: Bool {
        MainActor.assumeIsolated { platform?.apps[pid]?.unresponsive ?? false }
    }

    private func onMain(_ body: @escaping @MainActor (FakePlatform) -> Void) {
        DispatchQueue.main.async { [weak platform] in
            MainActor.assumeIsolated {
                guard let platform else { return }
                body(platform)
            }
        }
    }

    func windows(completion: @escaping @Sendable ([WindowSnapshot]?) -> Void) {
        let pid = pid
        onMain { completion($0.listWindows(pid)) }
    }

    func frame(of id: WindowID, completion: @escaping @Sendable (Rect?) -> Void) {
        let pid = pid
        onMain { completion($0.readFrame(id, pid: pid)) }
    }

    func setFrame(_ id: WindowID, to rect: Rect, from current: Rect?, completion: @escaping @Sendable (WriteResult) -> Void) {
        let pid = pid
        onMain { completion($0.write(id, pid: pid, target: rect, positionOnly: false)) }
    }

    func setPosition(_ id: WindowID, to point: Point, completion: @escaping @Sendable (WriteResult) -> Void) {
        let pid = pid
        onMain { completion($0.write(id, pid: pid, target: Rect(origin: point, size: Size(width: 1, height: 1)), positionOnly: true)) }
    }

    func raise(_ id: WindowID) { onMain { $0.raiseWindow(id) } }

    func focus(_ id: WindowID) {
        let pid = pid
        onMain { $0.focusWindow(id, pid: pid) }
    }

    func focusedWindow(completion: @escaping @Sendable (WindowID?) -> Void) {
        let pid = pid
        onMain { completion($0.apps[pid]?.focused) }
    }

    func setEnhancedUserInterface(_ on: Bool) {
        let pid = pid
        onMain { $0.apps[pid]?.enhancedUserInterface = on }
    }
}
