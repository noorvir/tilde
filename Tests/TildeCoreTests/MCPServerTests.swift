@testable import TildeCore
import Foundation
import Testing

@MainActor
struct MCPServerTests {
    let store = SessionStore()
    let server: MCPServer

    init() {
        server = MCPServer(store: store)
    }

    @Test func sendBetweenWaitsIsReturnedByTheNextWait() async throws {
        let sessionID = try await initialize(client: "codex-mcp-client")

        let started = try await call("start_annotation", ["message": "Check the table", "wait_seconds": 0], session: sessionID)
        let id = try #require(store.active?.id)
        #expect(text(of: started).contains("still annotating"))
        #expect(store.active?.client == "Codex")
        #expect(store.active?.message == "Check the table")

        store.finish(id, with: .sent(try sampleFeedback(), folder: nil))

        let result = try await call("wait_for_annotation", ["session_id": id, "wait_seconds": 30], session: sessionID)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(text(of: result).contains("> the badge is misaligned"))
        #expect(text(of: result).contains("Selector: `td > a`"))
        #expect(content[1]["type"] as? String == "image")
        #expect(content[1]["mimeType"] as? String == "image/png")
    }

    @Test func openWaitReturnsAsSoonAsTheUserSends() async throws {
        _ = try await call("start_annotation", ["wait_seconds": 0])
        let id = try #require(store.active?.id)

        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            store.finish(id, with: .cancelled)
        }

        let started = Date()
        let result = try await call("wait_for_annotation", ["session_id": id, "wait_seconds": 30])
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(text(of: result).contains("cancelled"))
    }

    @Test func secondSessionQueuesUntilTheFirstFinishes() async throws {
        _ = try await call("start_annotation", ["wait_seconds": 0])
        let first = try #require(store.active?.id)

        let queued = try await call("start_annotation", ["wait_seconds": 0])
        #expect(text(of: queued).contains("Queued"))
        #expect(store.active?.id == first)

        store.finish(first, with: .cancelled)
        #expect(store.active != nil)
        #expect(store.active?.id != first)
    }

    @Test func unknownSessionIsAToolError() async throws {
        let result = try await call("wait_for_annotation", ["session_id": "nope", "wait_seconds": 0])
        #expect(result["isError"] as? Bool == true)
    }

    @Test func rejectsRequestsForOtherHosts() async throws {
        let request = HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "evil.example:7311"], body: Data("{}".utf8))
        let response = await server.handle(request)
        #expect(response.status == 403)
    }

    // MARK: - Helpers

    private func initialize(client: String) async throws -> String {
        let response = await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": client, "version": "1"]],
        ], session: nil)
        return try #require(response.headers["Mcp-Session-Id"])
    }

    private func call(_ tool: String, _ arguments: [String: Any], session: String? = nil) async throws -> [String: Any] {
        let response = await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ], session: session)
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try #require(body["result"] as? [String: Any])
    }

    private func post(_ message: [String: Any], session: String?) async -> HTTPResponse {
        var headers = ["host": "127.0.0.1:7311", "content-type": "application/json"]
        if let session {
            headers["mcp-session-id"] = session
        }
        let body = try! JSONSerialization.data(withJSONObject: message)
        return await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body))
    }

    private func text(of result: [String: Any]) -> String {
        let content = result["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func sampleFeedback() throws -> Feedback {
        let json = """
            {"url":"http://localhost:3000/","title":"Docs","tag":"a","selector":"td > a","text":"Alex",
             "html":"<a>Alex</a>","components":["Table","OwnerCell"],"source":null,"styles":"color: red"}
            """
        let element = try JSONDecoder().decode(WebElement.self, from: Data(json.utf8))
        let annotation = Annotation(
            comment: "the badge is misaligned",
            target: .element(.web(element)),
            frame: CGRect(x: 10, y: 20, width: 40, height: 20),
            image: Data([0x89, 0x50, 0x4E, 0x47])
        )
        return Feedback(annotations: [annotation])
    }
}

struct HTTPServerTests {
    @Test func servesARequestOverLoopback() async throws {
        let server = try HTTPServer(port: 0) { request in
            HTTPResponse(status: 200, headers: ["X-Path": request.path], body: request.body)
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = Locked(false)
            server.start { status in
                guard resumed.swap(true) == false else {
                    return
                }
                switch status {
                case .ready(let port):
                    continuation.resume(returning: port)
                case .failed(let message):
                    continuation.resume(throwing: URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: message]))
                case .starting:
                    resumed.swap(false)
                }
            }
        }
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp?x=1")!)
        request.httpMethod = "POST"
        request.httpBody = Data("hello".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "X-Path") == "/mcp")
        #expect(String(data: data, encoding: .utf8) == "hello")
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func swap(_ newValue: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}
