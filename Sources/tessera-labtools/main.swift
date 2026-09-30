// Helpers for the live tests (audit F5): one binary built by SwiftPM instead of five files
// compiled by hand. Read-only except `drag` and `go-desktop`, which act like a person would.
// Never reads window titles.
import CoreGraphics
import Foundation

typealias MainConnection = @convention(c) () -> Int32
typealias ActiveSpace = @convention(c) (Int32) -> UInt64
typealias ManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

nonisolated(unsafe) let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
nonisolated func symbol<T>(_ name: String, _ type: T.Type) -> T { unsafeBitCast(dlsym(skyLight, name), to: type) }
let connection = symbol("SLSMainConnectionID", MainConnection.self)()

func activeSpace() -> UInt64 { symbol("SLSGetActiveSpace", ActiveSpace.self)(connection) }

/// Every Space of the display that shows the active one: (id, "desktop" | "fullscreen").
func spaces() -> [(UInt64, String)] {
    let displays = symbol("SLSCopyManagedDisplaySpaces", ManagedSpaces.self)(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    let active = activeSpace()
    let all = displays.map { display in
        ((display["Spaces"] as? [[String: Any]]) ?? []).compactMap { space -> (UInt64, String)? in
            guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
            return (id, (space["type"] as? NSNumber)?.intValue == 4 ? "fullscreen" : "desktop")
        }
    }
    return all.first { $0.contains { $0.0 == active } } ?? all.first ?? []
}

func post(key: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "active-space":
    // "<id> <kind> <desktop number or 0>"
    let active = activeSpace()
    let list = spaces()
    let kind = list.first { $0.0 == active }?.1 ?? "unknown"
    let number = list.filter { $0.1 == "desktop" }.firstIndex { $0.0 == active }.map { $0 + 1 } ?? 0
    print("\(active) \(kind) \(number)")
case "active-space-kind":
    print(spaces().first { $0.0 == activeSpace() }?.1 ?? "unknown")
case "spaces":
    for (id, kind) in spaces() { print("\(id) \(kind)") }
case "window-space":
    let id = UInt32(arguments[1])!
    let list = symbol("SLSCopySpacesForWindows", SpacesForWindows.self)(connection, 0x7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber]
    print("\(list?.first?.uint64Value ?? 0) \(activeSpace())")
case "visible-windows":
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    print(list.filter { entry in
        guard (entry[kCGWindowLayer as String] as? Int) == 0, ((entry[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
              let raw = entry[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw) else { return false }
        return rect.width >= 200 && rect.height >= 150
    }.count)
case "parked":
    let minX = Double(arguments[1])!, minY = Double(arguments[2])!
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for entry in list where (entry[kCGWindowLayer as String] as? Int) == 0 {
        guard let raw = entry[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw) else { continue }
        if rect.minX >= minX && rect.minY >= minY { print(entry[kCGWindowNumber as String] ?? "?") }
    }
case "drag":
    // Drags with the left button from (x1, y1) to (x2, y2), then puts the pointer back.
    let a = arguments.dropFirst().compactMap(Double.init)
    let from = CGPoint(x: a[0], y: a[1]), to = CGPoint(x: a[2], y: a[3])
    let source = CGEventSource(stateID: .hidSystemState)
    let pointer = CGEvent(source: nil)?.location ?? .zero
    func mouse(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    mouse(.mouseMoved, from); usleep(60_000)
    mouse(.leftMouseDown, from); usleep(80_000)
    for step in 1...20 {
        let t = Double(step) / 20
        mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(15_000)
    }
    usleep(100_000)
    mouse(.leftMouseUp, to); usleep(60_000)
    mouse(.mouseMoved, pointer)
case "go-desktop":
    // Returns the owner to desktop N (1-9) with Control-N, as macOS's own shortcut does.
    let digits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    guard let number = Int(arguments[1]), (1...9).contains(number) else { exit(64) }
    post(key: digits[number - 1], flags: .maskControl)
default:
    FileHandle.standardError.write(Data("usage: tessera-labtools active-space | active-space-kind | spaces | window-space <id> | visible-windows | parked <x> <y> | drag x1 y1 x2 y2 | go-desktop <n>\n".utf8))
    exit(64)
}
