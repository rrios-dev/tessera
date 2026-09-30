public import TesseraCore
import TesseraPorts
import CoreGraphics
import Foundation

/// Facts from the window server that need no permission: which windows exist and where
/// they really are. Titles are never read.
public enum WindowServer {
    /// For the given windows only: which still exist and which are on screen, in one call whose
    /// cost grows with the windows Tessera tracks rather than with every window of the system.
    public static func presence(of ids: [WindowID]) -> (existing: Set<WindowID>, onScreen: Set<WindowID>) {
        Metrics.count(.windowListCopies)
        guard !ids.isEmpty else { return ([], []) }
        // The array holds raw CGWindowID values, not NSNumbers: with NSNumbers the call returns
        // nothing and every window would look closed (found by the live tests, 2026-09-25).
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = pointers.withUnsafeMutableBufferPointer { buffer in
            CFArrayCreate(nil, buffer.baseAddress, buffer.count, nil)
        }
        guard let array, let list = CGWindowListCreateDescriptionFromArray(array) as? [NSDictionary] else { return ([], []) }
        var existing: Set<WindowID> = []
        var onScreen: Set<WindowID> = []
        for entry in list {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            existing.insert(id)
            if (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true { onScreen.insert(id) }
        }
        return (existing, onScreen)
    }

    /// Every window id currently known to the window server, on any Space.
    public static func existingWindowIDs() -> Set<WindowID> {
        Metrics.count(.windowListCopies)
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// Windows the window server currently draws on screen (on the active Space).
    public static func onScreenWindowIDs() -> Set<WindowID> {
        Metrics.count(.windowListCopies)
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// Owner of every ordinary (layer 0) window on screen, for discovering windows whose
    /// creation notification was missed.
    public static func onScreenOwners() -> [WindowID: Int32] {
        Metrics.count(.windowListCopies)
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var result: [WindowID: Int32] = [:]
        for entry in list where ((entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0 {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            result[id] = pid
        }
        return result
    }

    /// The frames the window server actually draws, top-left points.
    public static func bounds(of ids: [WindowID]) -> [WindowID: Rect] {
        Metrics.count(.windowListCopies)
        var result: [WindowID: Rect] = [:]
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let wanted = Set(ids)
        for entry in list {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, wanted.contains(id),
                  let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw), let finite = Rect(finite: rect) else { continue }
            result[id] = finite
        }
        return result
    }
}
