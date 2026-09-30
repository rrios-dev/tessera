import Foundation
import Security

/// Tessera's own code signature, and checks of other processes against it (audit B4, B7).
enum CodeSignature {
    /// The team that signed this process; nil for an ad hoc (development) build.
    static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Whether the process behind `auditToken` is validly signed by `team` with an Apple-issued
    /// certificate. Nothing is trusted on error.
    static func process(auditToken: Data, isSignedBy team: String) -> Bool {
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}
