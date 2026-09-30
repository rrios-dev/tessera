import Darwin
import DummyWindowKit
import Foundation

/// Line-delimited JSON over a Unix domain socket. Each connection is served on its own
/// thread; requests are executed on the main thread because they touch AppKit.
final class SocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (Request) -> Response

    private let path: String
    private let handler: Handler
    private var listener: Int32 = -1

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)

        let thread = Thread { [self] in acceptLoop() }
        thread.name = "DummyWindowApp.accept"
        thread.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            let thread = Thread { [self] in serve(client) }
            thread.start()
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard !line.isEmpty else { continue }
                let response: Response
                if let request = try? decoder.decode(Request.self, from: line) {
                    response = handler(request)
                } else {
                    response = .failure("malformed request")
                }
                var data = (try? encoder.encode(response)) ?? Data(#"{"ok":false}"#.utf8)
                data.append(0x0A)
                data.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
            }
        }
    }
}
