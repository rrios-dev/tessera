/// A snapshot of the machine Tessera runs on: displays, system settings that change
/// window-manager behaviour, and a title-free census of windows.
///
/// Produced by `tessera doctor`, committed under `fixtures/`, and loaded by the fake
/// window server so every arrangement a user reports can be replayed without the hardware.
/// Window titles are never collected.
public struct EnvironmentFixture: Codable, Sendable, Equatable {
    /// Bumped on any incompatible change; loaders reject unknown versions.
    public static let currentSchema = 1

    public var schema: Int
    public var capturedAt: String
    public var system: SystemInfo
    public var displays: [DisplayInfo]
    public var dock: DockInfo
    public var spaces: SpacesInfo
    public var windowManagement: WindowManagementSettings
    public var accessibility: AccessibilitySettings
    public var input: InputInfo
    public var windows: WindowCensus
    public var otherWindowManagers: [OtherWindowManager]

    public init(
        schema: Int = EnvironmentFixture.currentSchema,
        capturedAt: String,
        system: SystemInfo,
        displays: [DisplayInfo],
        dock: DockInfo,
        spaces: SpacesInfo,
        windowManagement: WindowManagementSettings,
        accessibility: AccessibilitySettings,
        input: InputInfo,
        windows: WindowCensus,
        otherWindowManagers: [OtherWindowManager]
    ) {
        self.schema = schema
        self.capturedAt = capturedAt
        self.system = system
        self.displays = displays
        self.dock = dock
        self.spaces = spaces
        self.windowManagement = windowManagement
        self.accessibility = accessibility
        self.input = input
        self.windows = windows
        self.otherWindowManagers = otherWindowManagers
    }
}

public struct SystemInfo: Codable, Sendable, Equatable {
    public var osVersion: String
    public var osBuild: String
    public var hardwareModel: String
    public var architecture: String

    public init(osVersion: String, osBuild: String, hardwareModel: String, architecture: String) {
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.hardwareModel = hardwareModel
        self.architecture = architecture
    }
}

public struct DisplayInfo: Codable, Sendable, Equatable {
    public var displayID: UInt32
    /// `CGDisplayCreateUUIDFromDisplayID`; identical monitors without a serial may share it.
    public var uuid: String?
    public var name: String
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    /// Recorded for diagnosis only: not stable across reconnects, never used as a key.
    public var unitNumber: UInt32
    public var isMain: Bool
    public var isBuiltin: Bool
    public var mirrorsDisplayID: UInt32?
    public var rotationDegrees: Int
    /// Global points, top-left origin.
    public var frame: Rect
    /// Global points, top-left origin; excludes the menu bar and the Dock.
    public var visibleFrame: Rect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var backingScale: Double
    public var refreshHz: Double
    public var safeAreaInsets: Insets
    /// `frame.top` to `visibleFrame.top`; `NSStatusBar.thickness` under-reports it.
    public var menuBarHeight: Int

    public init(
        displayID: UInt32, uuid: String?, name: String, vendor: UInt32, model: UInt32,
        serial: UInt32, unitNumber: UInt32, isMain: Bool, isBuiltin: Bool,
        mirrorsDisplayID: UInt32?, rotationDegrees: Int, frame: Rect, visibleFrame: Rect,
        pixelWidth: Int, pixelHeight: Int, backingScale: Double, refreshHz: Double,
        safeAreaInsets: Insets, menuBarHeight: Int
    ) {
        self.displayID = displayID
        self.uuid = uuid
        self.name = name
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.unitNumber = unitNumber
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.mirrorsDisplayID = mirrorsDisplayID
        self.rotationDegrees = rotationDegrees
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.backingScale = backingScale
        self.refreshHz = refreshHz
        self.safeAreaInsets = safeAreaInsets
        self.menuBarHeight = menuBarHeight
    }

    public var isPortrait: Bool { frame.height > frame.width }
}

public struct DockInfo: Codable, Sendable, Equatable {
    /// `bottom`, `left` or `right`.
    public var orientation: String
    public var autohide: Bool
    public var tileSize: Int?

    public init(orientation: String, autohide: Bool, tileSize: Int?) {
        self.orientation = orientation
        self.autohide = autohide
        self.tileSize = tileSize
    }
}

public struct SpacesInfo: Codable, Sendable, Equatable {
    /// "Displays have separate Spaces", read after `NSApplication` is initialised.
    public var displaysHaveSeparateSpaces: Bool
    public var perDisplay: [DisplaySpaces]

    public init(displaysHaveSeparateSpaces: Bool, perDisplay: [DisplaySpaces]) {
        self.displaysHaveSeparateSpaces = displaysHaveSeparateSpaces
        self.perDisplay = perDisplay
    }
}

public struct DisplaySpaces: Codable, Sendable, Equatable {
    /// A display UUID, or `Main` when Spaces span all displays.
    public var displayIdentifier: String
    /// Raw Space types from `com.apple.spaces`: 0 is a desktop, 4 is a native full-screen Space.
    public var spaceTypes: [Int]
    public var currentSpaceType: Int?

