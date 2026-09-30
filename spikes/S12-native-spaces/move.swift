// Spike S12: jump to native desktops and carry a window between them, measured.
// usage: move <dummy-pid> <window-id>
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

typealias MainConnection = @convention(c) () -> Int32
typealias ActiveSpace = @convention(c) (Int32) -> UInt64
typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let connection = unsafeBitCast(dlsym(handle, "SLSMainConnectionID"), to: MainConnection.self)()
let activeSpace = { unsafeBitCast(dlsym(handle, "SLSGetActiveSpace"), to: ActiveSpace.self)(connection) }
let spacesFor = unsafeBitCast(dlsym(handle, "SLSCopySpacesForWindows"), to: SpacesForWindows.self)
@_silgen_name("_AXUIElementGetWindow") func axWindowID(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let pid = pid_t(CommandLine.arguments[1])!
let windowID = CGWindowID(CommandLine.arguments[2])!
let source = CGEventSource(stateID: .hidSystemState)

func space(of id: CGWindowID) -> UInt64 {
    (spacesFor(connection, 0x7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber])?.first?.uint64Value ?? 0
}
func key(_ code: Int, flags: CGEventFlags) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
@discardableResult
func waitForSpaceChange(from before: UInt64) -> Int {
    let start = Date()
    while activeSpace() == before && Date().timeIntervalSince(start) < 3 { usleep(5_000) }
    return Int(Date().timeIntervalSince(start) * 1000)
}
func jump(_ desktop: Int) -> String {
    let codes = [0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3]
    let before = activeSpace()
    key(codes[desktop], flags: .maskControl)
    let ms = waitForSpaceChange(from: before)
    return "Ctrl+\(desktop): \(before) -> \(activeSpace()) in \(ms) ms"
}
func axWindow() -> AXUIElement? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
    return (value as? [AXUIElement])?.first { var id: CGWindowID = 0; return axWindowID($0, &id) == .success && id == windowID }
}
func bounds() -> CGRect? {
    let list = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]) ?? []
    return (list.first?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
}

print("window \(windowID) starts on Space \(space(of: windowID)); active \(activeSpace())")

let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "both"
// A: minimise, jump, restore (public API only).
if mode != "hold", let window = axWindow() {
    let start = Date()
    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    usleep(250_000)
    let jumped = jump(2)
    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    usleep(400_000)
    print("A minimise+jump+restore: \(jumped); window now on \(space(of: windowID)); total \(Int(Date().timeIntervalSince(start) * 1000)) ms")
} else {
    print("A: window not reachable through AX")
}

// B: hold the title bar while jumping (the window travels with the pointer).
if mode != "minimise", let frame = bounds() {
    let grab = CGPoint(x: frame.midX, y: frame.minY + 12)
    let previousPointer = CGEvent(source: nil)?.location ?? .zero
    let start = Date()
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: grab, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: grab.x + 4, y: grab.y + 4), mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(80_000)
    let target = activeSpace() == space(of: windowID) ? (mode == "hold" ? 2 : 1) : 1
    let jumped = jump(target)
    usleep(150_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: grab.x + 4, y: grab.y + 4), mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(300_000)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: previousPointer, mouseButton: .left)!.post(tap: .cghidEventTap)
    print("B hold-title-bar+jump: \(jumped); window now on \(space(of: windowID)); total \(Int(Date().timeIntervalSince(start) * 1000)) ms")
}
