import CryptoKit
import Foundation
import Network

/// A node's door to Tilde: a Unix socket on this Mac in a folder only this user can open, which
/// the node's ssh link forwards the node's own socket to. Whoever connects is that node, as only
/// its link reaches the socket. A connection speaks MCP's stdio framing, the one `tproxy`
/// pipes from the node's agents: one JSON-RPC message per line each way.
public final class NodeSocket: @unchecked Sendable {
    public let path: String
    private let node: String
    private let mcp: MCPServer
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tilde.node-socket")
    private let maxLine = 10 * 1024 * 1024

    /// The socket for a node: named for the host, as the host is in no other place on the Mac.
    public static func path(for host: String, folder: URL = defaultFolder) -> String {
        let name = SHA256.hash(data: Data(host.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(name).sock").path
    }

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tilde/links")
    }

    public init(node: String, mcp: MCPServer, folder: URL = defaultFolder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        path = Self.path(for: node, folder: folder)
        unlink(path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: parameters)
        self.node = node
        self.mcp = mcp
    }

    public func start() {
        listener.stateUpdateHandler = { [path] state in
            if case .ready = state {
                chmod(path, 0o600)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
        unlink(path)
    }

    /// One agent's MCP session, from `initialize` on; read and written on the main actor.
    @MainActor private final class Session {
        var id: String?
        /// The id of the agent's tproxy, which it sends first on each connection.
        var proxy: String?
    }

    /// The MCP session of each tproxy, newest last, so that an agent whose link dropped gets
    /// its session back when tproxy connects again, without a new `initialize`.
    @MainActor private var proxySessions: [(proxy: String, session: String)] = []

    @MainActor private func remember(_ session: Session) {
        guard let proxy = session.proxy, let id = session.id else {
            return
        }
        proxySessions.removeAll { $0.proxy == proxy }
        proxySessions.append((proxy, id))
        proxySessions.removeFirst(max(0, proxySessions.count - 100))
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { @MainActor in
            receive(on: connection, buffer: Data(), session: Session())
        }
    }

    /// Each line is handled at once, so a ping still gets its answer during a long wait.
    @MainActor private func receive(on connection: NWConnection, buffer: Data, session: Session) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    return
                }

                var buffer = buffer + (data ?? Data())
                while let end = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<end])
                    buffer = Data(buffer[buffer.index(after: end)...])
                    guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else {
                        continue
                    }
                    // tproxy's id, before any other line: its session, if it had one.
                    let hello = line.range(of: Data("tproxy/connect".utf8)) == nil ? nil : (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    if hello?["method"] as? String == "tproxy/connect", let proxy = (hello?["params"] as? [String: Any])?["id"] as? String {
                        session.proxy = proxy
                        session.id = self.proxySessions.last { $0.proxy == proxy }?.session
                        continue
                    }
                    Task { @MainActor in
                        let id = await self.mcp.handleLine(line, session: session.id, node: self.node) { reply in
                            connection.send(content: reply + Data("\n".utf8), completion: .idempotent)
                        }
                        session.id = id ?? session.id
                        self.remember(session)
                    }
                }

                if isComplete || error != nil || buffer.count > self.maxLine {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, session: session)
                }
            }
        }
    }
}