    public init(displayIdentifier: String, spaceTypes: [Int], currentSpaceType: Int?) {
        self.displayIdentifier = displayIdentifier
        self.spaceTypes = spaceTypes
        self.currentSpaceType = currentSpaceType
    }

    /// Desktop Spaces only: native full-screen Spaces must not trigger "more than one Space" warnings.
    public var desktopSpaceCount: Int { spaceTypes.filter { $0 == 0 }.count }
}

public struct WindowManagementSettings: Codable, Sendable, Equatable {
    public var stageManagerEnabled: Bool
    public var tilingByEdgeDrag: Bool?
    public var tilingByTopEdgeDrag: Bool?
    public var tilingOptionAccelerator: Bool?
    public var tiledWindowMargins: Bool?
    public var missionControlGroupsByApp: Bool
    public var rearrangeSpacesByRecentUse: Bool

    public init(
        stageManagerEnabled: Bool, tilingByEdgeDrag: Bool?, tilingByTopEdgeDrag: Bool?,
        tilingOptionAccelerator: Bool?, tiledWindowMargins: Bool?,
        missionControlGroupsByApp: Bool, rearrangeSpacesByRecentUse: Bool
    ) {
        self.stageManagerEnabled = stageManagerEnabled
        self.tilingByEdgeDrag = tilingByEdgeDrag
        self.tilingByTopEdgeDrag = tilingByTopEdgeDrag
        self.tilingOptionAccelerator = tilingOptionAccelerator
        self.tiledWindowMargins = tiledWindowMargins
        self.missionControlGroupsByApp = missionControlGroupsByApp
        self.rearrangeSpacesByRecentUse = rearrangeSpacesByRecentUse
    }
}

public struct AccessibilitySettings: Codable, Sendable, Equatable {
    public var voiceOver: Bool
    public var reduceMotion: Bool
    public var increaseContrast: Bool
    public var reduceTransparency: Bool
    public var differentiateWithoutColor: Bool

    public init(
        voiceOver: Bool, reduceMotion: Bool, increaseContrast: Bool,
        reduceTransparency: Bool, differentiateWithoutColor: Bool
    ) {
        self.voiceOver = voiceOver
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        self.reduceTransparency = reduceTransparency
        self.differentiateWithoutColor = differentiateWithoutColor
    }
}

public struct InputInfo: Codable, Sendable, Equatable {
    public var enabledKeyboardLayouts: [String]
    public var currentKeyboardLayout: String?
    public var secureInputActive: Bool

    public init(enabledKeyboardLayouts: [String], currentKeyboardLayout: String?, secureInputActive: Bool) {
        self.enabledKeyboardLayouts = enabledKeyboardLayouts
        self.currentKeyboardLayout = currentKeyboardLayout
        self.secureInputActive = secureInputActive
    }
}

/// Counts only: no titles, no bundle names, no bounds.
public struct WindowCensus: Codable, Sendable, Equatable {
    public var total: Int
    public var layerZero: Int
    /// Layer-0 entries of `.optionAll` that carry `kCGWindowIsOnscreen = true`.
    public var layerZeroOnScreen: Int
    /// Layer-0 entries of `.optionOnScreenOnly`; kept next to the flag count because the two
    /// sources disagree often enough to matter for the liveness rule (spikes S1 and S10).
    public var layerZeroInOnScreenList: Int
    public var owningProcesses: Int
    public var byLayer: [String: Int]

    public init(
        total: Int, layerZero: Int, layerZeroOnScreen: Int, layerZeroInOnScreenList: Int,
        owningProcesses: Int, byLayer: [String: Int]
    ) {
        self.total = total
        self.layerZero = layerZero
        self.layerZeroOnScreen = layerZeroOnScreen
        self.layerZeroInOnScreenList = layerZeroInOnScreenList
        self.owningProcesses = owningProcesses
        self.byLayer = byLayer
    }
}

public struct OtherWindowManager: Codable, Sendable, Equatable {
    public var name: String
    public var running: Bool
    public var version: String?
    public var configPath: String?
    public var bindings: BindingCensus?

    public init(name: String, running: Bool, version: String?, configPath: String?, bindings: BindingCensus?) {
        self.name = name
        self.running = running
        self.version = version
        self.configPath = configPath
        self.bindings = bindings
    }
}

/// How an imported keymap is distributed across modifier combinations.
///
/// `optionOnlyFamily` counts chords whose modifiers are Option or Option+Shift: on
/// layouts such as Spanish-ISO those produce printable characters (`@`, `#`, `|`), so a
/// global hotkey on them swallows typing and the importer must remap them.
public struct BindingCensus: Codable, Sendable, Equatable {
    public var total: Int
    public var optionOnlyFamily: Int
    public var byModifiers: [String: Int]

    public init(total: Int, optionOnlyFamily: Int, byModifiers: [String: Int]) {
        self.total = total
        self.optionOnlyFamily = optionOnlyFamily
        self.byModifiers = byModifiers
    }
}
