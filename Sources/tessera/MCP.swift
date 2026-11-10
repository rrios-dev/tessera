import AppKit
import Foundation
import MCPKit
import TesseraConfig
import TesseraCore
import TesseraEngine
import TesseraMCP
import TesseraPlatform

/// `tessera mcp`: Tessera's MCP server for agents (ADR 0005), launched by the agent over
/// stdio. This same signed binary is the client the engine already trusts for commands.
///
///   claude mcp add --scope user tessera -- ~/.local/bin/tessera mcp
///
/// stdout carries only the protocol.
enum MCPServer {
    static func serve() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent(LocalConfig.homeRelativePath)
        let log = AccessLog(directory: StatePaths().directory)
        let tools = TesseraTools(owners: { ids in
            WindowServer.owners(of: ids).mapValues { owner in
                let app = NSRunningApplication(processIdentifier: owner.pid)
                return WindowOwner(name: app?.localizedName ?? owner.name, bundleID: app?.bundleIdentifier)
            }
        }, replaced: ExecutableIdentity.replacedSinceLaunch())
        let server = Server(
            info: Server.Info(name: "tessera", title: "Tessera", version: BuildInfo.version, instructions: TesseraTools.instructions),
            tools: tools.all,
            gate: { enabled(config) ? nil : refusal },
            onCall: log.recorder()
        )
        await server.run()
    }

    static let refusal = """
        Tessera's agent access is off. The user can turn it on by adding `[agents]` with \
        `enabled = true` to ~/.config/tessera/tessera.local.toml.
        """

    /// Read on every call, so turning it off takes effect at once.
    static func enabled(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let config = try? LocalConfig.parse(text) else { return false }
        return config.agentsEnabled == true
    }
}
