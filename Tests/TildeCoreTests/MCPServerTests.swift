@testable import TildeCore
import Foundation
import Network
import TildeSkill
import Testing

@MainActor
struct MCPServerTests {
    let store = SessionStore()
    let server: MCPServer

    init() {
        server = MCPServer(store: store, localToken: "test")
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

    /// The store keeps a sent report without the pictures that are in its folder, and an
    /// agent that asks after the send still gets them, from the folder.
    @Test func aReportSavedInAFolderKeepsItsPicturesThereOnly() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        _ = try await call("start_annotation", ["wait_seconds": 0])
        let id = try #require(store.active?.id)
        let feedback = try sampleFeedback()
        let folder = try saveToInbox(feedback, sessionID: id, root: inbox)

        store.finish(id, with: .sent(feedback, folder: folder))

        guard case .sent(let kept, _) = store.session(id)?.state else {
            Issue.record("The session is not sent")
            return
        }
        #expect(kept.annotations.map(\.comment) == ["the badge is misaligned"])
        #expect(kept.annotations.allSatisfy { $0.image == nil && $0.contextImage == nil })

        let result = try await call("wait_for_annotation", ["session_id": id, "wait_seconds": 30])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 5)
        #expect(content[2]["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
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
        let response = await server.handle(request, node: nil)
        #expect(response.status == 403)
    }

    @Test func instructionsAreTheSkillAndThereAreNoPrompts() async throws {
        let initialized = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "codex-mcp-client", "version": "1"]])
        #expect(initialized["instructions"] as? String == tildeSkillBody)
        let capabilities = try #require(initialized["capabilities"] as? [String: Any])
        #expect(capabilities.keys.sorted() == ["resources", "tools"])

        let response = await post(["jsonrpc": "2.0", "id": 3, "method": "prompts/list", "params": [:]], session: nil)
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect((body["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func sentBatchesAreResources() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let server = MCPServer(store: store, localToken: "test", inbox: inbox)

        let empty = try await request("resources/list", [:], on: server)
        #expect((empty["resources"] as? [[String: Any]])?.isEmpty == true)

        let folder = try saveToInbox(try sampleFeedback(), sessionID: "a1b2c3d4", root: inbox)
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

    @Test func aSentReportIsReadByItsID() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let server = MCPServer(store: store, localToken: "test", inbox: inbox)
        let folder = try saveToInbox(try sampleFeedback(), sessionID: "a1b2c3d4", root: inbox)

        let read = try await request("tools/call", ["name": "get_report", "arguments": ["id": folder.lastPathComponent]], on: server)
        let content = try #require(read["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "text", "image", "text", "image"])
        #expect((content[0]["text"] as? String)?.contains("> the badge is misaligned") == true)
        #expect(content[1]["text"] as? String == "annotation-1.png")

        let missing = try await request("tools/call", ["name": "get_report", "arguments": ["id": "../x"]], on: server)
        #expect(missing["isError"] as? Bool == true)
    }

    /// A note with no picture, such as one whose window closed before its capture, does not
    /// hide the pictures of the notes after it.
    @Test func aSentReportHasThePicturesAfterANoteWithNone() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let server = MCPServer(store: store, localToken: "test", inbox: inbox)
        let withPicture = try #require(try sampleFeedback().annotations.first)
        let withNone = Annotation(comment: "no picture", target: withPicture.target, frame: withPicture.frame, image: nil, contextImage: nil)
        let folder = try saveToInbox(Feedback(annotations: [withNone, withPicture]), sessionID: "a1b2c3d4", root: inbox)

        let read = try await request("tools/call", ["name": "get_report", "arguments": ["id": folder.lastPathComponent]], on: server)
        let content = try #require(read["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["text"] as? String }.dropFirst() == ["annotation-2.png", "annotation-2-context.png"])
        #expect(content.filter { $0["type"] as? String == "image" }.count == 2)
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

    /// A client that takes no event stream gets the result alone, as JSON.
    @Test func withoutAnEventStreamAWaitingCallGivesOnlyTheResult() async throws {
        let session = store.start(client: "Codex", url: nil)
        store.finish(session.id, with: .cancelled)
        let response = await post([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "wait_for_annotation", "arguments": ["session_id": session.id, "wait_seconds": 30], "_meta": ["progressToken": 7]],
        ], session: nil)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(response.stream == nil)

        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(body["id"] as? Int == 4)
        #expect(text(of: try #require(body["result"] as? [String: Any])).contains("cancelled the annotation session"))
    }

    /// An agent that goes away during a wait ends the wait; it does not stay for its 600 s.
    @Test func aClosedConnectionEndsItsWait() async throws {
        let session = store.start(client: "Codex", url: nil)
        let (returned, continuation) = AsyncStream<Void>.makeStream()
        let http = try HTTPServer(port: 0) { [server] request in
            let response = await server.handleLocal(request)
            continuation.yield()
            return response
        }
        let port = try await http.started()
        defer { http.stop() }

        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait_for_annotation","arguments":{"session_id":"\#(session.id)","wait_seconds":600}}}"#
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer test\r\nContent-Type: application/json\r\nContent-Length: \(call.utf8.count)\r\n\r\n"
        let connection = NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data((head + call).utf8), completion: .idempotent)
        try await Task.sleep(for: .milliseconds(200))
        connection.cancel()

        Task {
            try await Task.sleep(for: .seconds(5))
            continuation.finish()
        }
        var answers = returned.makeAsyncIterator()
        #expect(await answers.next() != nil)
        store.finish(session.id, with: .cancelled)
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
        return await (server ?? self.server).handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body), node: nil)
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
    // MARK: - Who may call

    /// Agents on this Mac need the local token; other processes on the Mac do not have it.
    @Test func theLocalListenerAsksForTheToken() async throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        func status(_ authorization: String?) async -> Int {
            var headers = ["host": "127.0.0.1:7311", "content-type": "application/json"]
            headers["authorization"] = authorization
            return await server.handleLocal(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body)).status
        }
        #expect(await status(nil) == 401)
        #expect(await status("Bearer wrong") == 401)
        #expect(await status("Bearer test") == 200)
    }

    /// A web page cannot call Tilde: a JSON body needs a preflight, and an Origin that is not
    /// local, "null" from a sandboxed frame or a file included, is refused.
    @Test func webPagesCannotCall() async throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        func status(_ headers: [String: String]) async -> Int {
            await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:7311"].merging(headers) { $1 }, body: body), node: nil).status
        }
        #expect(await status(["content-type": "text/plain"]) == 415)
        #expect(await status(["content-type": "application/json", "origin": "null"]) == 403)
        #expect(await status(["content-type": "application/json", "origin": "https://evil.example"]) == 403)
        #expect(await status(["content-type": "application/json", "origin": "http://localhost:3000"]) == 200)
    }

    @Test func onlyWebPagesOpenInTheBrowser() async throws {
        let sessionID = try await initialize(client: "codex-mcp-client")
        let result = try await call("start_annotation", ["url": "file:///etc/passwd", "wait_seconds": 0], session: sessionID)
        #expect(result["isError"] as? Bool == true)
        #expect(store.active == nil)
    }

    /// A machine lists and gets "latest" of only the reports for its own agents; any report
    /// is read by its exact id, as a pasted report names it, and nothing outside the inbox.
    @Test func aMachineListsOnlyItsOwnReports() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let server = MCPServer(store: store, localToken: "test", inbox: inbox)
        let local = try saveToInbox(try sampleFeedback(), sessionID: "a1b2c3d4", root: inbox)
        let own = try saveToInbox(try sampleFeedback(), sessionID: "b1b2c3d4", node: "box", root: inbox)

        func list(_ node: String?) async throws -> [String] {
            let response = await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:7311", "content-type": "application/json"], body: Data(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#.utf8)), node: node)
            let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            let resources = (body["result"] as? [String: Any])?["resources"] as? [[String: Any]] ?? []
            return resources.compactMap { $0["uri"] as? String }
        }
        #expect(try await list("box") == ["tilde://feedback/latest", "tilde://feedback/\(own.lastPathComponent)"])
        #expect(try await list(nil).count == 3)

        func read(_ id: String, as node: String?) async throws -> Bool {
            let call: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_report", "arguments": ["id": id]]]
            let body = try JSONSerialization.data(withJSONObject: call)
            let response = await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:7311", "content-type": "application/json"], body: body), node: node)
            let reply = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            return ((reply["result"] as? [String: Any])?["isError"] as? Bool) != true
        }
        #expect(try await read(local.lastPathComponent, as: "box"))
        #expect(try await read("..", as: nil) == false)
        #expect(try await read("../inbox", as: nil) == false)
    }

    @Test func aMachineWaitsOnlyForItsOwnSessions() async throws {
        let mine = store.start(client: "Codex", node: "box", url: nil)
        #expect(await store.wait(for: mine.id, node: "box", seconds: 0) != nil)
        #expect(await store.wait(for: mine.id, node: "other", seconds: 0) == nil)
        #expect(await store.wait(for: mine.id, node: nil, seconds: 0) == nil)
    }

    /// A machine never gets this Mac's scope by sending a local agent's session id.
    @Test func aSessionCountsOnlyForTheMachineThatMadeIt() async throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let server = MCPServer(store: store, localToken: "test", inbox: inbox)
        _ = try saveToInbox(try sampleFeedback(), sessionID: "a1b2c3d4", root: inbox)
        let hello = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex"]]])
        let local = await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:7311", "content-type": "application/json"], body: hello), node: nil)
        let session = try #require(local.headers["Mcp-Session-Id"])

        let call = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_report", "arguments": ["id": "latest"]]])
        let headers = ["host": "127.0.0.1:7319", "content-type": "application/json", "mcp-session-id": session]
        let response = await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: call), node: "box")
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect((body["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func aRequestTargetIsAPath() {
        func status(_ target: String) -> Int? {
            switch HTTPServer.parse(Data("GET \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), maxBodySize: 1024) {
            case .invalid(let status): return status
            case .request: return 200
            case .incomplete: return nil
            }
        }
        #expect(status("?") == 400)
        #expect(status("mcp") == 400)
        #expect(status("/mcp?x=1") == 200)
    }

    /// Reports are kept as History keeps sessions: 30 days, and always the last 100.
    @Test func oldReportsGo() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        for day in 1...102 {
            let folder = inbox.appendingPathComponent(String(format: "2026-01-01_00-00-%02d_a1b2c%03d", day % 60, day))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }
        pruneInbox(root: inbox)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).count == 100)
    }

    /// Reports saved by an older Tilde, readable by others, become private.
    @Test func olderReportsBecomePrivate() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let folder = inbox.appendingPathComponent("2026-01-01_00-00-00_a1b2c3d4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = folder.appendingPathComponent("annotation-1.png")
        FileManager.default.createFile(atPath: file.path, contents: Data([1]), attributes: [.posixPermissions: 0o644])

        makePrivate(tree: inbox)

        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    /// Links in the inbox are left alone, and items that are private already keep their
    /// change time.
    @Test func makingReportsPrivateLeavesLinksAndPrivateItems() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: inbox)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let folder = inbox.appendingPathComponent("2026-01-01_00-00-00_a1b2c3d4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("annotation-1.png")
        FileManager.default.createFile(atPath: file.path, contents: Data([1]), attributes: [.posixPermissions: 0o600])
        try FileManager.default.createSymbolicLink(at: inbox.appendingPathComponent("synced"), withDestinationURL: outside)
        let changed = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        var before = stat()
        stat(file.path, &before)

        makePrivate(tree: inbox)

        var after = stat()
        stat(file.path, &after)
        #expect(after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec && after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == changed)
        #expect(try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int == 0o755)
    }

    /// The node's prune runs in sh, whatever the login shell: zsh here, as fish would.
    @Test func theNodePruneRunsInSh() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let inbox = home.appendingPathComponent(".tilde/inbox")
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        for number in 1...102 {
            let folder = inbox.appendingPathComponent(String(format: "2026-01-01_00-%02d-%02d_a1b2c%03d", number / 60, number % 60, number))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-c", pruneInboxCommand]
        shell.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try shell.run()
        shell.waitUntilExit()

        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).count == 100)
    }

    @Test func aRequestLengthIsDigitsOnly() {
        func status(_ length: String) -> Int? {
            let request = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(length)\r\n\r\n{}".utf8)
            switch HTTPServer.parse(request, maxBodySize: 1024) {
            case .invalid(let status): return status
            case .request: return 200
            case .incomplete: return nil
            }
        }
        #expect(status("-1") == 400)
        #expect(status("+2") == 400)
        #expect(status("2") == 200)
        #expect(status("4096") == 413)
    }

    /// Only the owner can open a report; a report for a machine names it.
    @Test func reportsArePrivate() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let folder = try saveToInbox(try sampleFeedback(), sessionID: "a1b2c3d4", node: "box", root: inbox)

        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        let report = folder.appendingPathComponent("feedback.md").path
        #expect(try FileManager.default.attributesOfItem(atPath: report)[.posixPermissions] as? Int == 0o600)
        #expect(reportNode(folder) == "box")
        #expect(isReportID(folder.lastPathComponent))
        #expect(!isReportID("2026-11-04_00-13-48_abc"))
    }
}

