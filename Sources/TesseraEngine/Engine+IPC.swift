public import Foundation
import TesseraCore
import TesseraIPC
import TesseraPorts

extension Engine {
    func startIPC() {
        let server = LineSocket.Server(path: paths.socket) { [weak self] line, token in
            // Requests are answered on the main actor, one at a time.
            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.answer(line, auditToken: token) ?? Data() } }
        }
        do {
            try server.start()
            self.server = server
            log.info("listening on \(paths.socket)", .ipc)
        } catch {
            log.error("IPC unavailable: \(error)", .ipc)
        }
    }

    /// - Parameter auditToken: the client's; nil only for in-process callers (tests).
    public func answer(_ line: Data, auditToken: Data? = nil) -> Data {
        Metrics.count(.ipcRequests)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let response = respond(line, auditToken: auditToken)
        return (try? encoder.encode(response)) ?? Data()
    }

    func respond(_ line: Data, auditToken: Data? = nil) -> IPCResponse {
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: line) else {
            return IPCResponse(ok: false, error: "malformed request")
        }
        let now = port.now()
        // Any process of this user can reach the socket. Commands that move windows or change
        // Tessera run only for programs signed by Tessera's own team, so no other process can
        // use Tessera's Accessibility permission as its own (audit B4). Queries stay open: they
        // expose nothing the window server does not already give any process.
        if request.isMutating, let auditToken, !port.peerSharesTeam(auditToken: auditToken) {
            Metrics.count(.ipcRejected)
            log.notice("IPC command refused: the client is not signed by Tessera's team", .ipc)
            return IPCResponse(ok: false, error: "refused: only programs signed by Tessera's developer may send commands")
        }
        if request.isMutating {
            // Any process of this user can talk to the socket: bound what it can make Tessera do
            // (audit B4; the code-signature check comes with the signed bundle).
            let isFocus = request.command?.first == "focus"
            guard ipcBudget.allow(now: now), !isFocus || focusBudget.allow(now: now) else {
                Metrics.count(.ipcRejected)
                log.info("IPC request rate-limited", .ipc)
                return IPCResponse(ok: false, error: "rate limited")
            }
        }
        if let words = request.command {
            do {
                let command = try CommandParser.parse(words)
                guard status.isActive else { return IPCResponse(ok: false, error: "Tessera is \(statusWord)") }
                execute(command)
                return IPCResponse(ok: true)
            } catch {
                return IPCResponse(ok: false, error: error.description)
            }
        }
        if let action = request.action {
            switch action {
            case "pause": if status.isActive { togglePause() }
            case "resume": if case .paused = status { resume() }
            case "toggle-pause": togglePause()
            case "gather", "retile": retileAll()
            case "reload-config": reloadConfig()
            case "forget-sizes": forgetLearnedSizes()
            case "revert-layout":
                guard canRevert else { return IPCResponse(ok: false, error: "the original layout is no longer available") }
                revertToOriginalLayout()
            case "retry": retryFromSafeMode()
            default: return IPCResponse(ok: false, error: "unknown action '\(action)'")
            }
            return IPCResponse(ok: true, info: ["status": statusWord])
        }
        switch request.query {
        case "stats":
            return IPCResponse(ok: true, stats: Metrics.snapshot(), info: info())
        case "activity":
            let formatter = ISO8601DateFormatter()
            return IPCResponse(ok: true, lines: activity.map { "\(formatter.string(from: $0.at)) \($0.notice.kind.rawValue) \($0.notice.key): \($0.notice.text)" })
        case "check":
            let violations = checkInvariants()
            return IPCResponse(ok: violations.isEmpty, lines: violations)
        case "state":
            // `state` reads the window server: repeated requests within 100 ms share one answer
            // so a client polling in a loop cannot slow the hotkeys down (audit B5) — only while the
            // model is unchanged, or a command's effect would be reported late (found live).
            if let cached = cachedState, now.timeIntervalSince(cached.at) < 0.1, cached.world == world,
               let response = try? JSONDecoder().decode(IPCResponse.self, from: cached.reply) {
                return response
            }
            guard let area = tilingArea else { return IPCResponse(ok: false, error: "no screen") }
            let render = Renderer.render(world, area: area)
            let drawn = port.bounds(of: Array(render.frames.keys))
            let accessibility = observed.filter { render.frames[$0.key] != nil }
            let response = IPCResponse(ok: true, state: StateSnapshot(world: world, render: render, observed: drawn, area: area, accessibility: accessibility))
            if let encoded = try? JSONEncoder().encode(response) { cachedState = (now, world, encoded) }
            return response
        default:
            return IPCResponse(ok: false, error: "unknown request")
        }
    }

    var statusWord: String {
        switch status {
        case .starting: "starting"
        case .active: "active"
        case .paused(.user): "paused"
        case .paused(.stageManager): "paused (Stage Manager)"
        case .paused(.conflict(let names)): "paused (\(names.joined(separator: ", ")) running)"
        case .noPermission: "waiting for the Accessibility permission"
        case .safeMode: "in safe mode"
        }
    }

    func info() -> [String: String] {
        [
            "version": BuildInfo.description,
            "pid": String(getpid()),
            "status": statusWord,
            "uptime": String(Int(port.now().timeIntervalSince(startedAt))),
            "stateDirectory": paths.directory.path,
            "socket": paths.socket,
            "lastError": log.lastError ?? "",
            "journalEntries": String(journal.hidden.count),
            "windows": String(world.windows.count),
            "apps": String(drivers.count),
            "edgeClamp": "\(edgeClamp.insets.top),\(edgeClamp.insets.left),\(edgeClamp.insets.bottom),\(edgeClamp.insets.right)",
            "spaces": port.spacesAvailable ? "skylight" : "unavailable",
        ]
    }
}
