import AppKit
import Foundation
import Testing

/// Whether the UX specs run at all: only from scripts/ux.sh, as they take over the screen.
let uxEnabled = ProcessInfo.processInfo.environment["TILDE_UX"] == "1"

/// Waits a limited time: `waitUntilExit` can hang for ever on a concurrency thread.
func waitForExit(_ process: Process, limit: TimeInterval = 10) {
    let end = Date().addingTimeInterval(limit)
    while process.isRunning, Date() < end {
        Thread.sleep(forTimeInterval: 0.05)
    }
}

struct UXFailure: Error, CustomStringConvertible {
    let description: String
}

/// What the user sees: one element of the app's accessibility tree.
struct Seen {
    let role: String
    let name: String?
    let enabled: Bool
    let frame: CGRect
    let children: [Seen]

    init(_ json: [String: Any]) {
        role = json["role"] as? String ?? ""
        name = json["name"] as? String
        enabled = json["enabled"] as? Bool ?? true
        let numbers = json["frame"] as? [Double] ?? [0, 0, 0, 0]
        frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        children = (json["children"] as? [[String: Any]] ?? []).map(Seen.init)
    }

    var flattened: [Seen] {
        [self] + children.flatMap(\.flattened)
    }
}

/// A key on the keyboard, by what a user would call it.
enum Key: Int {
    case escape = 53
    case enter = 36
    case w = 13
    case a = 0
}

/// The built app in a throwaway environment, driven from outside: real input and the
/// accessibility tree through TildeDriver, MCP over HTTP, and files on disk.
final class TildeApp {
    let port: Int
    let sessions: URL
    let inbox: URL
    private static let driver = URL(string: "http://127.0.0.1:7320")!
    private static var nextPort = 7340

    /// `sharing`: keeps the saved sessions of an app run before, as after a crash.
    init(sharing other: TildeApp? = nil) throws {
        Self.nextPort += 1
        port = Self.nextPort
        let root = other?.sessions.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-\(UUID().uuidString)", isDirectory: true)
        sessions = root.appendingPathComponent("sessions", isDirectory: true)
        inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try launch()
    }

    /// Starts the app as Finder would, so macOS applies its own permissions.
    private func launch() throws {
        Self.stopAll()
        let bundle = ProcessInfo.processInfo.environment["TILDE_UX_APP"] ?? "build/TildeUX.app"
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [
            "-n", "--env", "TILDE_PORT=\(port)", "--env", "TILDE_SESSIONS=\(sessions.path)", "--env", "TILDE_INBOX=\(inbox.path)", bundle,
        ]
        try open.run()
        waitForExit(open)
    }

