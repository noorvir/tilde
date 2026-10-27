// End-to-end check of the annotate flow without OS permissions or real input devices.
// Runs the real MCP server, browser, overlay, HUD and comment panel in this process,
// drives them with synthesized AppKit events, and acts as the agent over HTTP.
// Writes rendered screens and the agent's result to the output folder.
//
//   tilde-e2e [--out DIR]          internal agent; exits 0 when every check passes
//   tilde-e2e --external [--out D] waits for a real agent to call start_annotation on :7312

@testable import TildeUI
import TildeCore
import AppKit
import SwiftUI
import WebKit

let arguments = CommandLine.arguments
let isExternal = arguments.contains("--external")
let outputFolder: URL = {
    if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    return URL(fileURLWithPath: "build/e2e", isDirectory: true)
}()
let mcpPort: UInt16 = 7312
let pagePort: UInt16 = 7313

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let harness = Harness()
    harness.start()
    app.run()
}

@MainActor
final class Harness {
    let store = SessionStore()
    let browser = BrowserController()
    lazy var controller = AnnotationController(store: store, browser: browser)
    lazy var mcp = MCPServer(store: store)
    var servers: [HTTPServer] = []

    func start() {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        _ = controller

        let mcp = self.mcp
        let fixture = try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixture.html"))
        servers = [
            try! HTTPServer(port: mcpPort) { request in await mcp.handle(request) },
            try! HTTPServer(port: pagePort) { _ in HTTPResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: fixture) },
        ]
        for server in servers {
            server.start { status in
                if case .failed(let message) = status {
                    print("server failed: \(message)")
                    exit(3)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + (isExternal ? 900 : 120)) {
            print("E2E FAILED: timed out")
            exit(2)
        }

        Task {
            do {
                try await run()
                print("E2E PASSED")
                exit(0)
            } catch {
                print("E2E FAILED: \(error)")
                await render("failure")
                exit(1)
            }
        }
    }

    // MARK: - Scenario

    func run() async throws {
        var agent: Agent?
        if isExternal {
            print("Waiting for an agent to call start_annotation on http://127.0.0.1:\(mcpPort)/mcp")
            try await until("an agent starts a session", timeout: 840) { self.store.active != nil }
        } else {
            let client = Agent(port: mcpPort)
            try await client.initialize(name: "codex-mcp-client")
            let started = try await client.call("start_annotation", [
                "url": "http://127.0.0.1:\(pagePort)/",
                "message": "Check the documents table: owner chips and spacing.",
                "wait_seconds": 0,
            ])
            try check(started.text.contains("still annotating"), "start_annotation returns in-progress status")
            agent = client
        }

        let session = try require(store.active, "an active session")
        print("session \(session.id) for \(session.client)")
        try await until("annotate mode is on") { self.controller.phase == .annotating }
        if session.url == nil {
            browser.show(URL(string: "http://127.0.0.1:\(pagePort)/"))
        }
        try await until("the page is loaded", timeout: 30) { await self.pageIsReady() }
        await render("01-start")

        // Element: hover, click, comment with Return.
        let chip = try await screenRect(ofFirst: "tbody tr:nth-child(2) td:nth-child(3) .chip")
        let chipCenter = CGPoint(x: chip.midX, y: chip.midY)
        mouse(.mouseMoved, at: chipCenter)
        try await until("hover finds the element") { self.controller.hover != nil }
        try check(controller.hover?.chip == "span", "hover chip is span, got \(controller.hover?.details ?? [])")
        await render("02-hover")

        mouse(.leftMouseDown, at: chipCenter)
        mouse(.leftMouseUp, at: chipCenter)
        try await until("the comment box opens") { self.controller.composer != nil && self.commentFieldIsFocused }
        await render("03-comment-open")
        type("Avatar and name are not vertically centered")
        await render("04-comment-typed")
        key("\r", code: 36)
        try await until("the first annotation is added") { self.controller.drafts.count == 1 }

        // Region: drag, comment, then ⌘↩ sends everything.
        let table = try await screenRect(ofFirst: "table")
        let start = CGPoint(x: table.minX + 160, y: table.maxY - 64)
        let end = CGPoint(x: table.maxX - 260, y: table.maxY + 90)
        mouse(.leftMouseDown, at: start)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        await render("05-dragging")
        mouse(.leftMouseUp, at: end)
        try await until("the region comment box opens") { self.controller.pendingTarget != nil && self.commentFieldIsFocused }
        type("Too much empty space under the table")
        controller.showsList = true
        await render("06-region-and-list")

        key("\r", code: 36, modifiers: .command)
        try await until("the feedback is sent") {
            if case .sent = self.controller.phase {
                return true
            }
            return false
        }
        await render("07-sent")

        guard case .sent(let feedback, let folder)? = store.session(session.id)?.state else {
            throw CheckFailure(description: "session is not sent")
        }
        try check(feedback.annotations.count == 2, "two annotations sent")
        try check(folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("feedback.md").path) } == true, "inbox feedback.md written")
        print("inbox: \(folder?.path ?? "none")")

