import Darwin
import Foundation
import Testing
@testable import TesseraIPC

/// Audit A2, B5: the socket never steals another engine's path and bounds what a client can do.
struct LineSocketTests {
    func temporarySocket() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UInt32.random(in: 0...UInt32.max)).sock").path
    }

    @Test func answersOneLinePerRequest() throws {
        let path = temporarySocket()
        let server = LineSocket.Server(path: path) { line, _ in Data("echo:".utf8) + line }
        try server.start()
        defer { server.stop() }
        let reply = try LineSocket.request(Data("hello".utf8), path: path)
        #expect(String(decoding: reply, as: UTF8.self) == "echo:hello")
    }

    @Test func refusesToTakeASocketAnotherEngineAnswersOn() throws {
        let path = temporarySocket()
        let first = LineSocket.Server(path: path) { _, _ in Data("first".utf8) }
        try first.start()
        defer { first.stop() }
        let second = LineSocket.Server(path: path) { _, _ in Data("second".utf8) }
        #expect(throws: LineSocket.ServerError.self) { try second.start() }
        #expect(String(decoding: try LineSocket.request(Data("x".utf8), path: path), as: UTF8.self) == "first")
    }

    @Test func replacesAStaleSocketFile() throws {
        let path = temporarySocket()
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = LineSocket.Server(path: path) { _, _ in Data("ok".utf8) }
        try server.start()
        defer { server.stop() }
        #expect(String(decoding: try LineSocket.request(Data("x".utf8), path: path), as: UTF8.self) == "ok")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func dropsAClientThatSendsTooMuchWithoutANewline() throws {
        let path = temporarySocket()
        let server = LineSocket.Server(path: path) { _, _ in Data("ok".utf8) }
        try server.start()
        defer { server.stop() }
        let descriptor = try LineSocket.connect(path)
        defer { close(descriptor) }
        let chunk = Data(repeating: 0x41, count: 16 * 1024)
        var dropped = false
        for _ in 0..<64 {
            let written = chunk.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written <= 0 { dropped = true; break }
        }
        // The server closed the connection once the line passed 64 KiB.
        var byte: UInt8 = 0
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let read = Darwin.read(descriptor, &byte, 1)
        #expect(dropped || read == 0)
    }

    @Test func limitsConcurrentConnections() throws {
        let path = temporarySocket()
        let server = LineSocket.Server(path: path) { _, _ in Data("ok".utf8) }
        try server.start()
        defer { server.stop() }
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        for _ in 0..<(LineSocket.maxConnections + 4) { descriptors.append(try LineSocket.connect(path)) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(server.activeConnections <= LineSocket.maxConnections)
    }

    @Test func eachStateDirectoryHasItsOwnSocket() {
        let environment = ["TMPDIR": "/tmp/"]
        let owner = LineSocket.path(stateDirectory: nil, environment: environment)
        let test = LineSocket.path(stateDirectory: URL(fileURLWithPath: "/tmp/tessera-test"), environment: environment)
        #expect(owner != test)
        #expect(test == "/tmp/tessera-test/tessera.sock")
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120))
        #expect(LineSocket.path(stateDirectory: long, environment: environment).utf8.count < 104)
        #expect(LineSocket.path(stateDirectory: nil, environment: ["TESSERA_SOCKET": "/tmp/explicit.sock"]) == "/tmp/explicit.sock")
    }
}

extension LineSocketTests {
    @Test func aClientThatHangsUpEarlyDoesNotKillTheServer() throws {
        let path = temporarySocket()
        let server = LineSocket.Server(path: path) { _, _ in
            Thread.sleep(forTimeInterval: 0.05)
            return Data(repeating: 0x42, count: 256 * 1024)
        }
        try server.start()
        defer { server.stop() }
        for _ in 0..<5 {
            let descriptor = try LineSocket.connect(path)
            _ = "x\n".withCString { write(descriptor, $0, 2) }
            close(descriptor)
        }
        Thread.sleep(forTimeInterval: 0.3)
        // Still alive and serving.
        let reply = try LineSocket.request(Data("y".utf8), path: path)
        #expect(reply.count == 256 * 1024)
    }
}
