import AppKit
import DummyWindowKit
import Foundation

/// Scriptable test windows for the harness and spike S1.
///
/// usage: DummyWindowApp --socket <path>
/// then send one JSON request per line, e.g. with `nc -U <path>`.
let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--socket"), flag + 1 < arguments.count else {
    FileHandle.standardError.write(Data("usage: DummyWindowApp --socket <path>\n".utf8))
    exit(64)
}
let socketPath = arguments[flag + 1]

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let controller = Controller()
let server = SocketServer(path: socketPath) { request in
    DispatchQueue.main.sync { MainActor.assumeIsolated { controller.handle(request) } }
}

do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("DummyWindowApp: cannot listen on \(socketPath): \(error)\n".utf8))
    exit(1)
}
application.run()