    /// Stops every copy of the test app and waits until they are gone, so the next launch is
    /// the only one that answers.
    private static func stopAll() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tilde.ux") {
            Darwin.kill(app.processIdentifier, SIGKILL)
        }
        for _ in 0..<50 where !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tilde.ux").filter({ !$0.isTerminated }).isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tilde.ux").first { !$0.isTerminated }
    }

    static func resetSettings() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["delete", "dev.tilde.ux"]
        task.standardError = FileHandle.nullDevice
        try? task.run()
        waitForExit(task)
    }

    /// Fresh settings and sessions, as on a new Mac.
    static func launched() async throws -> TildeApp {
        resetSettings()
        let app = try TildeApp()
        try await app.waitForServer()
        return app
    }

    static func relaunched(after other: TildeApp) async throws -> TildeApp {
        let app = try TildeApp(sharing: other)
        try await app.waitForServer()
        return app
    }

    func quit() {
        Self.stopAll()
    }

    /// As a crash: the app gets no chance to save.
    func kill() {
        Self.stopAll()
    }

    private var pid: Int {
        Int(running?.processIdentifier ?? 0)
    }

    func waitForServer() async throws {
        for _ in 0..<50 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, timeoutInterval: 2)
            request.httpMethod = "GET"
            if (try? await URLSession.shared.data(for: request)) != nil {
                try await Task.sleep(for: .milliseconds(500))
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw UXFailure(description: "Tilde did not start its MCP server")
    }

    // MARK: - Driver

    @discardableResult
    private func drive(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.driver.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Everything on screen from the app.
    func seen() async throws -> [Seen] {
        let result = try await drive("ax", ["pid": pid])
        return (result["tree"] as? [[String: Any]] ?? []).map(Seen.init).flatMap(\.flattened)
    }

    /// Clicks the control with this name with the mouse, as a user does: unlike an
    /// accessibility press, this also makes the app active.
    func press(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await clickText(name, sourceLocation: sourceLocation)
    }

    func key(_ key: Key, command: Bool = false) async throws {
        try await drive("key", ["code": key.rawValue, "command": command])
        try await Task.sleep(for: .milliseconds(300))
    }

    func type(_ text: String) async throws {
        try await drive("type", ["text": text])
        try await Task.sleep(for: .milliseconds(200))
    }

    func doubleTap(_ modifier: String) async throws {
        try await drive("tap", ["key": modifier])
        try await Task.sleep(for: .milliseconds(80))
        try await drive("tap", ["key": modifier])
        try await Task.sleep(for: .milliseconds(400))
    }

    func click(at point: CGPoint) async throws {
        try await drive("mouse", ["type": "move", "x": point.x, "y": point.y])
        try await Task.sleep(for: .milliseconds(200))
        try await drive("mouse", ["type": "click", "x": point.x, "y": point.y])
        try await Task.sleep(for: .milliseconds(300))
    }

    func hover(over point: CGPoint) async throws {
        try await drive("mouse", ["type": "move", "x": point.x, "y": point.y])
    }

    /// Clicks the element with this text, such as on a web page.
    func clickText(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // Windows can still be moving just after they open: wait until it holds still.
        var element = try await waitToSee(text, sourceLocation: sourceLocation)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(200))
            let again = try await waitToSee(text, sourceLocation: sourceLocation)
            if again.frame == element.frame {
                break
            }
            element = again
        }
        try await click(at: CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    // MARK: - Expectations

    /// Waits until an element with this name is on screen.
    @discardableResult
    func waitToSee(_ name: String, timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Seen {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let found = try await seen().first(where: { $0.name == name }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        await saveScreenshot(named: name)
        let names = try await seen().compactMap(\.name)
        Issue.record("\"\(name)\" is not on screen. On screen: \(names.prefix(40))", sourceLocation: sourceLocation)
        throw UXFailure(description: "\(name) is not on screen")
    }

    /// Keeps a picture of the screen for a failed expectation, in the temporary folder.
    private func saveScreenshot(named name: String) async {
        guard let (data, _) = try? await URLSession.shared.data(from: Self.driver.appendingPathComponent("screenshot")) else {
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-failure-\(name.prefix(12)).png")
        try? data.write(to: file)
    }

    /// Waits until no element with this name is on screen.
    func waitNotToSee(_ name: String, timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await !seen().contains(where: { $0.name == name }) {
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        Issue.record("\"\(name)\" is still on screen", sourceLocation: sourceLocation)
    }

    /// Waits until some text containing this is on screen.
    @discardableResult
    func waitToSeeText(containing part: String, timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Seen {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let found = try await seen().first(where: { $0.name?.contains(part) == true }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        let names = try await seen().compactMap(\.name)
        Issue.record("No text with \"\(part)\" on screen. On screen: \(names.prefix(40))", sourceLocation: sourceLocation)
        throw UXFailure(description: "\(part) is not on screen")
    }

    // MARK: - Menu bar

    /// Clicks the menu bar item to open its menu, as a user does.
    func openMenu() async throws {
        let item = try await waitToSeeRole("AXMenuBarItem")
        try await click(at: CGPoint(x: item.frame.midX, y: item.frame.midY))
        try await Task.sleep(for: .milliseconds(400))
    }

    /// Opens the menu and presses an item. The app keeps the keyboard in the menu afterwards,
    /// so flows that type next start another way.
    func menu(_ item: String) async throws {
        try await openMenu()
        try await waitToSee(item)
        try await drive("press", ["pid": pid, "name": item, "role": "AXMenuItem"])
        try await Task.sleep(for: .milliseconds(500))
    }

    private func waitToSeeRole(_ role: String) async throws -> Seen {
        for _ in 0..<30 {
            if let found = try await seen().first(where: { $0.role == role }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw UXFailure(description: "no \(role) on screen")
    }

    // MARK: - Window pictures

    /// Compares the app's window with this title to its baseline PNG, leaving out the version
    /// text at the bottom of the sidebar, which changes with every build.
    func expectWindow(titled title: String, matches name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let reply = try await drive("window", ["pid": pid, "title": title])
        guard let encoded = reply["png"] as? String, let picture = Data(base64Encoded: encoded) else {
            Issue.record("No window titled \(title)", sourceLocation: sourceLocation)
            return
        }
        let actual = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).png")
        try picture.write(to: actual)

        let baseline = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Baselines/\(name).png")
        if ProcessInfo.processInfo.environment["TILDE_UX_RECORD"] == "1" {
            try? FileManager.default.removeItem(at: baseline)
            try FileManager.default.copyItem(at: actual, to: baseline)
            return
        }
        // Baselines belong to one macOS version, as controls render differently on others.
        let recordedOn = (try? String(contentsOf: baseline.deletingLastPathComponent().appendingPathComponent("macos-version.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard recordedOn == String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) else {
            return
        }
        guard let expected = NSBitmapImageRep(data: try Data(contentsOf: baseline)),
              let image = NSBitmapImageRep(data: try Data(contentsOf: actual))
        else {
            Issue.record("No baseline \(name); record it with TILDE_UX_RECORD=1", sourceLocation: sourceLocation)
            return
        }
        let difference = Self.difference(expected, image)
        #expect(difference < 0.002, "\(name) differs by \(difference * 100)%: \(actual.path)", sourceLocation: sourceLocation)
    }

    private static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
            return 1
        }
        var different = 0
        // The bottom left corner holds the version.
        let versionTop = a.pixelsHigh - 100
        let versionRight = a.pixelsWide / 4
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) where !(y > versionTop && x < versionRight) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let red: CGFloat = abs(p.redComponent - q.redComponent)
                let green: CGFloat = abs(p.greenComponent - q.greenComponent)
                let blue: CGFloat = abs(p.blueComponent - q.blueComponent)
                if red + green + blue > 0.05 {
                    different += 1
                }
            }
        }
        return Double(different) / Double(a.pixelsWide * a.pixelsHigh / 4)
    }
}

/// An agent connected over MCP, as Codex or Claude Code would be.
final class MCPAgent {
    struct Reply {
        let text: String
        let images: [Data]
    }

    private let endpoint: URL
    private var sessionID: String?
    private var nextID = 1

    init(port: Int, name: String) async throws {
        endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        _ = try await post("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": name, "version": "1"]])
    }

    func call(_ tool: String, _ arguments: [String: Any]) async throws -> Reply {
        let result = try await post("tools/call", ["name": tool, "arguments": arguments])
        let content = result["content"] as? [[String: Any]] ?? []
        return Reply(
            text: content.compactMap { $0["text"] as? String }.joined(separator: "\n"),
            images: content.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        )
    }

    private func post(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        nextID += 1
        let (data, response) = try await URLSession.shared.data(for: request)
        if let id = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = id
        }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let result = body["result"] as? [String: Any] else {
            throw UXFailure(description: "\(method) failed: \(body)")
        }
        return result
    }
}

/// A small web page on localhost for the browser flows.
final class TestPage {
    let url: String
    private let server = Process()

    init(port: Int = 7399) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Test page</title></head>
        <body style="font: 16px sans-serif; margin: 40px; min-height: 3000px">
        <h1>Welcome page</h1><p><button id="save">Save changes</button></p><p>Second paragraph</p>
        <p><a href="other.html">Other page</a></p></body></html>
        """
        try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Other</title><h1>Other page heading</h1>".write(to: folder.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", folder.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        url = "http://127.0.0.1:\(port)/"
        Thread.sleep(forTimeInterval: 0.8)
    }

    func stop() {
        server.terminate()
        waitForExit(server)
    }
}
