// Reads CGWindowList bounds and drives window sizes through the Accessibility API,
// the same path Tessera will use. Never reads titles.
// usage: swift axprobe.swift bounds <windowNumber>...
//        swift axprobe.swift setsize <pid> <windowNumber> <width> <height>
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func bounds(_ id: CGWindowID) -> [String: Int]? {
    let list = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]) ?? []
    guard let raw = list.first?[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: raw) else { return nil }
    return ["x": Int(rect.minX), "y": Int(rect.minY), "width": Int(rect.width), "height": Int(rect.height)]
}

func axWindow(pid: pid_t, number: CGWindowID) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    return windows.first { element in
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id == number
    }
}

func axFrame(_ element: AXUIElement) -> [String: Int]? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return ["x": Int(point.x), "y": Int(point.y), "width": Int(size.width), "height": Int(size.height)]
}

let arguments = CommandLine.arguments
var output: [String: Any] = ["trusted": AXIsProcessTrusted()]
switch arguments[1] {
case "bounds":
    var all: [String: Any] = [:]
    for number in arguments.dropFirst(2) { all[number] = bounds(CGWindowID(number)!) ?? NSNull() }
    output["bounds"] = all
case "setsize":
    let pid = pid_t(arguments[2])!
    let number = CGWindowID(arguments[3])!
    var size = CGSize(width: Double(arguments[4])!, height: Double(arguments[5])!)
    guard let element = axWindow(pid: pid, number: number) else {
        output["error"] = "window not found through AX"
        break
    }
    let value = AXValueCreate(.cgSize, &size)!
    let start = DispatchTime.now()
    let error = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    output["setError"] = error.rawValue
    output["setMilliseconds"] = elapsed
    output["axFrameImmediately"] = axFrame(element) ?? NSNull()
    output["cgBoundsImmediately"] = bounds(number) ?? NSNull()
default:
    output["error"] = "unknown command"
}
let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
