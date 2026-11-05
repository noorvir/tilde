// Stdio bridge for harnesses that start MCP servers as processes.
// Forwards each newline-delimited JSON-RPC message to the Tilde app's HTTP endpoint
// and writes replies to stdout. Starts the app when it is not running.
// `tilde-mcp install` instead sets up agent apps; see Install.swift.

import AppKit
import Foundation
import TildeInstaller

if CommandLine.arguments.dropFirst().first == "install" {
    exit(runInstall(Array(CommandLine.arguments.dropFirst(2))))
}

let port = ProcessInfo.processInfo.environment["TILDE_PORT"] ?? "7311"
let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
let authorization = LocalToken.authorization(home: FileManager.default.homeDirectoryForCurrentUser)
let output = DispatchQueue(label: "tilde-mcp.stdout")
let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 900
    configuration.timeoutIntervalForResource = 900
    return URLSession(configuration: configuration)
}()

actor Bridge {
    private var mcpSessionID: String?
    private var launchedApp = false

    func forward(_ line: Data) async {
        let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let id = message?["id"]

        for attempt in 0..<20 {
            do {
                let reply = try await post(line)
                if !reply.isEmpty {
                    write(reply)
                }
                return
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                if attempt == 0 {
                    launchApp()
                }
                try? await Task.sleep(for: .milliseconds(500))
            } catch {
                break
            }
        }

        if let id {
            let failure: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32000, "message": "Tilde is not reachable at \(endpoint.absoluteString). Start Tilde.app."],
            ]
            write(try! JSONSerialization.data(withJSONObject: failure))
        }
    }

    private func post(_ body: Data) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let mcpSessionID {
            request.setValue(mcpSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            mcpSessionID = id
        }
        return data
    }

    private func launchApp() {
        guard !launchedApp else {
            return
        }
        launchedApp = true

        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.tilde.app") else {
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

func write(_ data: Data) {
    output.sync {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

let bridge = Bridge()

// The initialize request must finish first so later calls carry its session id.
var initialized = false
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else {
        continue
    }
    let data = Data(line.utf8)

    if !initialized {
        initialized = true
        let done = DispatchSemaphore(value: 0)
        Task {
            await bridge.forward(data)
            done.signal()
        }
        done.wait()
        continue
    }

    Task {
        await bridge.forward(data)
    }
}
