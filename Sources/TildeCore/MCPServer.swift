import Foundation

/// MCP over Streamable HTTP (JSON responses only) at `/mcp`.
/// Exposes `start_annotation` and `wait_for_annotation` on top of a `SessionStore`.
@MainActor
public final class MCPServer {
    private let store: SessionStore
    /// Display names of connected harnesses, keyed by `Mcp-Session-Id`.
    private var clients: [String: String] = [:]

    private let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    private let defaultWaitSeconds = 45.0
    private let maxWaitSeconds = 600.0

    private let instructions = """
        Tilde lets the user give visual feedback on anything on their Mac: web pages, native apps, \
        the iOS Simulator. Call start_annotation to open annotate mode (pass url to open a page in \
        Tilde's browser, and message to tell the user what to look at). If a result reports that the \
        user is still annotating, call wait_for_annotation with the same session_id until it returns \
        the feedback or reports that the user cancelled. Each annotation comes with a close-up of the \
        target (primary) and a context image of its surroundings (secondary); look at the context \
        image only when the close-up does not show enough.
        """

    public init(store: SessionStore) {
        self.store = store
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
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
            return initialize(id: id, params: params)
        case "ping":
            return json(result(id: id, [:]))
        case "tools/list":
            return json(result(id: id, ["tools": tools]))
        case "tools/call":
            let content = await callTool(params: params, client: clientName(for: sessionID))
            return json(result(id: id, content))
        default:
            return json(error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Methods

    private func initialize(id: Any, params: [String: Any]) -> HTTPResponse {
        let requested = params["protocolVersion"] as? String ?? ""
        let version = supportedVersions.contains(requested) ? requested : supportedVersions.last!

        let info = params["clientInfo"] as? [String: Any] ?? [:]
        let name = info["title"] as? String ?? info["name"] as? String ?? "Agent"
        let sessionID = UUID().uuidString
        clients[sessionID] = displayName(forClient: name)

        let body = result(id: id, [
            "protocolVersion": version,
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "tilde", "version": "0.1.0"],
            "instructions": instructions,
        ])
        return json(body, headers: ["Mcp-Session-Id": sessionID])
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
                "description": "Opens annotate mode on the user's Mac. The user clicks elements or drags regions on any app or web page, comments on each and presses Send. Returns the feedback (markdown report plus, per annotation, a close-up and a smaller context screenshot that shows where the target sits) if the user sends within wait_seconds; otherwise returns a session_id that is still in progress.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "message": ["type": "string", "description": "Short note shown to the user, such as what to review."],
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
                "description": "Waits up to wait_seconds for the feedback of an annotation session. Returns the feedback, a cancellation, or that the user is still annotating.",
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
            let message = arguments["message"] as? String
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

            let session = store.start(client: client, message: message, url: url, capturesContext: context == "window")
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
            var content: [[String: Any]] = [["type": "text", "text": reportText(for: feedback, folder: folder)]]
            for (index, annotation) in feedback.annotations.enumerated() {
                let labelled = [(closeUpLabel(index + 1), annotation.image), (contextLabel(index + 1), annotation.contextImage)]
                for case let (label, image?) in labelled {
                    content.append(["type": "text", "text": label])
                    content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": "image/png"])
                }
            }
            return ["content": content]
        }
    }

    // MARK: - Helpers

    private func clientName(for sessionID: String?) -> String {
        guard let sessionID, let name = clients[sessionID] else {
            return "Agent"
        }
        return name
    }

    private func displayName(forClient name: String) -> String {
        let known = [
            "claude-code": "Claude Code",
            "codex-mcp-client": "Codex",
            "cursor-vscode": "Cursor",
            "gemini-cli-mcp-client": "Gemini CLI",
            "Visual Studio Code": "VS Code",
        ]
        return known[name] ?? name
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
