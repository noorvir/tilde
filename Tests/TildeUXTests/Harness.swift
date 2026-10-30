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
    case z = 6
    case leftBracket = 33
    case rightBracket = 30
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

    func key(_ key: Key, command: Bool = false, shift: Bool = false, option: Bool = false) async throws {
        try await drive("key", ["code": key.rawValue, "command": command, "shift": shift, "option": option])
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

    func hold(_ modifier: String, down: Bool) async throws {
        try await drive("modifier", ["key": modifier, "down": down])
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

    // MARK: - Screen pictures

    /// How many Tilde-blue pixels are on screen in this area: notes are drawn, so they have no
    /// accessibility elements to read.
    func bluePixels(in area: CGRect) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: Self.driver.appendingPathComponent("screenshot"))
        guard let picture = NSBitmapImageRep(data: data), let screen = NSScreen.screens.first else {
            throw UXFailure(description: "no screenshot")
        }
        let scale = Double(picture.pixelsWide) / screen.frame.width
        var count = 0
        for y in stride(from: Int(area.minY * scale), to: Int(area.maxY * scale), by: 2) {
            for x in stride(from: Int(area.minX * scale), to: Int(area.maxX * scale), by: 2) {
                guard let color = picture.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.blueComponent > 0.8, color.redComponent < 0.35, color.greenComponent > 0.25, color.greenComponent < 0.65 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Waits until the area has at least, or at most, this many blue pixels.
    func waitForBlue(in area: CGRect, atLeast: Int = 0, atMost: Int = .max, timeout: Double = 6, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = Date().addingTimeInterval(timeout)
        var last = 0
        while Date() < end {
            last = try await bluePixels(in: area)
            if last >= atLeast, last <= atMost {
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        Issue.record("\(last) blue pixels, expected \(atLeast)...\(atMost)", sourceLocation: sourceLocation)
        await saveScreenshot(named: "blue-\(sourceLocation.line)")
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

/// A window of another app whose whole content changes, like a page change in the Simulator.
final class ChangingWindow {
    /// The window on screen, in screen points from the top left.
    static let frame = CGRect(x: 300, y: 200, width: 500, height: 400)
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-page-\(UUID().uuidString)")
    private let process = Process()

    init() throws {
        try "a".write(to: file, atomically: true, encoding: .utf8)
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TILDE_UX_FIXTURE"] ?? "")
        process.arguments = [file.path]
        try process.run()
        Thread.sleep(forTimeInterval: 1)
    }

    func show(_ page: String) throws {
        try page.write(to: file, atomically: true, encoding: .utf8)
    }

    func close() {
        process.terminate()
        waitForExit(process)
    }
}

/// Two pages of plain text with the same layout, in Safari: a real browser, not Tilde's.
final class WebPages {
    enum Browser: String, CaseIterable, Sendable {
        case safari = "Safari"
        case chrome = "Google Chrome"
    }

    let first: String
    let second: String
    let singlePage: String
    let browser: Browser
    private let server = Process()
    private let folder: URL

    /// Where the buttons of the single page app are, from the top left of the page.
    static let forward = CGPoint(x: 50, y: 22)
    static let back = CGPoint(x: 150, y: 22)
    static let load = CGPoint(x: 250, y: 22)

    init(browser: Browser, port: Int = 7398) throws {
        self.browser = browser
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func page(_ rows: [String], script: String = "") -> String {
            let list = rows.map { "<p style=\"margin:0;line-height:30px\">\($0)</p>" }.joined()
            let bar = "<div style=\"position:fixed;top:0;left:0;height:44px\"><button id=f style=\"width:90px;height:44px\">Next</button><button id=b style=\"width:90px;height:44px;margin-left:10px\">Back</button><button onclick=\"location.href='second.html'\" style=\"width:90px;height:44px;margin-left:10px\">Load</button></div>"
            return "<!doctype html><meta charset=utf-8><title>T</title><body style=\"font:16px sans-serif;margin:60px 40px 0;color:#111\">\(bar)\(list)\(script)</body>"
        }
        // A new address each run: browsers keep pages of earlier runs.
        let run = UUID().uuidString
        let pagesFolder = folder.appendingPathComponent(run, isDirectory: true)
        try FileManager.default.createDirectory(at: pagesFolder, withIntermediateDirectories: true)
        let rows = (1...12).map { "Starlink outages disrupt drone operations \($0)" }
        try page(rows).write(to: pagesFolder.appendingPathComponent("first.html"), atomically: true, encoding: .utf8)
        // The same layout and the same first rows: only the address and the last row differ.
        try page(Array(rows.dropLast()) + ["Museum opens wing for modern painters"])
            .write(to: pagesFolder.appendingPathComponent("second.html"), atomically: true, encoding: .utf8)
        // Identical on both routes, so that only the address tells them apart.
        let routes = "<script>f.onclick=()=>history.pushState({},\"\",\"?route=b\");b.onclick=()=>history.back()</script>"
        try page(rows, script: routes).write(to: pagesFolder.appendingPathComponent("spa.html"), atomically: true, encoding: .utf8)
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", folder.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        first = "http://127.0.0.1:\(port)/\(run)/first.html"
        second = "http://127.0.0.1:\(port)/\(run)/second.html"
        singlePage = "http://127.0.0.1:\(port)/\(run)/spa.html"
        // The first page must not fail to load because the server is not listening yet.
        for _ in 0..<50 {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            check.arguments = ["-z", "127.0.0.1", String(port)]
            try check.run()
            waitForExit(check)
            if check.terminationStatus == 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Goes to a page in the front window of the browser. Chrome runs with its own empty
    /// profile the first time.
    func go(to url: String) {
        let script = Process()
        switch browser {
        case .safari:
            script.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            script.arguments = ["-a", "Safari", url]
            try? script.run()
            waitForExit(script)
        case .chrome:
            // Run again with the same profile, Chrome opens the address in its running copy.
            let profile = folder.appendingPathComponent("chrome-profile").path
            script.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
            script.arguments = ["--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check", "--window-position=200,100", "--window-size=1000,700", url]
            script.standardOutput = FileHandle.nullDevice
            script.standardError = FileHandle.nullDevice
            try? script.run()
        }
    }

    /// Waits for the window of the browser, which is slow to open the first time.
    func waitForPage() async throws {
        for _ in 0..<60 where pageArea == nil {
            try await Task.sleep(for: .milliseconds(500))
        }
        try await Task.sleep(for: .seconds(3))
    }

    /// Where the page is, without the toolbar of the browser.
    var pageArea: CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in list where window[kCGWindowOwnerName as String] as? String == browser.rawValue && window[kCGWindowLayer as String] as? Int == 0 {
            if let bounds = window[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds), frame.height > 200 {
                return CGRect(x: frame.minX, y: frame.minY + 90, width: frame.width, height: frame.height - 90)
            }
        }
        return nil
    }

    func quitBrowser() {
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        quit.arguments = [browser.rawValue]
        try? quit.run()
        waitForExit(quit)
    }

    func stop() {
        server.terminate()
        waitForExit(server)
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

/// The real iOS Simulator with a small app of two screens with the same layout.
final class SimulatorScreens {
    private static let device = "iPhone 17e"

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("scripts/ux-sim-app").path
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("TwoScreens.app").path
        try Self.run("rm -rf \"\(app)\"; mkdir -p \"\(app)\"; cp \"\(source)/Info.plist\" \"\(app)/\"; xcrun -sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \"\(source)/App.swift\" -o \"\(app)/TwoScreens\" && codesign -s - \"\(app)\"")
        try Self.run("xcrun simctl boot \"\(Self.device)\" 2>/dev/null; xcrun simctl bootstatus \"\(Self.device)\" >/dev/null; open \"$(xcode-select -p)/Applications/Simulator.app\"; xcrun simctl install \"\(Self.device)\" \"\(app)\"; xcrun simctl launch \"\(Self.device)\" dev.tilde.ux.twoscreens")
    }

    func show(_ screen: String) throws {
        try Self.run("xcrun simctl openurl \"\(Self.device)\" tildeux://\(screen)")
    }

    var window: CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let bounds = list.first { $0[kCGWindowOwnerName as String] as? String == "Simulator" && $0[kCGWindowLayer as String] as? Int == 0 }?[kCGWindowBounds as String] as? NSDictionary
        return bounds.flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    func stop() {
        try? Self.run("xcrun simctl shutdown \"\(Self.device)\"; killall Simulator")
    }

    private static func run(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        waitForExit(process)
    }
}
