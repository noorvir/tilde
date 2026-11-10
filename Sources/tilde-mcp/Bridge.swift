import Foundation

/// Forwards an agent's JSON-RPC lines to Tilde's HTTP endpoint and gives each message of the
/// answers to `write`. `write` gets only whole JSON-RPC messages: a request that Tilde does
/// not answer with one gets a JSON-RPC error.
actor Bridge {
    private let endpoint: URL
    private let authorization: String
    private let write: @Sendable (Data) -> Void
    /// Starts Tilde; called once at most, when nothing listens at the endpoint.
    private let launch: @Sendable () -> Void
    private var launched = false
    private var mcpSessionID: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    init(endpoint: URL, authorization: String, write: @escaping @Sendable (Data) -> Void, launch: @escaping @Sendable () -> Void) {
        self.endpoint = endpoint
        self.authorization = authorization
        self.write = write
        self.launch = launch
    }

    /// Why an answer is not JSON-RPC.
    private enum Failure: Error {
        case status(Int)
        case notJSON
    }

    func forward(_ line: Data) async {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            write(error(id: NSNull(), code: -32700, message: "Parse error"))
            return
        }
        var reason = "Tilde is not reachable at \(endpoint.absoluteString). Start Tilde.app."

        attempts: for attempt in 0..<20 {
            do {
                try await post(line)
                return
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                if attempt == 0, !launched {
                    launched = true
                    launch()
                }
                try? await Task.sleep(for: .milliseconds(500))
            } catch Failure.status(401) {
                reason = "Tilde did not accept the token in ~/.tilde/local-token (HTTP 401)."
                break attempts
            } catch Failure.status(let status) {
                reason = "Tilde refused the call (HTTP \(status))."
                break attempts
            } catch Failure.notJSON {
                reason = "The answer from \(endpoint.absoluteString) was cut, or is not from Tilde. Call again."
                break attempts
            } catch {
                break attempts
            }
        }

        // A notification needs no answer.
        if let id = message["id"] {
            write(error(id: id, code: -32000, message: reason))
        }
    }

    /// Posts the line and writes each message of the answer.
    private func post(_ body: Data) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let mcpSessionID {
            request.setValue(mcpSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, (200..<300).contains(status) else {
            throw Failure.status(status)
        }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            mcpSessionID = id
        }
        let isEvents = http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true
        try await pass(bytes, isEvents: isEvents)
    }

    /// Writes the messages of an answer as they arrive: a JSON body is one message, and in an
    /// event stream each message is the data line of an event. Away from the actor, so that
    /// reading a byte never changes threads.
    private nonisolated func pass(_ bytes: URLSession.AsyncBytes, isEvents: Bool) async throws {
        let dataPrefix = Array("data: ".utf8)

        func pass(_ line: [UInt8]) throws {
            var message = line[...]
            if isEvents {
                guard line.starts(with: dataPrefix) else {
                    return
                }
                message = line.dropFirst(dataPrefix.count)
            }
            guard !message.isEmpty else {
                return
            }
            let data = Data(message)
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw Failure.notJSON
            }
            write(data)
        }

        // Lines end only at a line feed: JSON text may hold other line separators.
        var line: [UInt8] = []
        for try await byte in bytes {
            guard byte == 0x0A else {
                line.append(byte)
                continue
            }
            try pass(line)
            line.removeAll(keepingCapacity: true)
        }
        try pass(line)
    }

    private nonisolated func error(id: Any, code: Int, message: String) -> Data {
        let failure: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        return try! JSONSerialization.data(withJSONObject: failure)
    }
}
