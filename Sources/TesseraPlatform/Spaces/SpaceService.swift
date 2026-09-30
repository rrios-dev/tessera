public import TesseraCore
import TesseraPorts
import CoreGraphics
import Foundation

/// Read-only access to native Spaces through SkyLight (private API, no SIP changes).
///
/// Approved by the owner on 2026-09-25: Tessera reads the active Space, the Spaces of each
/// display and the Space of each window. It never moves windows between Spaces or switches
/// Spaces through SkyLight. Every symbol is resolved at runtime; if one is missing the service
/// reports itself unavailable and the engine falls back to a single implicit Space.
public final class SpaceService: @unchecked Sendable {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias ManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let connection: Int32
    private let activeSpaceFunction: ActiveSpace?
    private let managedSpacesFunction: ManagedDisplaySpaces?
    private let spacesForWindowsFunction: SpacesForWindows?

    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        connection = symbol("SLSMainConnectionID", as: MainConnection.self)?() ?? 0
        activeSpaceFunction = symbol("SLSGetActiveSpace", as: ActiveSpace.self)
        managedSpacesFunction = symbol("SLSCopyManagedDisplaySpaces", as: ManagedDisplaySpaces.self)
        spacesForWindowsFunction = symbol("SLSCopySpacesForWindows", as: SpacesForWindows.self)
    }

    public var isAvailable: Bool {
        connection != 0 && activeSpaceFunction != nil && managedSpacesFunction != nil && spacesForWindowsFunction != nil
    }

    public func activeSpace() -> SpaceID? {
        Metrics.count(.skyLightCalls)
        guard let activeSpaceFunction, connection != 0 else { return nil }
        let id = activeSpaceFunction(connection)
        return id == 0 ? nil : id
    }

    /// Every Space of every display. Type 0 is a desktop; 4 is a native full-screen Space.
    public func spaces() -> [SpaceDescriptor] {
        Metrics.count(.skyLightCalls)
        guard let managedSpacesFunction, connection != 0,
              let displays = managedSpacesFunction(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        var result: [SpaceDescriptor] = []
        for display in displays {
            for space in (display["Spaces"] as? [[String: Any]]) ?? [] {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                result.append(SpaceDescriptor(id: id, kind: type == 4 ? .fullscreen : .desktop))
            }
        }
        return result
    }

    /// Every Space a window is on: more than one for "assign to all desktops".
    public func spaces(of window: WindowID) -> [SpaceID] {
        Metrics.count(.skyLightCalls)
        guard let spacesForWindowsFunction, connection != 0,
              let ids = spacesForWindowsFunction(connection, 0x7, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
        else { return [] }
        return ids.map(\.uint64Value)
    }

    /// The Spaces of the display showing the active Space, in Mission Control order.
    public func spaceOrder() -> [SpaceID] {
        Metrics.count(.skyLightCalls)
        guard let managedSpacesFunction, connection != 0,
              let displays = managedSpacesFunction(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        let active = activeSpace()
        let orders = displays.map { display in
            ((display["Spaces"] as? [[String: Any]]) ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        }
        return orders.first { order in active.map(order.contains) ?? false } ?? orders.first ?? []
    }

    /// Private API can change under an OS update (audit B8). The answers must agree with each
    /// other before the engine trusts them: the active Space is one of the managed Spaces.
    public func selfTest() -> Bool {
        guard isAvailable, let active = activeSpace() else { return false }
        return spaces().contains { $0.id == active }
    }
}