        guard let agent else {
            return
        }

        let result = try await agent.call("wait_for_annotation", ["session_id": session.id, "wait_seconds": 5])
        let report = result.text
        try report.write(to: outputFolder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        for (index, image) in result.images.enumerated() {
            try image.write(to: outputFolder.appendingPathComponent("agent-image-\(index + 1).png"))
        }

        try check(report.contains("> Avatar and name are not vertically centered"), "report has the element comment")
        try check(report.contains("> Too much empty space under the table"), "report has the region comment")
        try check(report.contains("React components: App › DocumentsTable › DocumentRow › OwnerChip"), "report has the React component path")
        try check(report.contains("Selector: `"), "report has a selector")
        try check(result.images.count == 2, "agent receives two images, got \(result.images.count)")
    }

    // MARK: - Page

    private func pageIsReady() async -> Bool {
        let ready = try? await browser.webView.callAsyncJavaScript(
            "return !!window.__tilde && !!document.querySelector('tbody tr')",
            arguments: [:], contentWorld: .page
        )
        return ready as? Bool == true
    }

    /// Quartz screen rect of the first element matching `selector` in the browser.
    private func screenRect(ofFirst selector: String) async throws -> CGRect {
        let value = try await browser.webView.callAsyncJavaScript(
            "const r = document.querySelector(s).getBoundingClientRect(); return [r.x, r.y, r.width, r.height];",
            arguments: ["s": selector], contentWorld: .page
        )
        let numbers = try require(value as? [Double], "rect of \(selector)")
        let webView = browser.webView
        let window = try require(webView.window, "browser window")

        var viewRect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        if !webView.isFlipped {
            viewRect.origin.y = webView.bounds.height - viewRect.maxY
        }
        return window.convertToScreen(webView.convert(viewRect, to: nil)).flipped
    }

    // MARK: - Synthesized input

    private var overlays: [OverlayWindow] {
        NSApp.windows.compactMap { $0 as? OverlayWindow }.filter(\.isVisible)
    }

    private var hudWindow: NSWindow? {
        NSApp.windows.first { $0.contentView is NSHostingView<HUDView> }
    }

    private var commentWindow: NSWindow? {
        NSApp.windows.first { $0 is FloatingPanel && $0 !== hudWindow && $0.isVisible }
    }

    private var commentFieldIsFocused: Bool {
        commentWindow?.firstResponder is NSTextView
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
        guard let window = overlays.first(where: { $0.frame.contains(point.flipped) }) ?? overlays.first,
              let view = window.contentView
        else {
            return
        }

        let location = window.convertPoint(fromScreen: point.flipped)
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
        // Tracking areas deliver mouse-moved events to the view; clicks go through the window.
        if type == .mouseMoved {
            view.mouseMoved(with: event)
        } else {
            window.sendEvent(event)
        }
    }

