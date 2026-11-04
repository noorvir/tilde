@testable import TildeCore
import Foundation
import TildeSkill
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

        let started = try await call("start_annotation", ["message": "Ignored by Tilde", "wait_seconds": 0], session: sessionID)
        let id = try #require(store.active?.id)
        #expect(text(of: started).contains("still annotating"))
        #expect(store.active?.client == "Codex")

        store.finish(id, with: .sent(try sampleFeedback(), folder: nil))

        let result = try await call("wait_for_annotation", ["session_id": id, "wait_seconds": 30], session: sessionID)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 5)
        #expect(text(of: result).contains("> the badge is misaligned"))
        #expect(text(of: result).contains("Selector: `td > a`"))
        #expect(text(of: result).contains("![annotation 1 in context](annotation-1-context.png)"))
        #expect(content[2]["type"] as? String == "image")
        #expect(content[2]["mimeType"] as? String == "image/png")
        // Each image follows its caption, and the close-up comes before the context image.
        #expect(content[1]["text"] as? String == "Annotation 1 close-up (primary)")
        #expect(content[2]["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        #expect((content[3]["text"] as? String)?.hasPrefix("Annotation 1 context (secondary") == true)
        #expect(content[4]["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47, 0x0D]).base64EncodedString())
    }

    @Test func contextNoneTurnsOffContextScreenshots() async throws {
        _ = try await call("start_annotation", ["wait_seconds": 0, "context": "none"])
        #expect(store.active?.capturesContext == false)

        let invalid = try await call("start_annotation", ["wait_seconds": 0, "context": "screen"])
        #expect(invalid["isError"] as? Bool == true)
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

    @Test func instructionsAreTheSkillAndThereAreNoPrompts() async throws {
        let initialized = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "codex-mcp-client", "version": "1"]])
        #expect(initialized["instructions"] as? String == tildeServerInstructions)
        let capabilities = try #require(initialized["capabilities"] as? [String: Any])
        #expect(capabilities.keys.sorted() == ["resources", "tools"])

        let response = await post(["jsonrpc": "2.0", "id": 3, "method": "prompts/list", "params": [:]], session: nil)
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect((body["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func sentBatchesAreResources() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let server = MCPServer(store: store, inbox: inbox)

        let empty = try await request("resources/list", [:], on: server)
        #expect((empty["resources"] as? [[String: Any]])?.isEmpty == true)

        let folder = try saveToInbox(try sampleFeedback(), sessionID: "abc", root: inbox)
        let list = try await request("resources/list", [:], on: server)
        let resources = try #require(list["resources"] as? [[String: Any]])
        #expect(resources.map { $0["uri"] as? String } == ["tilde://feedback/latest", "tilde://feedback/\(folder.lastPathComponent)"])
        #expect((resources[1]["title"] as? String)?.hasSuffix("· the badge is misaligned") == true)

        let read = try await request("resources/read", ["uri": "tilde://feedback/latest"], on: server)
        let contents = try #require(read["contents"] as? [[String: Any]])
        #expect(contents.map { $0["mimeType"] as? String } == ["text/markdown", "image/png", "image/png"])
        #expect((contents[0]["text"] as? String)?.contains("> the badge is misaligned") == true)
        #expect(contents[1]["uri"] as? String == "tilde://feedback/latest/annotation-1.png")
        #expect(contents[1]["blob"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())

        let missing = await post(["jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": ["uri": "tilde://feedback/../x"]], session: nil, on: server)
        let body = try #require(try JSONSerialization.jsonObject(with: missing.body) as? [String: Any])
        #expect(body["error"] != nil)
    }

    @Test func waitingToolCallsStreamProgressThenTheResult() async throws {
        let session = store.start(client: "Codex", url: nil)
        store.updateNoteCount(2, for: session.id)
        let response = await post([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "wait_for_annotation", "arguments": ["session_id": session.id, "wait_seconds": 30], "_meta": ["progressToken": 7]],
        ], session: nil, accept: "application/json, text/event-stream")
        #expect(response.headers["Content-Type"] == "text/event-stream")

        var events = try #require(response.stream).makeAsyncIterator()
        let first = try #require(await events.next())
        #expect(String(decoding: first, as: UTF8.self).contains("2 notes so far"))

        store.finish(session.id, with: .cancelled)
        var last = Data()
        while let event = await events.next() {
            last = event
        }
        #expect(String(decoding: last, as: UTF8.self).contains("cancelled the annotation session"))
    }

    // MARK: - Helpers

    private func request(_ method: String, _ params: [String: Any], on server: MCPServer? = nil) async throws -> [String: Any] {
        let response = await post(["jsonrpc": "2.0", "id": 3, "method": method, "params": params], session: nil, on: server)
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try #require(body["result"] as? [String: Any])
    }

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

    private func post(_ message: [String: Any], session: String?, accept: String = "application/json", on server: MCPServer? = nil) async -> HTTPResponse {
        var headers = ["host": "127.0.0.1:7311", "content-type": "application/json", "accept": accept]
        if let session {
            headers["mcp-session-id"] = session
        }
        let body = try! JSONSerialization.data(withJSONObject: message)
        return await (server ?? self.server).handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body))
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
            image: Data([0x89, 0x50, 0x4E, 0x47]),
            contextImage: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        )
        return Feedback(annotations: [annotation])
    }
}

