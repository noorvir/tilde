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
// Without the token, Tilde answers 401, which the agent gets as an error.
let authorization = (try? LocalToken.authorization(home: FileManager.default.homeDirectoryForCurrentUser)) ?? ""
let output = DispatchQueue(label: "tilde-mcp.stdout")

let bridge = Bridge(endpoint: endpoint, authorization: authorization) { message in
    output.sync {
        FileHandle.standardOutput.write(message + Data("\n".utf8))
    }
} launch: {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.tilde.app") else {
        return
    }
    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
}

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
