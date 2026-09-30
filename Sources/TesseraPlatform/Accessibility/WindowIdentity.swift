import ApplicationServices
import CoreGraphics
import Foundation
import TesseraCore
import TesseraPorts

/// Maps an Accessibility window element to its window-server id.
///
/// `_AXUIElementGetWindow` is private (plan D7). It is resolved at runtime rather than linked,
/// so an OS update that removes it degrades to a public fallback instead of failing to launch:
/// the on-screen layer-0 window of the same process with the same frame.
enum WindowIdentity {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindow? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static var privateAPIAvailable: Bool { getWindow != nil }

    static func id(of element: AXUIElement, pid: Int32, frame: Rect? = nil) -> WindowID? {
        if let getWindow {
            var id: CGWindowID = 0
            if getWindow(element, &id) == .success, id != 0 { return id }
            return nil
        }
        guard let frame else { return nil }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        for entry in list where (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && ((entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0 {
            guard let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw), Rect(finite: bounds) == frame,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            return id
        }
        return nil
    }
}

enum AXOutcomeMapping {
    static func outcome(_ error: AXError) -> AXOutcome {
        switch error {
        case .success: .success
        case .apiDisabled: .apiDisabled
        case .cannotComplete: .cannotComplete
        case .invalidUIElement: .invalidElement
        default: .failure(error.rawValue)
        }
    }
}
