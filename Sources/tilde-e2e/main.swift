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
        if session.url != nil {
            try await until("the session is limited to the browser window") { self.isScopedToBrowser }
            try check(isScopedToBrowser, "a session that opens a page annotates only the browser window")
            try check(controller.isPaused, "a session that opens a page starts paused, so the user can browse")
            controller.togglePause()
        }
        try await until("the page is loaded", timeout: 30) { await self.pageIsReady() }
        // On a Mac with more displays, other apps' windows can cover the page. Keep it on the
        // main display and above normal windows so hover and clicks reach it.
        if let page = NSApp.windows.first(where: { $0.windowNumber == browser.windowNumber }), let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = page.frame.size
            page.level = .floating
            page.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
            // This process runs in the background, so another app is in front.
            controller.frontmostAppChanged(to: ProcessInfo.processInfo.processIdentifier)

            // The HUD is in the browser's toolbar, and the floating one is hidden.
            try check(controller.isHUDInBrowser && hudWindow?.isVisible != true, "the browser's toolbar hosts the HUD and the floating HUD is hidden")

            // The overlay sits on the page only and follows the window with no lag.
            let overlay = try require(overlays.first, "an overlay")
            try check(overlays.count == 1 && overlay.isWindowSized, "a session on one window has one overlay on that window")
            try check(overlay.frame == browser.pageFrame && overlay.frame.maxY < page.frame.maxY - 40, "the overlay covers the page, not the toolbar")
            let moved = page.frame.offsetBy(dx: -40, dy: 30)
            let start = Date()
            page.setFrame(moved, display: true)
            try check(overlay.frame == browser.pageFrame, "the overlay follows the window in the same run loop turn, got \(overlay.frame) for \(browser.pageFrame as Any)")
            print("overlay followed the window in \(Int(Date().timeIntervalSince(start) * 1_000_000)) µs")
            page.setFrame(moved.offsetBy(dx: 40, dy: -30), display: true)

            // Another app in front pauses the session; the window's app coming back resumes it.
            controller.frontmostAppChanged(to: 1)
            try check(controller.isAutoPaused && overlay.ignoresMouseEvents, "another app in front pauses the session and lets clicks through")
            controller.frontmostAppChanged(to: ProcessInfo.processInfo.processIdentifier)
            try check(!controller.isAutoPaused && !overlay.ignoresMouseEvents, "the window's app in front again resumes the session")

            // A click in the browser, such as on its Annotate button, raises it over the
            // overlay; the overlay goes back above it, also after pause and resume.
            func overlayIsAbovePage() -> Bool {
                let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(page.windowNumber)) as? [[String: Any]] ?? []
                return above.contains { $0[kCGWindowNumber as String] as? Int == overlay.windowNumber }
            }
            page.makeKeyAndOrderFront(nil)
            try await until("the overlay goes back above the browser after a click in it", timeout: 1) { overlayIsAbovePage() }
            controller.togglePause()
            page.makeKeyAndOrderFront(nil)
            controller.togglePause()
            try await until("the overlay is above the browser after pause and resume", timeout: 1) { overlayIsAbovePage() }
            try check(overlayIsAbovePage(), "hover reaches the page after a click in the browser and after pause and resume")
        }
        await render("01-start")

        // Scrolling while annotating scrolls the page under the pointer.
        if isScopedToBrowser {
            _ = try await browser.webView.evaluateJavaScript("document.body.style.minHeight = '4000px'; window.scrollTo(0, 0)")
            let page = try require(NSApp.windows.first { $0.windowNumber == self.browser.windowNumber }, "the browser window")
            let point = CGPoint(x: page.frame.midX, y: page.frame.midY).flipped
            let event = try require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -300, wheel2: 0, wheel3: 0), "a scroll event")
            event.location = point
            let scroll = try require(NSEvent(cgEvent: event), "a scroll event")
            // The page's new height reaches WebKit's scrolling on its next frame, so scroll until it does.
            try await until("scrolling while annotating scrolls the page", timeout: 5) {
                self.controller.scroll(scroll, at: point)
                try? await Task.sleep(for: .milliseconds(100))
                return ((try? await self.browser.webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0) > 0
            }
            let scrolled = (try? await browser.webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            try check(scrolled > 0, "scrolling while annotating scrolls the page, scrollY \(scrolled)")
            _ = try await browser.webView.evaluateJavaScript("document.body.style.minHeight = ''; window.scrollTo(0, 0)")
        } else {
            throw CheckFailure(description: "the scroll check needs a session on the browser")
        }

        // Element: hover, click, comment with Return.
        let chip = try await screenRect(ofFirst: "tbody tr:nth-child(2) td:nth-child(3) .chip")
        let chipCenter = CGPoint(x: chip.midX, y: chip.midY)
        // Real pointer moves also reach the overlay, so repeat the move until the hover is the chip.
        try await until("hover finds the element") {
            self.mouse(.mouseMoved, at: chipCenter)
            try? await Task.sleep(for: .milliseconds(100))
            return self.controller.hover?.chip == "span"
        }
        try check(controller.hover?.chip == "span", "hover chip is span, got \(controller.hover?.details ?? [])")

        // Moving the browser moves the highlight with the page at once.
        if let page = NSApp.windows.first(where: { $0.windowNumber == browser.windowNumber }), let before = controller.hover?.frame {
            page.setFrameOrigin(NSPoint(x: page.frame.minX + 40, y: page.frame.minY - 30))
            let after = controller.hover?.frame
            page.setFrameOrigin(NSPoint(x: page.frame.minX - 40, y: page.frame.minY + 30))
            try check(after == before.offsetBy(dx: 40, dy: 30), "the highlight moves with the browser window, got \(after as Any) for \(before)")
        }
        await render("02-hover")

        mouse(.leftMouseDown, at: chipCenter)
        mouse(.leftMouseUp, at: chipCenter)
        try await until("the comment box opens") { self.controller.composer != nil && self.commentFieldIsFocused }
        await render("03-comment-open")
        type("Avatar and name are not vertically centered")
        await render("04-comment-typed")
        key("\r", code: 36)
        try await until("the first annotation is added") { self.controller.drafts.count == 1 }

        // Preview: opens on the draft, shows its comment, closes and gives annotate mode back.
        let first = controller.drafts[0]
        try await until("the first screenshots are captured") { self.controller.drafts.first?.annotation.image != nil }

        // The notes panel: the note is active on its page, muted on another, active again
        // after going back.
        try await until("the note is found on its page") { self.browser.anchorRects[self.controller.drafts[0].id] != nil }
        try check(browser.showsNotes, "the browser shows the notes panel")
        await captureBrowser("08-browser-notes")
        let firstPage = browser.pageURL
        browser.show(URL(string: "http://127.0.0.1:\(pagePort)/other"))
        try await until("another page loads") { self.browser.pageURL != firstPage && !self.browser.isLoading }
        try await until("the note is muted on another page") { self.browser.anchorRects.isEmpty }
        await captureBrowser("09-browser-other-page")
        browser.webView.goBack()
        try await until("the note is active again after going back") { self.browser.anchorRects[self.controller.drafts[0].id] != nil }
        try check(browser.pageURL == firstPage, "back on the first page, its note is active with a line")
        await captureBrowser("10-browser-back")

        // When the page changes under a note, its outline and line follow the element; the
        // overlay draws no second, fixed outline for it.
        let before = try require(browser.anchorRects[controller.drafts[0].id], "the note's rect")
        _ = try await browser.webView.evaluateJavaScript("document.body.style.paddingTop = '120px'")
        try await until("the note follows its element down") {
            (self.browser.anchorRects[self.controller.drafts[0].id]?.minY ?? 0) >= before.minY + 119
        }
        await captureBrowser("11-browser-page-moved")
        _ = try await browser.webView.evaluateJavaScript("document.body.style.paddingTop = ''")

        // A muted note opens its page and shows its element there.
        let note = controller.drafts[0].id
        browser.show(URL(string: "http://127.0.0.1:\(pagePort)/other"))
        try await until("another page loads again") { self.browser.pageURL != firstPage && !self.browser.isLoading }
        browser.reveal(note)
        try await until("a muted note opens its page and flashes its element", timeout: 5) {
            self.browser.pageURL == firstPage && self.browser.flashedNote == note
        }
        try check(browser.selectedNote == note, "the opened note is selected")
        controller.preview(first.id)
        try await until("the preview opens") { self.previewWindow?.isVisible == true }
        if let previewWindow {
            await renderAlone(previewWindow, "04b-preview")
            controller.expandedPreviewImage = .context
            await renderAlone(previewWindow, "04c-preview-context")
        }
        controller.closePreview()
        try check(previewWindow?.isVisible != true && controller.drafts.count == 1, "preview closes and keeps the annotation")

        // The pill keeps one width in every state.
        let annotatingWidth = hudPillWidth
        controller.togglePause()
        let pausedWidth = hudPillWidth
        controller.togglePause()
        controller.showsList = true
        if let hudWindow, hudWindow.isVisible {
            await renderAlone(hudWindow, "04d-hud-list")
        }
        controller.showsList = false
        try check(annotatingWidth == pausedWidth && annotatingWidth > 0, "HUD keeps its width when paused, got \(annotatingWidth) and \(pausedWidth)")

        // Clear all and cancel ask first, in the pill, at the same width; Cancel keeps everything.
        controller.requestClearAll()
        let confirmWidth = hudPillWidth
        if let hudWindow, hudWindow.isVisible {
            await renderAlone(hudWindow, "04e-confirm-clear")
        }
        controller.dismissConfirmation()
        controller.requestCancel()
        if let hudWindow, hudWindow.isVisible {
            await renderAlone(hudWindow, "04f-confirm-cancel")
        }
        controller.dismissConfirmation()
        try check(
            confirmWidth == annotatingWidth && controller.drafts.count == 1 && controller.phase == .annotating,
            "confirming keeps the pill width and Cancel keeps the annotation"
        )

        // The pointer over the pill is over Tilde's UI; the empty panel below the HUD is not.
        if let hudWindow, hudWindow.isVisible {
            let pill = CGPoint(x: hudWindow.frame.midX, y: hudWindow.frame.maxY - 16 - HUDMetrics.height / 2).flipped
            let below = CGPoint(x: hudWindow.frame.midX, y: hudWindow.frame.maxY - 600).flipped
            try check(controller.isOverPanel(pill) && !controller.isOverPanel(below), "the pill counts as UI and the empty panel below it does not")
        }

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
        if let hudWindow, hudWindow.isVisible {
            await renderAlone(hudWindow, "07b-hud-sent")
        }

        guard case .sent(let feedback, let folder)? = store.session(session.id)?.state else {
            throw CheckFailure(description: "session is not sent")
        }
        try check(feedback.annotations.count == 2, "two annotations sent")
        // The session is kept in the history with its notes and images.
        controller.archive.flush()
        try await until("the sent session is saved with its images", timeout: 5) {
            self.controller.archive.flush()
            guard let record = self.controller.archive.record(session.id), let note = record.notes.first else {
                return false
            }
            return record.state == .sent && record.notes.count == 2 && self.controller.archive.images(of: note, in: record.id).image != nil
        }
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
        // Without Screen Recording there are no context screenshots.
        let imageCount = feedback.annotations.flatMap { [$0.image, $0.contextImage] }.compactMap { $0 }.count
        try check(result.images.count == imageCount && imageCount >= 2, "agent receives \(imageCount) images, got \(result.images.count)")

        // The close-up is the element alone (4 pt around it) and the context is its page.
        if let closeUp = feedback.annotations[0].image.flatMap(NSBitmapImageRep.init(data:)),
           let context = feedback.annotations[0].contextImage.flatMap(NSBitmapImageRep.init(data:)),
           let page = NSApp.windows.first(where: { $0.windowNumber == browser.windowNumber })
        {
            let closeUpRatio = Double(closeUp.pixelsWide) / Double(closeUp.pixelsHigh)
            let chipRatio = (chip.width + 8) / (chip.height + 8)
            try check(abs(closeUpRatio - chipRatio) < 0.1, "close-up is the element alone, got \(closeUp.pixelsWide)×\(closeUp.pixelsHigh) for \(chip.size)")
            // In Tilde's browser, the context is the visible page, drawn by the web view.
            let contextRatio = Double(context.pixelsWide) / Double(context.pixelsHigh)
            let pageFrame = browser.pageFrame ?? page.frame
            let pageRatio = pageFrame.width / pageFrame.height
            try check(abs(contextRatio - pageRatio) < 0.05, "context is the visible page, got \(context.pixelsWide)×\(context.pixelsHigh) for \(pageFrame.size)")
        }

        // Open Browser: a session limited to the browser that ends its scope when the
        // browser closes.
        try await until("the first session is over") { self.controller.session == nil }
        controller.annotateInBrowser()
        try await until("Open Browser limits the session to the browser") { self.isScopedToBrowser }
        try check(controller.isPaused, "Open Browser starts paused")
        browser.close()
        try await until("the scope ends when the browser closes", timeout: 5) { self.controller.scope == nil }
        try check(controller.notice == "Window closed", "the HUD says the window closed")
        controller.cancel()
    }

    private var isScopedToBrowser: Bool {
        controller.scope != nil && controller.scope?.number == browser.windowNumber
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

    /// Fitting width of the HUD's pill, measured on a fresh view so no animation is involved.
    private var hudPillWidth: CGFloat {
        let view = NSHostingView(rootView: HUDView(controller: controller))
        return view.fittingSize.width
    }

    private var previewWindow: NSWindow? {
        NSApp.windows.first { $0.contentView is NSHostingView<PreviewView> }
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
    /// The browser window as it is on screen (needs Screen Recording), into build/e2e.
    private func captureBrowser(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(400))
        guard let window = browser.window, let data = await SettingsCapture.png(of: window) else {
            return
        }
        try? data.write(to: outputFolder.appendingPathComponent("\(name).png"))
    }

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

    /// Renders one window by itself into a PNG of its size.
    private func renderAlone(_ window: NSWindow, _ name: String) async {
        try? await Task.sleep(for: .milliseconds(250))
        let size = window.frame.size
        let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        canvas.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSColor(white: 0.55, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.current?.cgContext.translateBy(x: -window.frame.minX, y: -window.frame.minY)
        draw(window, rounded: false)
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
