import CoreGraphics
import Foundation
import Testing
import TesseraCore
@testable import TesseraPlatform

/// Checks the window-server queries against the live window server. Needs a GUI session; with
/// no windows on screen (a headless runner) the tests have nothing to compare and return.
struct WindowServerTests {
    func onScreenIDs() -> [WindowID] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    @Test func presenceReportsExistingOnScreenWindows() {
        let ids = Array(onScreenIDs().prefix(20))
        guard !ids.isEmpty else { return }
        let presence = WindowServer.presence(of: ids)
        // Every id came from the on-screen list a moment ago: all must exist.
        #expect(presence.existing == Set(ids), "presence lost windows: \(Set(ids).subtracting(presence.existing))")
        #expect(!presence.onScreen.isEmpty)
    }

    @Test func presenceDropsUnknownWindows() {
        let unknown: WindowID = 0xFFFF_FFF0
        let ids = Array(onScreenIDs().prefix(3)) + [unknown]
        let presence = WindowServer.presence(of: ids)
        #expect(!presence.existing.contains(unknown))
    }

    @Test func existingAndPresenceAgree() {
        let ids = Array(onScreenIDs().prefix(20))
        guard !ids.isEmpty else { return }
        let all = WindowServer.existingWindowIDs()
        #expect(WindowServer.presence(of: ids).existing == Set(ids).intersection(all))
    }
}

/// Audit B6: a non-finite frame from any app is rejected, never a crash.
struct FiniteRectTests {
    @Test func nonFiniteFramesAreRejected() {
        #expect(Rect(finite: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)) == nil)
        #expect(Rect(finite: CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10)) == nil)
        #expect(Rect(finite: CGRect(x: 0, y: 0, width: 1e12, height: 10)) == nil)
        #expect(Rect(finite: CGRect(x: 1.4, y: 2.6, width: 10, height: 10)) == Rect(x: 1, y: 3, width: 10, height: 10))
    }

    @Test func privateWindowLookupResolvesAtRuntime() {
        // Resolved by dlsym, never linked: an OS without it degrades instead of refusing to launch.
        #expect(WindowIdentity.privateAPIAvailable)
    }
}

/// Audit B4/B7: a development build has no team, so it trusts every client; a team check of a
/// process that is not signed by that team fails.
struct CodeSignatureTests {
    @Test func developmentBuildsHaveNoTeam() {
        #expect(CodeSignature.ownTeam == nil)
    }

    @Test func aProcessNotSignedByTheTeamIsNotTrusted() {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        #expect(result == KERN_SUCCESS)
        let data = withUnsafeBytes(of: &token) { Data($0) }
        #expect(!CodeSignature.process(auditToken: data, isSignedBy: "ABCDE12345"))
    }
}
