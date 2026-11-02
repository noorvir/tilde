import Foundation
import OSLog
import TildeSkill

/// MCP over Streamable HTTP at `/mcp`. Replies are JSON, except tool calls that wait for the
/// user: when the client sends a progress token and accepts event streams, those stream
/// progress notifications ("Tilde is open: 2 notes so far") before the result.
/// Exposes `start_annotation` and `wait_for_annotation` on top of a `SessionStore`.
@MainActor
public final class MCPServer {
    private let store: SessionStore
    private let inbox: URL
    /// Display names of connected harnesses, keyed by `Mcp-Session-Id`.
    private var clients: [String: String] = [:]
    /// Keeps those names, oldest first, as a harness keeps its session when Tilde restarts.
    private let clientsFile: URL?
    private static let keptClients = 200
    private let log = Logger(subsystem: "dev.tilde.app", category: "mcp")

    private let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    private let defaultWaitSeconds = 45.0
    private let maxWaitSeconds = 600.0
    public init(store: SessionStore, inbox: URL = inboxRoot, clientsFile: URL? = nil) {
        self.store = store
        self.inbox = inbox
        self.clientsFile = clientsFile
        if let clientsFile, let data = try? Data(contentsOf: clientsFile), let saved = try? JSONDecoder().decode([SavedClient].self, from: data) {
            savedClients = saved
            clients = Dictionary(saved.map { ($0.id, $0.name) }, uniquingKeysWith: { $1 })
        }
    }

    private struct SavedClient: Codable {
        let id: String
        let name: String
    }
    private var savedClients: [SavedClient] = []

    private func saveClients() {
        guard let clientsFile, let data = try? JSONEncoder().encode(savedClients) else {
            return
        }
        try? FileManager.default.createDirectory(at: clientsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: clientsFile, options: .atomic)
    }

    /// A request from a node's tunnel: only with that node's token.
    public func handleFromNode(_ request: HTTPRequest, store: NodeStore) async -> HTTPResponse {
        guard let node = store.node(forAuthorization: request.headers["authorization"]) else {
            return HTTPResponse(status: 401)
        }
        return await handle(request, node: node.host)
    }

