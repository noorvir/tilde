import Foundation

/// MCP over Streamable HTTP at `/mcp`. Replies are JSON, except tool calls that wait for the
/// user: when the client sends a progress token and accepts event streams, those stream
/// progress notifications ("Tilde is open: 2 notes so far") before the result.
extension MCPServer {
    /// A request from an agent on this Mac: only with the local token.
    public func handleLocal(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.headers["authorization"] == "Bearer \(localToken)" else {
            return HTTPResponse(status: 401)
        }
        return await handle(request, node: nil)
    }

    /// A request from a node's tunnel: only with that node's token, and only from a node that
    /// is not linked by its socket.
    public func handleFromNode(_ request: HTTPRequest, store: NodeStore) async -> HTTPResponse {
        guard let node = store.node(forAuthorization: request.headers["authorization"]), node.socket == nil else {
            return HTTPResponse(status: 401)
        }
        return await handle(request, node: node.host)
    }

    /// A request whose caller is known: `node` is the machine it came from, nil for this Mac.
    func handle(_ request: HTTPRequest, node: String?) async -> HTTPResponse {
        guard isLocalRequest(request) else {
            return HTTPResponse(status: 403)
        }
        guard request.path == "/mcp" else {
            return HTTPResponse(status: 404)
        }
        let session = request.headers["mcp-session-id"]

        switch request.method {
        case "POST":
            // A web page can only send JSON after a preflight, which gets 405.
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                return HTTPResponse(status: 415)
            }
        case "DELETE":
            if let session {
                end(session: session, node: node)
            }
            return HTTPResponse(status: 200)
        default:
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }

        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return HTTPResponse(status: 400, headers: ["Content-Type": "application/json"], body: Self.parseError)
        }
        let caller = Caller(session: session, node: node, userAgent: request.headers["user-agent"])
        let reply = await receive(message, from: caller)

        switch reply {
        case .none:
            return HTTPResponse(status: 202)
        case .message(let body, let made):
            var headers = ["Content-Type": "application/json"]
            headers["Mcp-Session-Id"] = made
            return HTTPResponse(status: 200, headers: headers, body: body)
        case .stream(let messages):
            guard request.headers["accept"]?.contains("text/event-stream") == true else {
                // Without an event stream, only the result: the last message.
                var result = Data()
                for await message in messages {
                    result = message
                }
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: result)
            }
            return HTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"], stream: events(messages))
        }
    }

    /// Each message as one server-sent event. A reader that stops ends the messages too.
    private func events(_ messages: AsyncStream<Data>) -> AsyncStream<Data> {
        let (events, continuation) = AsyncStream<Data>.makeStream()
        let framing = Task {
            for await message in messages {
                continuation.yield(Data("event: message\ndata: ".utf8) + message + Data("\n\n".utf8))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            framing.cancel()
        }
        return events
    }

    /// Rejects DNS-rebinding and browser cross-origin requests; the listener is loopback-only.
    private func isLocalRequest(_ request: HTTPRequest) -> Bool {
        let localHosts = ["127.0.0.1", "localhost", "[::1]"]
        let host = request.headers["host"] ?? ""
        let hostName = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : String(host.split(separator: ":").first ?? "")
        guard localHosts.contains(hostName) else {
            return false
        }

        // A page in a sandboxed frame or from a file sends "null", which is not local.
        guard let origin = request.headers["origin"] else {
            return true
        }
        let originHost = URL(string: origin)?.host.map { $0 == "::1" ? "[::1]" : $0 } ?? ""
        return localHosts.contains(originHost)
    }
}
