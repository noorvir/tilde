import Foundation
import Network

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    /// Header names are lowercased.
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// When set, the server sends `body` first, then each chunk as it arrives, and closes the
    /// connection when the stream ends. Used for server-sent events.
    public var stream: AsyncStream<Data>?

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), stream: AsyncStream<Data>? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.stream = stream
    }
}

/// Minimal HTTP/1.1 server on the loopback interface. One request per connection;
/// requests are handled concurrently so long-polling calls do not block others.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public enum Status: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "tilde.http")
    private let maxBodySize = 10 * 1024 * 1024
    /// Open connections at most; more are closed at once. Long polls keep theirs open.
    private let maxConnections = 64
    /// A request must arrive in full this soon after its connection opens.
    private let readTimeout: TimeInterval = 10
    // Read and written on `queue` only.
    private var connections = 0

    public init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }
        listener = try NWListener(using: parameters, on: endpointPort)
        self.handler = handler
    }

    public func start(onStatus: @escaping @Sendable (Status) -> Void) {
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                onStatus(.ready(port: listener.port?.rawValue ?? 0))
            case .failed(let error), .waiting(let error):
                onStatus(.failed(error.localizedDescription))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        onStatus(.starting)
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard connections < maxConnections else {
            connection.cancel()
            return
        }
        connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections -= 1
            default:
                break
            }
        }
        connection.start(queue: queue)
        let reading = Reading()
        queue.asyncAfter(deadline: .now() + readTimeout) {
            if !reading.isDone {
                connection.cancel()
            }
        }
        receive(on: connection, buffer: Data(), reading: reading)
    }

    /// Whether a connection's request has arrived; read and written on `queue` only.
    private final class Reading: @unchecked Sendable {
        var isDone = false
    }

    private func receive(on connection: NWConnection, buffer: Data, reading: Reading) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }

            switch Self.parse(buffer, maxBodySize: self.maxBodySize) {
            case .incomplete where error == nil && !isComplete:
                self.receive(on: connection, buffer: buffer, reading: reading)
            case .incomplete:
                connection.cancel()
            case .invalid(let status):
                reading.isDone = true
                self.send(HTTPResponse(status: status), on: connection)
            case .request(let request):
                reading.isDone = true
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    enum ParseResult {
        case incomplete
        case invalid(status: Int)
        case request(HTTPRequest)
    }

    /// A request from the bytes so far, or whether more must come, or the error status.
    static func parse(_ buffer: Data, maxBodySize: Int) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid(status: 431) : .incomplete
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else {
            return .invalid(status: 400)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        if headers["transfer-encoding"] != nil {
            return .invalid(status: 411)
        }
        // Digits only: Int() also takes a sign, and a negative length would end in a crash.
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.allSatisfy(\.isASCII), lengthText.allSatisfy(\.isNumber), let length = Int(lengthText) else {
            return .invalid(status: 400)
        }
        if length > maxBodySize {
            return .invalid(status: 413)
        }

        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else {
            return .incomplete
        }

        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        let path = String(requestLine[1].split(separator: "?", maxSplits: 1)[0])
        return .request(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: body))
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        if response.stream == nil {
            headers["Content-Length"] = String(response.body.count)
        }
        headers["Connection"] = "close"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        guard let stream = response.stream else {
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        // Without a length, the end of the stream is marked by closing the connection.
        connection.send(content: payload, completion: .idempotent)
        Task {
            for await chunk in stream {
                connection.send(content: chunk, completion: .idempotent)
            }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        default: return "Status"
        }
    }
}
