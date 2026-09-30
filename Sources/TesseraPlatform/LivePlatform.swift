public import TesseraCore
public import TesseraPorts
import AppKit
import ApplicationServices
import Carbon
public import Foundation

/// The real macOS behind `SystemPort`: Accessibility, CGWindowList, read-only SkyLight,
/// NSWorkspace, Carbon hotkeys and global mouse monitors.
@MainActor
public final class LivePlatform: SystemPort {
    public var onEvent: (@MainActor (SystemEvent) -> Void)?

    private let spaceService = SpaceService()
    private lazy var spacesTrusted = spaceService.selfTest()
    private var hub: AXObserverHub?
    private var drivers: [Int32: AXApplication] = [:]
    private var hotkeys: HotkeyCenter?
    private var tokens: [any NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var voiceOverObservation: NSKeyValueObservation?
    private var versions: [Int32: String?] = [:]
    private var lastDrag = Date.distantPast

    public init() {
        AXApplication.configureGlobalTimeout()
    }

    // MARK: Permission

    public func isTrusted(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt's value, spelled out: the global is not concurrency-safe.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    // MARK: Apps

    public func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map(runningApp)
    }

    func runningApp(_ app: NSRunningApplication) -> RunningApp {
        let pid = app.processIdentifier
        if versions[pid] == nil {
            versions[pid] = .some(app.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        }
        return RunningApp(
            pid: pid, bundleID: app.bundleIdentifier, executableName: app.executableURL?.lastPathComponent,
            version: versions[pid] ?? nil, isRegular: app.activationPolicy == .regular, isHidden: app.isHidden
        )
    }

    public func frontmostPID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    public func frontmostBundleID() -> String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    public func makeDriver(pid: Int32) -> any AppDriver {
        if let existing = drivers[pid] { return existing }
        let driver = AXApplication(pid: pid, hub: hub)
        drivers[pid] = driver
        return driver
    }

    // MARK: Window server

    public func presence(of ids: [WindowID]) -> (existing: Set<WindowID>, onScreen: Set<WindowID>) { WindowServer.presence(of: ids) }
    public func bounds(of ids: [WindowID]) -> [WindowID: Rect] { WindowServer.bounds(of: ids) }
    public func onScreenOwners() -> [WindowID: Int32] { WindowServer.onScreenOwners() }

    // MARK: Spaces

    public var spacesAvailable: Bool { spacesTrusted }
    public func activeSpace() -> SpaceID? { spacesTrusted ? spaceService.activeSpace() : nil }
    public func spaces() -> [SpaceDescriptor] { spacesTrusted ? spaceService.spaces() : [] }
    public func spaces(of window: WindowID) -> [SpaceID] { spacesTrusted ? spaceService.spaces(of: window) : [] }
    public func spaceOrder() -> [SpaceID] { spacesTrusted ? spaceService.spaceOrder() : [] }

    // MARK: Screens

    public func screens() -> [ScreenInfo] {
        Metrics.count(.screenReads)
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else { return [] }
        return screens.map { screen in
            ScreenInfo(
                frame: EnvironmentProbe.topLeftRect(appKit: screen.frame, primaryHeight: primaryHeight),
                usableArea: EnvironmentProbe.topLeftRect(appKit: screen.visibleFrame, primaryHeight: primaryHeight),
                scale: Int(screen.backingScaleFactor.rounded())
            )
        }
    }

    // MARK: Settings and input

    public func secureInputActive() -> Bool { IsSecureEventInputEnabled() }

    public func symbolicHotkeys() -> [Int: SymbolicHotkey] {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return [:] }
        var result: [Int: SymbolicHotkey] = [:]
        for (key, value) in all {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int] ?? []
            result[id] = SymbolicHotkey(
                enabled: (entry["enabled"] as? Bool) ?? false,
                keyCode: parameters.count == 3 ? parameters[1] : -1,
                modifiers: parameters.count == 3 ? parameters[2] : 0
            )
        }
        return result
    }

    public func otherTilersRunning() -> [String] {
        EnvironmentProbe.otherWindowManagers()
            .filter { $0.running && ["AeroSpace", "yabai", "Amethyst"].contains($0.name) }
            .map(\.name)
    }

