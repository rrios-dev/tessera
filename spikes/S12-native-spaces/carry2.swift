// Carry variant with tunable drag distance and hold time.
// usage: carry2 <window-id> <distance> <hold-ms-after-jump> [hid|session] [hid|combined|none]
import Carbon
import CoreGraphics
import Foundation
typealias C = @convention(c) () -> Int32
typealias A = @convention(c) (Int32) -> UInt64
typealias F = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let c = unsafeBitCast(dlsym(h, "SLSMainConnectionID"), to: C.self)()
let active = { unsafeBitCast(dlsym(h, "SLSGetActiveSpace"), to: A.self)(c) }
let spacesFor = unsafeBitCast(dlsym(h, "SLSCopySpacesForWindows"), to: F.self)
let id = CGWindowID(CommandLine.arguments[1])!, distance = Double(CommandLine.arguments[2])!, hold = UInt32(CommandLine.arguments[3])!
func space() -> UInt64 { (spacesFor(c, 0x7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber])?.first?.uint64Value ?? 0 }
let list = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]) ?? []
let frame = CGRect(dictionaryRepresentation: list.first![kCGWindowBounds as String] as! NSDictionary)!
let args = CommandLine.arguments
let tap: CGEventTapLocation = args.count > 4 && args[4] == "session" ? .cgSessionEventTap : .cghidEventTap
let source: CGEventSource? = args.count > 5 ? (args[5] == "combined" ? CGEventSource(stateID: .combinedSessionState) : args[5] == "none" ? nil : CGEventSource(stateID: .hidSystemState)) : CGEventSource(stateID: .hidSystemState)
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: tap) }
let grab = CGPoint(x: frame.midX, y: frame.minY + 12)
post(.mouseMoved, grab); usleep(60_000)
post(.leftMouseDown, grab); usleep(60_000)
var point = grab
for step in 1...10 { point = CGPoint(x: grab.x + distance * Double(step) / 10, y: grab.y + distance * Double(step) / 10); post(.leftMouseDragged, point); usleep(15_000) }
usleep(60_000)
let before = active()
for down in [true, false] { let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_2), keyDown: down)!; e.flags = .maskControl; e.post(tap: tap) }
let deadline = Date().addingTimeInterval(2)
while active() == before && Date() < deadline { usleep(5_000) }
for _ in 0..<(hold / 30) { post(.leftMouseDragged, point); usleep(30_000) }
post(.leftMouseUp, point); usleep(300_000)
print("\(args.dropFirst(4).joined(separator: "/")) distance \(Int(distance)): window on \(space()), active \(active())")
