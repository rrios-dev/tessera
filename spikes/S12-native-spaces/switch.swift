// Switches one native Space left or right by posting Control-Arrow (the Mission Control
// shortcut) and reports how long macOS takes to make the new Space active.
// usage: switch <left|right>
import Carbon
import CoreGraphics
import Foundation
typealias MainConnection = @convention(c) () -> Int32
typealias ActiveSpace = @convention(c) (Int32) -> UInt64
let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let connection = unsafeBitCast(dlsym(handle, "SLSMainConnectionID"), to: MainConnection.self)()
let activeSpace = unsafeBitCast(dlsym(handle, "SLSGetActiveSpace"), to: ActiveSpace.self)
let key = CommandLine.arguments[1] == "left" ? CGKeyCode(kVK_LeftArrow) : CGKeyCode(kVK_RightArrow)
let before = activeSpace(connection)
let source = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
    event.flags = [.maskControl, .maskSecondaryFn]
    event.post(tap: .cghidEventTap)
}
let start = Date()
var after = before
while after == before && Date().timeIntervalSince(start) < 3 {
    usleep(5_000)
    after = activeSpace(connection)
}
print("from \(before) to \(after) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