struct HTTPServerTests {
    @Test func servesARequestOverLoopback() async throws {
        let server = try HTTPServer(port: 0) { request in
            HTTPResponse(status: 200, headers: ["X-Path": request.path], body: request.body)
        }
        let port = try await start(server)
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

    @Test func streamsChunksUntilTheStreamEnds() async throws {
        let server = try HTTPServer(port: 0) { _ in
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            Task {
                for chunk in ["one ", "two ", "three"] {
                    continuation.yield(Data(chunk.utf8))
                    try? await Task.sleep(for: .milliseconds(20))
                }
                continuation.finish()
            }
            return HTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream"], stream: stream)
        }
        let port = try await start(server)
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        #expect(String(data: data, encoding: .utf8) == "one two three")
    }

    private func start(_ server: HTTPServer) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
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

@MainActor @Suite struct ClientNameAfterRestartTests {
    private func request(_ message: [String: Any], session: String? = nil, userAgent: String? = nil) throws -> HTTPRequest {
        var headers = ["host": "127.0.0.1:1", "accept": "application/json"]
        headers["mcp-session-id"] = session
        headers["user-agent"] = userAgent
        return HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: try JSONSerialization.data(withJSONObject: message))
    }

    private func start(on server: MCPServer, session: String?, userAgent: String? = nil) async throws {
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "start_annotation", "arguments": ["wait_seconds": 0]]]
        _ = await server.handle(try request(call, session: session, userAgent: userAgent))
    }

    @Test func aSessionKeepsItsClientNameWhenTildeRestarts() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-clients-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = MCPServer(store: SessionStore(), clientsFile: file)
        let hello: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "claude-code"]]]
        let session = try #require(await first.handle(try request(hello)).headers["Mcp-Session-Id"])

        let store = SessionStore()
        try await start(on: MCPServer(store: store, clientsFile: file), session: session)
        #expect(store.active?.client == "Claude Code")
    }

    @Test func anUnknownSessionIsNamedByItsUserAgent() async throws {
        let store = SessionStore()
        try await start(on: MCPServer(store: store), session: "gone", userAgent: "claude-code/2.1 (cli)")
        #expect(store.active?.client == "Claude Code")
    }
}

@Suite struct ClientNameTests {
    @Test func clientNamesMapToTheirHarness() {
        let cases = [
            ("claude-code", "Claude Code"), ("Claude Code", "Claude Code"), ("claude-ai", "Claude"),
            ("codex-mcp-client", "Codex"), ("rmcp", "Codex"), ("Cursor", "Cursor"),
            ("Visual Studio Code", "VS Code"), ("gemini-cli-mcp-client", "Gemini CLI"),
            ("windsurf-client", "Windsurf"), ("devin", "Windsurf"), ("SomethingNew", "SomethingNew"),
        ]
        for (name, display) in cases {
            #expect(MCPServer.displayName(forClient: name) == display, "\(name)")
        }
    }
}
