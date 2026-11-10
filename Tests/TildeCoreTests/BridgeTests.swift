@testable import TildeCore
@testable import tilde_mcp
import Foundation
import os
import Testing

/// The `tilde-mcp` stdio bridge: lines from an agent in, lines for the agent out.
@MainActor
struct BridgeTests {
    /// The lines the bridge wrote for the agent.
    private let written = OSAllocatedUnfairLock(initialState: [Data]())

    private func bridge(port: UInt16, token: String = "test") -> Bridge {
        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        return Bridge(endpoint: endpoint, authorization: "Bearer \(token)") { [written] line in
            written.withLock { $0.append(line) }
        } launch: {
        }
    }

    private func messages() throws -> [[String: Any]] {
        try written.withLock { $0 }.map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }

    /// A call that waits with a progress token gets its progress and its result as lines of
    /// JSON-RPC, as on a node's socket, never the text of an event stream.
    @Test func progressAndResultsAreJSONRPCLines() async throws {
        let store = SessionStore()
        let mcp = MCPServer(store: store, localToken: "test")
        let server = try HTTPServer(port: 0) { request in await mcp.handleLocal(request) }
        let port = try await server.started()
        defer { server.stop() }
        let bridge = bridge(port: port)

        await bridge.forward(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-mcp-client"}}}"#.utf8))
        await bridge.forward(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        await bridge.forward(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_annotation","arguments":{"wait_seconds":0}}}"#.utf8))
        #expect(try messages().map { $0["id"] as? Int } == [1, 2])
        let session = try #require(store.active)
        #expect(session.client == "Codex")

        let wait = Task {
            await bridge.forward(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait_for_annotation","arguments":{"session_id":"\#(session.id)","wait_seconds":30},"_meta":{"progressToken":9}}}"#.utf8))
        }
        while written.withLock({ $0.count }) < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.finish(session.id, with: .cancelled)
        await wait.value

        let answers = try messages().dropFirst(2)
        #expect(answers.first?["method"] as? String == "notifications/progress")
        #expect(answers.last?["id"] as? Int == 3)
        #expect("\(answers.last ?? [:])".contains("cancelled the annotation session"))
    }

    /// A request that Tilde refuses, or that something else answers, gets a JSON-RPC error
    /// with its id; a notification gets nothing.
    @Test func anAnswerThatIsNotJSONRPCBecomesAnError() async throws {
        let answers = [
            HTTPResponse(status: 401),
            HTTPResponse(status: 403),
            HTTPResponse(status: 500, body: Data("<html>".utf8)),
            HTTPResponse(status: 200, body: Data("<html>".utf8)),
            HTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(#"event: message\#ndata: {"jsonrpc":"2.0","id":7,"res"#.utf8)),
        ]
        for answer in answers {
            let server = try HTTPServer(port: 0) { _ in answer }
            let port = try await server.started()
            defer { server.stop() }
            let bridge = bridge(port: port)
            written.withLock { $0 = [] }

            await bridge.forward(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            #expect(try messages().isEmpty)
            await bridge.forward(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8))
            let reply = try #require(try messages().first)
            #expect(try messages().count == 1)
            #expect(reply["id"] as? Int == 7, "\(answer.status)")
            #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32000, "\(answer.status)")
        }
    }

    @Test func aLineThatIsNotAMessageGetsAParseError() async throws {
        await bridge(port: 1).forward(Data("not json".utf8))
        let reply = try #require(try messages().first)
        #expect(reply["id"] is NSNull)
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32700)
    }
}