struct HTTPServerTests {
    @Test func servesARequestOverLoopback() async throws {
        let server = try HTTPServer(port: 0) { request in
            HTTPResponse(status: 200, headers: ["X-Path": request.path], body: request.body)
        }
        let port = try await server.started()
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
        let port = try await server.started()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        #expect(String(data: data, encoding: .utf8) == "one two three")
    }

    /// A caller that goes away ends its request: the handler's task is cancelled, and a
    /// stream that answers it ends.
    @Test func aClosedConnectionEndsItsRequest() async throws {
        let (events, continuation) = AsyncStream<String>.makeStream()
        let server = try HTTPServer(port: 0) { request in
            continuation.yield("begun")
            if request.path == "/stream" {
                let (stream, chunks) = AsyncStream<Data>.makeStream()
                chunks.onTermination = { _ in continuation.yield("ended") }
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    continuation.yield("not ended")
                }
                return HTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream"], stream: stream)
            }
            try? await Task.sleep(for: .seconds(5))
            continuation.yield(Task.isCancelled ? "ended" : "not ended")
            return HTTPResponse(status: 200)
        }
        let port = try await server.started()
        defer { server.stop() }

        var next = events.makeAsyncIterator()
        for path in ["/wait", "/stream"] {
            let connection = NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
            connection.start(queue: .global())
            connection.send(content: Data("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), completion: .idempotent)
            #expect(await next.next() == "begun")
            connection.cancel()
            #expect(await next.next() == "ended", "\(path)")
        }
    }

    /// One caller may have 8 requests open on a limited listener, such as long polls; another
    /// caller still gets through.
    @Test func oneCallerCannotTakeEveryConnection() async throws {
        let server = try HTTPServer(port: 0, maxRequestsPerCaller: 8) { request in
            if request.headers["authorization"] == "Bearer busy" {
                try? await Task.sleep(for: .seconds(2))
            }
            return HTTPResponse(status: 200)
        }
        let port = try await server.started()
        defer { server.stop() }

        func status(_ token: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let polls = (0..<8).map { _ in Task { try await status("busy") } }
        try await Task.sleep(for: .milliseconds(300))

        #expect(try await status("busy") == 429)
        #expect(try await status("other") == 200)
        for poll in polls {
            #expect(try await poll.value == 200)
        }
    }
}

extension HTTPServer {
    /// Starts the server and gives its port.
    func started() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = Locked(false)
            start { status in
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
        var headers = ["host": "127.0.0.1:1", "accept": "application/json", "content-type": "application/json"]
        headers["mcp-session-id"] = session
        headers["user-agent"] = userAgent
        return HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: try JSONSerialization.data(withJSONObject: message))
    }

    private func start(on server: MCPServer, session: String?, userAgent: String? = nil) async throws {
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "start_annotation", "arguments": ["wait_seconds": 0]]]
        _ = await server.handle(try request(call, session: session, userAgent: userAgent), node: nil)
    }

    @Test func aSessionKeepsItsClientNameWhenTildeRestarts() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-clients-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = MCPServer(store: SessionStore(), localToken: "test", clientsFile: file)
        let hello: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "claude-code"]]]
        let session = try #require(await first.handle(try request(hello), node: nil).headers["Mcp-Session-Id"])

        let store = SessionStore()
        try await start(on: MCPServer(store: store, localToken: "test", clientsFile: file), session: session)
        #expect(store.active?.client == "Claude Code")
    }

    @Test func anUnknownSessionIsNamedByItsUserAgent() async throws {
        let store = SessionStore()
        try await start(on: MCPServer(store: store, localToken: "test"), session: "gone", userAgent: "claude-code/2.1 (cli)")
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
