public import TesseraCore
import TesseraPorts
import AppKit
import Carbon
import CoreGraphics
import Darwin
import Foundation
import TesseraConfig

/// Captures an `EnvironmentFixture` from the running machine.
///
/// Needs no privacy permission: display geometry, preferences, and window counts from
/// `CGWindowListCopyWindowInfo` are readable without Accessibility or Screen Recording.
/// Window titles are deliberately never read.
@MainActor
public enum EnvironmentProbe {
    public static func capture() -> EnvironmentFixture {
        // `NSScreen.screensHaveSeparateSpaces` reports `false` until NSApplication exists.
        _ = NSApplication.shared

        let formatter = ISO8601DateFormatter()
        return EnvironmentFixture(
            capturedAt: formatter.string(from: Date()),
            system: systemInfo(),
            displays: displays(),
            dock: dock(),
            spaces: spaces(),
            windowManagement: windowManagement(),
            accessibility: accessibility(),
            input: input(),
            windows: windowCensus(),
            otherWindowManagers: otherWindowManagers()
        )
    }

    // MARK: - System

    static func systemInfo() -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return SystemInfo(
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osBuild: sysctlString("kern.osversion") ?? "unknown",
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            architecture: architecture
        )
    }

    static func string(fromNulTerminated buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return string(fromNulTerminated: buffer)
    }

    // MARK: - Displays

    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let screensByID: [CGDirectDisplayID: NSScreen] = Dictionary(
            NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                    .map { (CGDirectDisplayID($0.uint32Value), screen) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        return ids.prefix(Int(count)).map { id in
            let screen = screensByID[id]
            let bounds = CGDisplayBounds(id)
            let frame = Rect(cg: bounds)
            let visible = screen.map { topLeftRect(appKit: $0.visibleFrame, primaryHeight: primaryHeight) } ?? frame
            let mode = CGDisplayCopyDisplayMode(id)
            let mirror = CGDisplayMirrorsDisplay(id)
            let insets = screen?.safeAreaInsets ?? NSEdgeInsetsZero

            return DisplayInfo(
                displayID: id,
                uuid: displayUUID(id),
                name: screen?.localizedName ?? "Display \(id)",
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                unitNumber: CGDisplayUnitNumber(id),
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                mirrorsDisplayID: mirror == kCGNullDirectDisplay ? nil : mirror,
                rotationDegrees: Int(CGDisplayRotation(id).rounded()),
                frame: frame,
                visibleFrame: visible,
                pixelWidth: mode?.pixelWidth ?? Int(bounds.width),
                pixelHeight: mode?.pixelHeight ?? Int(bounds.height),
                backingScale: Double(screen?.backingScaleFactor ?? 1),
                refreshHz: mode?.refreshRate ?? 0,
                safeAreaInsets: Insets(
                    top: Int(insets.top), left: Int(insets.left),
                    bottom: Int(insets.bottom), right: Int(insets.right)
                ),
                menuBarHeight: max(0, visible.minY - frame.minY)
            )
        }
    }

    static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Converts an AppKit rect (bottom-left origin, relative to the primary screen) to top-left points.
    static func topLeftRect(appKit rect: NSRect, primaryHeight: CGFloat) -> Rect {
        Rect(
            x: Int(rect.minX.rounded()),
            y: Int((primaryHeight - rect.maxY).rounded()),
            width: Int(rect.width.rounded()),
            height: Int(rect.height.rounded())
        )
    }

    // MARK: - Preferences

    static func preferences(_ domain: String) -> UserDefaults? { UserDefaults(suiteName: domain) }

    static func optionalBool(_ domain: String, _ key: String) -> Bool? {
        preferences(domain)?.object(forKey: key).flatMap { ($0 as? NSNumber)?.boolValue }
    }

    static func dock() -> DockInfo {
        let dock = preferences("com.apple.dock")
        return DockInfo(
            orientation: dock?.string(forKey: "orientation") ?? "bottom",
            autohide: dock?.bool(forKey: "autohide") ?? false,
            tileSize: (dock?.object(forKey: "tilesize") as? NSNumber)?.intValue
        )
    }

    static func spaces() -> SpacesInfo {
        var perDisplay: [DisplaySpaces] = []
        let configuration = preferences("com.apple.spaces")?.dictionary(forKey: "SpacesDisplayConfiguration")
        let management = configuration?["Management Data"] as? [String: Any]
        var seen: Set<String> = []
        for monitor in (management?["Monitors"] as? [[String: Any]]) ?? [] {
            // The list also keeps collapsed entries for displays seen before; only entries
            // that carry a Spaces array describe a live display.
            guard let identifier = monitor["Display Identifier"] as? String,
                  let spaceList = monitor["Spaces"] as? [[String: Any]],
                  seen.insert(identifier).inserted
            else { continue }
            let types = spaceList.compactMap { ($0["type"] as? NSNumber)?.intValue }
            let current = ((monitor["Current Space"] as? [String: Any])?["type"] as? NSNumber)?.intValue
            perDisplay.append(DisplaySpaces(displayIdentifier: identifier, spaceTypes: types, currentSpaceType: current))
        }
        return SpacesInfo(displaysHaveSeparateSpaces: NSScreen.screensHaveSeparateSpaces, perDisplay: perDisplay)
    }

    static func windowManagement() -> WindowManagementSettings {
        let windowManager = "com.apple.WindowManager"
        return WindowManagementSettings(
            stageManagerEnabled: optionalBool(windowManager, "GloballyEnabled") ?? false,
            tilingByEdgeDrag: optionalBool(windowManager, "EnableTilingByEdgeDrag"),
            tilingByTopEdgeDrag: optionalBool(windowManager, "EnableTopTilingByEdgeDrag"),
            tilingOptionAccelerator: optionalBool(windowManager, "EnableTilingOptionAccelerator"),
            tiledWindowMargins: optionalBool(windowManager, "EnableTiledWindowMargins"),
            missionControlGroupsByApp: optionalBool("com.apple.dock", "expose-group-apps") ?? false,
            rearrangeSpacesByRecentUse: optionalBool("com.apple.dock", "mru-spaces") ?? true
        )
    }

    static func accessibility() -> TesseraCore.AccessibilitySettings {
        let workspace = NSWorkspace.shared
        return TesseraCore.AccessibilitySettings(
            voiceOver: workspace.isVoiceOverEnabled,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        )
    }

    // MARK: - Input

    static func input() -> InputInfo {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true,
        ] as CFDictionary
        let sources = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        return InputInfo(
            enabledKeyboardLayouts: sources.compactMap(inputSourceID),
            currentKeyboardLayout: current.flatMap(inputSourceID),
            secureInputActive: IsSecureEventInputEnabled()
        )
    }

    static func inputSourceID(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    // MARK: - Windows

    static func windowCensus() -> WindowCensus {
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        var byLayer: [String: Int] = [:]
        var pids: Set<Int> = []
        var layerZero = 0
        var layerZeroOnScreen = 0
        for window in list {
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            byLayer[String(layer), default: 0] += 1
            if let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue { pids.insert(pid) }
            guard layer == 0 else { continue }
            layerZero += 1
            // The key is only present for windows that are on screen.
            if (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true { layerZeroOnScreen += 1 }
        }
        let onScreenList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let layerZeroInOnScreenList = onScreenList.filter {
            (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0
        }.count
        return WindowCensus(
            total: list.count,
            layerZero: layerZero,
            layerZeroOnScreen: layerZeroOnScreen,
            layerZeroInOnScreenList: layerZeroInOnScreenList,
            owningProcesses: pids.count,
            byLayer: byLayer
        )
    }

    // MARK: - Other window managers

    static let knownManagers: [(name: String, bundleID: String?, processName: String?)] = [
        ("AeroSpace", "bobko.aerospace", nil),
        ("yabai", nil, "yabai"),
        ("Amethyst", "com.amethyst.Amethyst", nil),
        ("Rectangle", "com.knollsoft.Rectangle", nil),
        ("Rectangle Pro", "com.knollsoft.Hookshot", nil),
        ("Loop", "com.MrKai77.Loop", nil),
        ("Magnet", "com.crowdcafe.windowmagnet", nil),
    ]

    static func otherWindowManagers() -> [OtherWindowManager] {
        let processNames = runningProcessNames()
        return knownManagers.compactMap { manager in
            var running = false
            var version: String?
            if let bundleID = manager.bundleID {
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                running = !apps.isEmpty
                version = apps.first?.bundleURL.flatMap { Bundle(url: $0) }?
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            }
            if let processName = manager.processName { running = processNames.contains(processName) }

            var configPath: String?
            var bindings: BindingCensus?
            if manager.name == "AeroSpace", let path = aeroSpaceConfigPath(),
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                configPath = (path as NSString).abbreviatingWithTildeInPath
                bindings = AeroSpaceBindingCensus.census(inTOML: text)
            }
            guard running || configPath != nil else { return nil }
            return OtherWindowManager(
                name: manager.name, running: running, version: version,
                configPath: configPath, bindings: bindings
            )
        }
    }

    static func aeroSpaceConfigPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.aerospace.toml"]
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
        candidates.append("\(xdg)/aerospace/aerospace.toml")
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func runningProcessNames() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let found = proc_listallpids(&pids, bytes)
        guard found > 0 else { return [] }
        var names: Set<String> = []
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(found)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names.insert(string(fromNulTerminated: buffer)) }
        }
        return names
    }
}

extension Rect {
    /// Nil for non-finite or absurd values: one app reporting NaN must never crash the engine.
    init?(finite rect: CGRect) {
        let values = [rect.minX, rect.minY, rect.width, rect.height]
        guard values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) else { return nil }
        self.init(
            x: Int(rect.minX.rounded()),
            y: Int(rect.minY.rounded()),
            width: Int(rect.width.rounded()),
            height: Int(rect.height.rounded())
        )
    }

    /// For geometry the system itself guarantees finite (display bounds).
    init(cg rect: CGRect) {
        self = Rect(finite: rect) ?? .zero
    }
}
