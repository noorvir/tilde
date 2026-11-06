@testable import TildeCore
import Foundation
import Testing

/// A node's socket: MCP's stdio framing, and the node it belongs to as the caller.
@MainActor
struct NodeSocketTests {
    let store = SessionStore()

    /// The socket's path must fit a socket address, so the folder is short.
    private func folder() -> URL {
        URL(fileURLWithPath: "/tmp/tilde-test-\(UUID().uuidString.prefix(8))")
    }

    @Test func aConnectionIsOneSessionOfThatNodeInLines() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = try NodeSocket(node: "box", mcp: MCPServer(store: store, localToken: "test"), folder: folder)
        socket.start()
        defer { socket.stop() }
        let client = try await LineClient(path: socket.path)

        try client.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"codex-mcp-client"}}}"#)
        #expect(try await client.next()["result"] != nil)
        try client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try client.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_annotation","arguments":{"wait_seconds":0}}}"#)
        let started = try await client.next()
        #expect(started["id"] as? Int == 2)
        let session = try #require(store.active)
        #expect(session.node == "box")
        #expect(session.client == "Codex")

        // A call that waits sends progress lines, then its result; a ping is answered meanwhile.
        try client.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait_for_annotation","arguments":{"session_id":"\#(session.id)","wait_seconds":30},"_meta":{"progressToken":9}}}"#)
        #expect(try await client.next()["method"] as? String == "notifications/progress")
        try client.send(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        #expect(try await client.reply()["id"] as? Int == 4)
        store.finish(session.id, with: .cancelled)
        let result = try await client.reply()
        #expect(result["id"] as? Int == 3)
        #expect("\(result)".contains("cancelled"))

        let mode = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0 }
        #expect(mode(folder.path) == 0o700)
        #expect(mode(socket.path) == 0o600)
    }

    /// After a drop, tproxy connects again with its id: the agent keeps its MCP session with no
    /// new `initialize`, and another tproxy does not get it.
    @Test func aTproxyGetsItsSessionBackWhenItConnectsAgain() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = try NodeSocket(node: "box", mcp: MCPServer(store: store, localToken: "test"), folder: folder)
        socket.start()
        defer { socket.stop() }
        let hello = #"{"jsonrpc":"2.0","method":"tproxy/connect","params":{"id":"a1"}}"#
        let start = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_annotation","arguments":{"wait_seconds":0}}}"#

        let first = try await LineClient(path: socket.path)
        try first.send(hello)
        try first.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-mcp-client"}}}"#)
        _ = try await first.reply()
        first.close()

        let again = try await LineClient(path: socket.path)
        try again.send(hello)
        try again.send(start)
        _ = try await again.reply()
        #expect(store.active?.client == "Codex")
        #expect(store.active?.node == "box")
        store.finish(try #require(store.active?.id), with: .cancelled)

        let other = try await LineClient(path: socket.path)
        try other.send(#"{"jsonrpc":"2.0","method":"tproxy/connect","params":{"id":"b2"}}"#)
        try other.send(start)
        _ = try await other.reply()
        #expect(store.active?.client == "Agent")
    }

    /// A node has at most 8 calls at once, across its connections; one more gets an error at
    /// once. A connection that ends ends its waits, so they no longer count.
    @Test func aNodeHasEightCallsAtOnceAndADropEndsItsWaits() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = try NodeSocket(node: "box", mcp: MCPServer(store: store, localToken: "test"), folder: folder)
        socket.start()
        defer { socket.stop() }
        let first = try await LineClient(path: socket.path)
        try first.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_annotation","arguments":{"wait_seconds":0}}}"#)
        _ = try await first.reply()
        let session = try #require(store.active)

        for id in 10..<18 {
            try first.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"wait_for_annotation","arguments":{"session_id":"\#(session.id)","wait_seconds":600}}}"#)
        }
        let second = try await LineClient(path: socket.path)
        try second.send(#"{"jsonrpc":"2.0","id":18,"method":"ping"}"#)
        let refused = try await second.reply()
        #expect(refused["id"] as? Int == 18)
        #expect("\(refused)".contains("Too many calls"))

        first.close()
        try await Task.sleep(for: .milliseconds(300))
        try second.send(#"{"jsonrpc":"2.0","id":19,"method":"ping"}"#)
        let answered = try await second.reply()
        #expect(answered["id"] as? Int == 19)
        #expect(answered["result"] != nil)
        store.finish(session.id, with: .cancelled)
    }

    @Test func eachNodeHasItsOwnSocket() {
        #expect(NodeSocket.path(for: "box") != NodeSocket.path(for: "other"))
        #expect(NodeSocket.path(for: "box") == NodeSocket.path(for: "box"))
        #expect(NodeSocket.path(for: "a-very-long-host-name.example.internal.corp").utf8.count < 104)
    }

    /// A node linked by its socket is not let in through the port, even with its token.
    @Test func aSocketNodesTokenIsRefusedOnThePort() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nodes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let nodes = NodeStore(file: file)
        try nodes.save([Node(host: "box", token: "boxtoken", socket: "/home/me/.tilde/tilde.sock"), Node(host: "bsd", token: "bsdtoken")])
        let server = MCPServer(store: store, localToken: "test")

        func status(_ token: String) async -> Int {
            let headers = ["host": "127.0.0.1:7319", "content-type": "application/json", "authorization": "Bearer \(token)"]
            let ping = HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            return await server.handleFromNode(ping, store: nodes).status
        }
        #expect(await status("boxtoken") == 401)
        #expect(await status("bsdtoken") == 200)
    }
}

/// A client of the socket that sends lines and reads them, off the main actor.
private final class LineClient: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()

    init(path: String) async throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.utf8.prefix(bytes.count - 1))
        }
        // The listener may still be starting.
        for _ in 0..<50 {
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if connected == 0 {
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Darwin.close(fd)
        throw POSIXError(.ECONNREFUSED)
    }

    func close() {
        try? handle.close()
    }

    func send(_ line: String) throws {
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func next() async throws -> [String: Any] {
        let line = try await Task.detached { [self] in try readLine() }.value
        return try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    /// The next answer, past progress notifications.
    func reply() async throws -> [String: Any] {
        while true {
            let message = try await next()
            if message["id"] != nil {
                return message
            }
        }
    }

    private func readLine() throws -> Data {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<end]
                buffer = Data(buffer[buffer.index(after: end)...])
                return Data(line)
            }
            let data = handle.availableData
            guard !data.isEmpty else {
                throw POSIXError(.ECONNRESET)
            }
            buffer.append(data)
        }
    }
}