    public func handle(_ request: HTTPRequest, node: String? = nil) async -> HTTPResponse {
        guard isLocalRequest(request) else {
            return HTTPResponse(status: 403)
        }
        guard request.path == "/mcp" else {
            return HTTPResponse(status: 404)
        }

        switch request.method {
        case "POST":
            break
        case "DELETE":
            if let sessionID = request.headers["mcp-session-id"] {
                clients.removeValue(forKey: sessionID)
                savedClients.removeAll { $0.id == sessionID }
                saveClients()
            }
            return HTTPResponse(status: 200)
        default:
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }

        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return json(status: 400, error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let id = message["id"], let method = message["method"] as? String else {
            // Notifications and client responses need no reply.
            return HTTPResponse(status: 202)
        }

        let params = message["params"] as? [String: Any] ?? [:]
        let sessionID = request.headers["mcp-session-id"]

        switch method {
        case "initialize":
            return initialize(id: id, params: params, node: node)
        case "ping":
            return json(result(id: id, [:]))
        case "tools/list":
            return json(result(id: id, ["tools": tools]))
        case "tools/call":
            let client = clientName(for: sessionID, userAgent: request.headers["user-agent"])
            let accept = request.headers["accept"] ?? ""
            if let token = (params["_meta"] as? [String: Any])?["progressToken"], accept.contains("text/event-stream"), waitsForUser(params) {
                return progressStream(id: id, params: params, client: client, progressToken: token)
            }
            let content = await callTool(params: params, client: client)
            return json(result(id: id, content))
        case "resources/list":
            return json(result(id: id, ["resources": resources]))
        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            guard let contents = readResource(uri) else {
                return json(error(id: id, code: -32002, message: "Resource not found: \(uri)"))
            }
            return json(result(id: id, ["contents": contents]))
        default:
            return json(error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Methods

    private func initialize(id: Any, params: [String: Any], node: String?) -> HTTPResponse {
        let requested = params["protocolVersion"] as? String ?? ""
        let version = supportedVersions.contains(requested) ? requested : supportedVersions.last!

        let info = params["clientInfo"] as? [String: Any] ?? [:]
        let name = info["title"] as? String ?? info["name"] as? String ?? "Agent"
        let sessionID = UUID().uuidString
        let display = Self.displayName(forClient: name) + (node.map { " on \($0)" } ?? "")
        // Lets new harness names be added to the list.
        log.notice("MCP client \(name, privacy: .public) shows as \(display, privacy: .public)")
        clients[sessionID] = display
        savedClients.append(SavedClient(id: sessionID, name: display))
        savedClients.removeFirst(max(0, savedClients.count - Self.keptClients))
        saveClients()

        let body = result(id: id, [
            "protocolVersion": version,
            // No list-changed notifications: replies are per request, so the server cannot push.
            "capabilities": ["tools": [:], "resources": [:]],
            "serverInfo": ["name": "tilde", "version": "0.2.0"],
            "instructions": tildeSkillBody,
        ])
        return json(body, headers: ["Mcp-Session-Id": sessionID])
    }

    // MARK: - Progress

    private func waitsForUser(_ params: [String: Any]) -> Bool {
        let name = params["name"] as? String
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let waitSeconds = arguments["wait_seconds"] as? Double ?? defaultWaitSeconds
        return (name == "start_annotation" || name == "wait_for_annotation") && waitSeconds > 0
    }

    /// Runs the tool call and streams a progress notification every 2 s until it returns.
    private func progressStream(id: Any, params: [String: Any], client: String, progressToken: Any) -> HTTPResponse {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let waitedSession = (params["arguments"] as? [String: Any])?["session_id"] as? String

        let ticker = Task {
            var progress = 0
            while !Task.isCancelled {
                let session = waitedSession.flatMap(store.session) ?? store.active
                let notification: [String: Any] = [
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": ["progressToken": progressToken, "progress": progress, "message": progressMessage(notes: session?.noteCount ?? 0)],
                ]
                continuation.yield(event(notification))
                progress += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Task {
            let content = await callTool(params: params, client: client)
            ticker.cancel()
            continuation.yield(event(result(id: id, content)))
            continuation.finish()
        }

        return HTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"], stream: stream)
    }

    private func progressMessage(notes: Int) -> String {
        switch notes {
        case 0:
            return "Tilde is open on the user's screen, waiting for annotations"
        case 1:
            return "Tilde is open on the user's screen: 1 note so far"
        default:
            return "Tilde is open on the user's screen: \(notes) notes so far"
        }
    }

    private func event(_ message: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return Data("event: message\ndata: ".utf8) + data + Data("\n\n".utf8)
    }

    // MARK: - Resources

    /// Sent feedback as resources, for clients that attach resources (for example with "@"):
    /// `tilde://feedback/latest` and one per recent batch.
    private var resources: [[String: Any]] {
        let folders = recentInboxFolders(root: inbox, limit: 10)
        guard !folders.isEmpty else {
            return []
        }

        let latest: [String: Any] = [
            "uri": "tilde://feedback/latest",
            "name": "latest",
            "title": "Latest Tilde feedback",
            "description": "The annotations and screenshots the user sent most recently.",
            "mimeType": "text/markdown",
        ]
        let batches = folders.map { folder -> [String: Any] in
            [
                "uri": "tilde://feedback/\(folder.lastPathComponent)",
                "name": folder.lastPathComponent,
                "title": "Tilde feedback \(batchTitle(folder))",
                "description": "Tilde feedback \(batchTitle(folder))",
                "mimeType": "text/markdown",
            ]
        }
        return [latest] + batches
    }

    /// The report as text, then each screenshot as a PNG blob, in report order.
    private func readResource(_ uri: String) -> [[String: Any]]? {
        let prefix = "tilde://feedback/"
        guard uri.hasPrefix(prefix) else {
            return nil
        }
        let id = String(uri.dropFirst(prefix.count))
        let folder = id == "latest" ? latestInboxFolder(root: inbox) : inbox.appendingPathComponent(id)
        guard let folder, !id.contains("/"), let report = try? String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8) else {
            return nil
        }

        var contents: [[String: Any]] = [["uri": uri, "mimeType": "text/markdown", "text": report]]
        for name in inboxImageNames(folder) {
            let data = (try? Data(contentsOf: folder.appendingPathComponent(name))) ?? Data()
            contents.append(["uri": "\(uri)/\(name)", "mimeType": "image/png", "blob": data.base64EncodedString()])
        }
        return contents
    }

    /// "2026-10-28 17:17 · i like this! nice!": the time and the first comment of a batch.
    private func batchTitle(_ folder: URL) -> String {
        let name = folder.lastPathComponent
        let date = String(name.prefix(10))
        let time = name.dropFirst(11).prefix(5).replacingOccurrences(of: "-", with: ":")
        let report = (try? String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8)) ?? ""
        let comment = report.components(separatedBy: "\n").first { $0.hasPrefix("> ") }.map { String($0.dropFirst(2).prefix(60)) }
        guard let comment else {
            return "\(date) \(time)"
        }
        return "\(date) \(time) · \(comment)"
    }

    /// Screenshot file names of a saved batch, close-up then context per annotation.
    private func inboxImageNames(_ folder: URL) -> [String] {
        var names: [String] = []
        var number = 1
        while true {
            let found = [imageName(number), contextImageName(number)].filter {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            if found.isEmpty {
                return names
            }
            names += found
            number += 1
        }
    }

    /// The report, then each annotation's close-up and context image after its caption.
    private func feedbackContent(_ feedback: Feedback, folder: URL?) -> [[String: Any]] {
        var content = [textBlock(reportText(for: feedback, folder: folder))]
        for (index, annotation) in feedback.annotations.enumerated() {
            let labelled = [(closeUpLabel(index + 1), annotation.image), (contextLabel(index + 1), annotation.contextImage)]
            for case let (label, image?) in labelled {
                content.append(textBlock(label))
                content.append(imageBlock(image))
            }
        }
        return content
    }

    private func textBlock(_ value: String) -> [String: Any] {
        ["type": "text", "text": value]
    }

    private func imageBlock(_ data: Data) -> [String: Any] {
        ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]
    }

    private var tools: [[String: Any]] {
        let waitSeconds: [String: Any] = [
            "type": "number",
            "description": "How long to wait for the user before returning (0–600, default 45).",
        ]
        return [
            [
                "name": "start_annotation",
                "annotations": ["title": "Ask the user for visual feedback", "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
                "description": "Opens Tilde for the user. Only when the user asks for it. Call first, no preamble. Returns the feedback (a report, and per annotation a close-up and a context screenshot), or a session_id that is still in progress.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Web page to open in Tilde's browser, such as http://localhost:3000."],
                        "context": [
                            "type": "string",
                            "enum": ["window", "none"],
                            "description": "\"window\" (default) adds a screenshot of the window around each annotation with the target outlined. \"none\" sends only the close-ups.",
                        ],
                        "wait_seconds": waitSeconds,
                    ],
                ],
            ],
            [
                "name": "wait_for_annotation",
                "annotations": ["title": "Wait for visual feedback", "readOnlyHint": true, "openWorldHint": false],
                "description": "Waits for the user's feedback. Returns the feedback, a cancellation, or that the user is still annotating.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Session id returned by start_annotation."],
                        "wait_seconds": waitSeconds,
                    ],
                    "required": ["session_id"],
                ],
            ],
        ]
    }

    private func callTool(params: [String: Any], client: String) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let waitSeconds = min(max(arguments["wait_seconds"] as? Double ?? defaultWaitSeconds, 0), maxWaitSeconds)

        switch name {
        case "start_annotation":
            var url: URL?
            if let text = arguments["url"] as? String {
                guard let parsed = URL(string: text), parsed.scheme != nil else {
                    return toolError("Invalid url: \(text)")
                }
                url = parsed
            }

            let context = arguments["context"] as? String ?? "window"
            guard context == "window" || context == "none" else {
                return toolError("Invalid context: \(context). Use \"window\" or \"none\".")
            }

            let session = store.start(client: client, url: url, capturesContext: context == "window")
            let state = await store.wait(for: session.id, seconds: waitSeconds)
            return toolResult(sessionID: session.id, state: state)

        case "wait_for_annotation":
            guard let sessionID = arguments["session_id"] as? String else {
                return toolError("session_id is required")
            }
            let state = await store.wait(for: sessionID, seconds: waitSeconds)
            return toolResult(sessionID: sessionID, state: state)

        default:
            return toolError("Unknown tool: \(name)")
        }
    }

    private func toolResult(sessionID: String, state: SessionStore.State?) -> [String: Any] {
        guard let state else {
            return toolError("Unknown session_id: \(sessionID)")
        }

        switch state {
        case .queued:
            return text("Queued behind another annotation session. session_id: \(sessionID). Call wait_for_annotation with this session_id to keep waiting.")
        case .annotating:
            return text("The user is still annotating. session_id: \(sessionID). Call wait_for_annotation with this session_id to keep waiting.")
        case .cancelled:
            return text("The user cancelled the annotation session \(sessionID) without sending feedback.")
        case .sent(let feedback, let folder):
            return ["content": feedbackContent(feedback, folder: folder)]
        }
    }

    // MARK: - Helpers

    private func clientName(for sessionID: String?, userAgent: String?) -> String {
        if let sessionID, let name = clients[sessionID] {
            return name
        }
        // An unknown session: the request may still say who sent it.
        log.notice("MCP session unknown, user agent \(userAgent ?? "-", privacy: .public)")
        return userAgent.flatMap(Self.knownName(forClient:)) ?? "Agent"
    }

    /// The app name for an MCP `clientInfo.name`. The HUD shows it with that app's icon, so
    /// the names match the agent apps that Tilde installs into.
    /// The harness's display name for an MCP clientInfo name, such as "Codex" for
    /// "codex-mcp-client" or "rmcp" (the Rust MCP library that Codex uses).
    nonisolated static func displayName(forClient name: String) -> String {
        knownName(forClient: name) ?? name
    }

    nonisolated static func knownName(forClient name: String) -> String? {
        let lowercased = name.lowercased()
        let known: [(match: String, name: String)] = [
            ("claude-code", "Claude Code"),
            ("claude code", "Claude Code"),
            ("claude", "Claude"),
            ("codex", "Codex"),
            ("rmcp", "Codex"),
            ("cursor", "Cursor"),
            ("windsurf", "Windsurf"),
            ("devin", "Windsurf"),
            ("gemini", "Gemini CLI"),
            ("visual studio code", "VS Code"),
            ("vscode", "VS Code"),
            ("copilot", "VS Code"),
        ]
        return known.first { lowercased.contains($0.match) }?.name
    }

    /// Rejects DNS-rebinding and browser cross-origin requests; the listener is loopback-only.
    private func isLocalRequest(_ request: HTTPRequest) -> Bool {
        let localHosts = ["127.0.0.1", "localhost", "[::1]"]
        let host = request.headers["host"] ?? ""
        let hostName = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : String(host.split(separator: ":").first ?? "")
        guard localHosts.contains(hostName) else {
            return false
        }

        guard let origin = request.headers["origin"], origin != "null" else {
            return true
        }
        let originHost = URL(string: origin)?.host.map { $0 == "::1" ? "[::1]" : $0 } ?? ""
        return localHosts.contains(originHost)
    }

    private func text(_ value: String) -> [String: Any] {
        ["content": [["type": "text", "text": value]]]
    }

    private func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func json(status: Int = 200, _ body: [String: Any], headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: allHeaders, body: data)
    }
}
