import Darwin
public import Foundation

/// Newline-delimited JSON over a Unix domain socket, mode 0600, same user only.
public enum LineSocket {
    /// Longest request accepted; a client sending more without a newline is dropped.
    public static let maxLine = 64 * 1024
    /// Concurrent connections served; more are closed at once.
    public static let maxConnections = 8
    /// A client that sends nothing for this long is dropped.
    public static let readTimeout = 5

    /// The socket for a state directory: the historical per-user path for the default one (the
    /// CLI finds it without flags), a path inside any other one, so a test or benchmark engine
    /// never takes the owner's socket (audit A2). `TESSERA_SOCKET` overrides both.
    public static func path(stateDirectory: URL?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = environment["TESSERA_SOCKET"], !explicit.isEmpty { return explicit }
        if let stateDirectory {
            let inside = stateDirectory.appendingPathComponent("tessera.sock").path
            // sun_path holds 104 bytes; long directories fall back to a short hashed name.
            if inside.utf8.count < 100 { return inside }
            return temporaryDirectory(environment) + "tessera-\(getuid())-\(stableHash(stateDirectory.path)).sock"
        }
        return temporaryDirectory(environment) + "tessera-\(getuid()).sock"
    }

    public static func defaultPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["TESSERA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return path(stateDirectory: home, environment: environment)
    }

    static func temporaryDirectory(_ environment: [String: String]) -> String {
        let directory = environment["TMPDIR"] ?? "/tmp/"
        return directory.hasSuffix("/") ? directory : directory + "/"
    }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// Sends one line and waits for one line back.
    public static func request(_ line: Data, path: String = defaultPath(), timeout: TimeInterval = 5) throws -> Data {
        let descriptor = try connect(path)
        defer { close(descriptor) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var payload = line
        payload.append(0x0A)
        guard writeAll(descriptor, payload) else { throw POSIXError(.EPIPE) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !received.contains(0x0A) {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return received.prefix { $0 != 0x0A }
    }

    /// The connected process's audit token: identifies it for a code-signature check, unlike
    /// its pid, which can be reused (audit B4).
    static func auditToken(_ descriptor: Int32) -> Data? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// A peer that disconnects early must never kill the process with SIGPIPE.
    static func noSignalOnBrokenPipe(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func connect(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        noSignalOnBrokenPipe(descriptor)
        var address = try makeAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
        return descriptor
    }

    /// Whether an engine answers on `path`.
    public static func isServed(_ path: String) -> Bool {
        guard let descriptor = try? connect(path) else { return false }
        close(descriptor)
        return true
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    public enum ServerError: Error, CustomStringConvertible {
        case inUse(String)
        case failed(String)

        public var description: String {
            switch self {
            case .inUse(let path): "another Tessera engine answers on \(path)"
            case .failed(let reason): reason
            }
        }
    }

    /// One thread per connection, at most `maxConnections`; `handler` is called off the main thread.
    public final class Server: @unchecked Sendable {
        /// The line, and the client's audit token (nil if the kernel would not give it).
        public typealias Handler = @Sendable (Data, Data?) -> Data
        private let path: String
        private let handler: Handler
        private var listener: Int32 = -1
        private let lock = NSLock()
        private var connections = 0
        private var stopped = false

        public init(path: String = LineSocket.defaultPath(), handler: @escaping Handler) {
            self.path = path
            self.handler = handler
        }

        public func start() throws {
            // A client that hangs up before reading its reply must not kill the engine. The
            // per-socket option covers the socket; this covers every other descriptor too.
            signal(SIGPIPE, SIG_IGN)
            // Never unlink a socket another engine still answers on (audit A2).
            if LineSocket.isServed(path) { throw ServerError.inUse(path) }
            unlink(path)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw ServerError.failed("socket() failed") }
            var address = try LineSocket.makeAddress(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(listener, 16) == 0 else { throw ServerError.failed("cannot listen on \(path)") }
            chmod(path, 0o600)
            let thread = Thread { [self] in acceptLoop() }
            thread.name = "tessera.ipc"
            thread.start()
        }

        private func acceptLoop() {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    if isStopped { return }
                    // Back off instead of spinning when accept fails (e.g. out of descriptors).
                    usleep(100_000)
                    continue
                }
                guard reserve() else {
                    close(client)
                    continue
                }
                Thread { [self] in
                    serve(client)
                    release()
                }.start()
            }
        }

        private var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        private func reserve() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard connections < LineSocket.maxConnections else { return false }
            connections += 1
            return true
        }

        private func release() {
            lock.lock()
            connections -= 1
            lock.unlock()
        }

        public var activeConnections: Int {
            lock.lock()
            defer { lock.unlock() }
            return connections
        }

        public func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
            if listener >= 0 { close(listener) }
            unlink(path)
        }

        private func serve(_ client: Int32) {
            defer { close(client) }
            LineSocket.noSignalOnBrokenPipe(client)
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else { return }
            var tv = timeval(tv_sec: LineSocket.readTimeout, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let token = LineSocket.auditToken(client)
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { return }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                    var reply = handler(line, token)
                    reply.append(0x0A)
                    guard LineSocket.writeAll(client, reply) else { return }
                }
                guard pending.count <= LineSocket.maxLine else { return }
            }
        }
    }
}