    public func stageManagerEnabled() -> Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    public func edgeTilingEnabled() -> Bool {
        // Absent means the macOS default, which is on.
        (UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool) ?? true
    }

    public func voiceOverEnabled() -> Bool { NSWorkspace.shared.isVoiceOverEnabled }

    public func postKey(_ keyCode: Int, flags: KeyFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        var cgFlags: CGEventFlags = []
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.function) { cgFlags.insert(.maskSecondaryFn) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
            event.flags = cgFlags
            event.post(tap: .cghidEventTap)
        }
    }

    public func mouseLocation() -> Point {
        let location = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return Point(x: Int(location.x.rounded()), y: Int((height - location.y).rounded()))
    }

    public func bootSessionID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func now() -> Date { Date() }

    public func peerSharesTeam(auditToken: Data) -> Bool {
        guard let team = CodeSignature.ownTeam else { return true }
        return CodeSignature.process(auditToken: auditToken, isSignedBy: team)
    }

    public func armEnhancedUIJournal(at url: URL) -> [Int32] {
        let journal = EnhancedUIJournal(url: url)
        let pending = journal.takePending()
        AXApplication.enhancedUIToggled = { pid, on in journal.mark(pid, off: !on) }
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let restored = pending.filter(running.contains)
        for pid in restored { AXApplication(pid: pid).setEnhancedUserInterface(true) }
        return restored
    }

    // MARK: Hotkeys

    public func registerHotkeys(_ chords: [KeyChord]) -> [Bool] {
        unregisterHotkeys()
        let center = HotkeyCenter { [weak self] index in self?.onEvent?(.hotkeyPressed(index)) }
        hotkeys = center
        return center.register(chords)
    }

    public func unregisterHotkeys() {
        hotkeys?.unregisterAll()
        hotkeys = nil
    }

    // MARK: Observation

    public func startMonitoring() {
        guard hub == nil else { return }
        hub = AXObserverHub { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEvent?(.window(event)) } }
        }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = LivePlatform.app(note) else { return }
            MainActor.assumeIsolated { guard let self else { return }; self.onEvent?(.appLaunched(self.runningApp(running))) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = LivePlatform.app(note)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.versions[pid] = nil
                self?.onEvent?(.appTerminated(pid: pid))
            }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.activeSpaceChanged) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = LivePlatform.app(note)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.onEvent?(.appActivated(pid: pid)) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.didWake) }
        })
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let pid = LivePlatform.app(note)?.processIdentifier else { return }
                MainActor.assumeIsolated { self?.onEvent?(.appVisibilityChanged(pid: pid)) }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.screensChanged) }
        })
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] workspace, _ in
            let enabled = workspace.isVoiceOverEnabled
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEvent?(.voiceOverChanged(enabled)) } }
        }
        // Global monitors see events of other apps only and never consume them.
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.mouseDown) }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.onEvent?(.mouseUp(self.mouseLocation())) }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated {
                // 30 Hz is plenty for a highlight and costs nothing while idle.
                guard let self, Date().timeIntervalSince(self.lastDrag) > 1.0 / 30 else { return }
                self.lastDrag = Date()
                self.onEvent?(.mouseDragged(self.mouseLocation()))
            }
        }
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            var keys: KeyFlags = []
            if event.modifierFlags.contains(.control) { keys.insert(.control) }
            if event.modifierFlags.contains(.option) { keys.insert(.option) }
            if event.modifierFlags.contains(.shift) { keys.insert(.shift) }
            if event.modifierFlags.contains(.command) { keys.insert(.command) }
            MainActor.assumeIsolated { self?.onEvent?(.modifiersChanged(keys)) }
        }
        monitors = [down, up, dragged, flags].compactMap { $0 }
    }

    nonisolated static func app(_ note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    public func stopMonitoring() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        voiceOverObservation = nil
        unregisterHotkeys()
    }

    public func observe(pid: Int32) {
        (makeDriver(pid: pid) as? AXApplication)?.startObserving()
    }

    public func observeWindows(pid: Int32) {
        drivers[pid]?.observeWindows()
    }

    public func stopObserving(pid: Int32) {
        hub?.forget(pid: pid)
        drivers[pid] = nil
    }
}
