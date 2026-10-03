import Foundation

/// What build is running: the version, and the git commit `scripts/install.sh` writes into the
/// bundle's Info.plist (`TesseraGitSHA`), or `TESSERA_BUILD_SHA`, or "dev".
public enum BuildInfo {
    public static let version = "0.2.1"

    public static var commit: String {
        if let sha = Bundle.main.object(forInfoDictionaryKey: "TesseraGitSHA") as? String, !sha.isEmpty { return sha }
        if let sha = ProcessInfo.processInfo.environment["TESSERA_BUILD_SHA"], !sha.isEmpty { return sha }
        return "dev"
    }

    public static var description: String { "Tessera \(version) (\(commit))" }
}