    private func type(_ text: String) {
        for character in text {
            key(String(character), code: 0)
        }
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = commentWindow else {
            return
        }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )!
        if modifiers.contains(.command), window.performKeyEquivalent(with: event) {
            return
        }
        window.sendEvent(event)
    }

    // MARK: - Rendering

    /// Renders Tilde's visible windows into one screen-sized PNG, back to front.
    private func render(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(250))
        guard let screen = NSScreen.screens.first else {
            return
        }

        var webSnapshot: NSImage?
        if browser.webView.window?.isVisible == true {
            webSnapshot = try? await browser.webView.takeSnapshot(configuration: nil)
        }

        let size = screen.frame.size
        let scale = 2
        let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        canvas.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSGradient(starting: NSColor(srgbRed: 0.80, green: 0.78, blue: 0.84, alpha: 1), ending: NSColor(srgbRed: 0.93, green: 0.85, blue: 0.76, alpha: 1))?
            .draw(in: NSRect(origin: .zero, size: size), angle: -70)

        if let browserWindow = browser.webView.window, browserWindow.isVisible {
            draw(browserWindow, rounded: true)
            if let webSnapshot {
                let frame = browserWindow.convertToScreen(browser.webView.convert(browser.webView.bounds, to: nil))
                webSnapshot.draw(in: frame)
            }
        }
        for window in overlays {
            draw(window, rounded: false)
        }
        if let commentWindow {
            draw(commentWindow, rounded: false)
        }
        if let hudWindow, hudWindow.isVisible {
            draw(hudWindow, rounded: false)
        }
        NSGraphicsContext.restoreGraphicsState()

        let url = outputFolder.appendingPathComponent("\(name).png")
        try? canvas.representation(using: .png, properties: [:])?.write(to: url)
        print("rendered \(url.path)")
    }

    private func draw(_ window: NSWindow, rounded: Bool) {
        guard let view = window.contentView else {
            return
        }
        // A zeroed RGBA bitmap keeps transparent areas transparent.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = view.bounds.size
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.set()
        NSRect(origin: .zero, size: view.bounds.size).fill(using: .copy)
        // Render exactly what the view and its layers paint, flipped to AppKit's origin.
        let cgContext = context.cgContext
        cgContext.translateBy(x: 0, y: view.bounds.height)
        cgContext.scaleBy(x: 1, y: -1)
        if let layer = view.layer {
            layer.render(in: cgContext)
        } else {
            view.draw(view.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        if rounded {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: window.frame, xRadius: 12, yRadius: 12).fill()
            NSBezierPath(roundedRect: window.frame, xRadius: 12, yRadius: 12).addClip()
        }
        // NSImageRep.draw(in:) composites with .copy, which would punch transparent holes.
        rep.draw(in: window.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Helpers

    private func until(_ what: String, timeout: Double = 10, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CheckFailure(description: "timed out waiting until \(what)")
    }

    private func check(_ condition: Bool, _ what: String) throws {
        guard condition else {
            throw CheckFailure(description: "check failed: \(what)")
        }
        print("ok: \(what)")
    }

    private func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else {
            throw CheckFailure(description: "missing \(what)")
        }
        return value
    }
}

/// Minimal MCP client over HTTP, standing in for an agent harness.
final class Agent {
    struct Result {
        let text: String
        let images: [Data]
    }

    private let endpoint: URL
    private var sessionID: String?
    private var nextID = 1

    init(port: UInt16) {
        endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    func initialize(name: String) async throws {
        _ = try await post("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": name, "version": "1"]])
    }

    func call(_ tool: String, _ arguments: [String: Any]) async throws -> Result {
        let result = try await post("tools/call", ["name": tool, "arguments": arguments])
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let images = content.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        return Result(text: text, images: images)
    }

    private func post(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
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
            throw CheckFailure(description: "\(method) failed: \(body)")
        }
        return result
    }
}
