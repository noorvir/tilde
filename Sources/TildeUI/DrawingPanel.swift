import AppKit
import WebKit
import os

/// Drawing on the screen: a transparent canvas above the overlay. While the user draws it takes
/// the mouse; afterwards it stays visible and lets everything through.
@MainActor
final class DrawingPanel: NSObject, WKScriptMessageHandler {
    struct Drawing {
        /// As JSON, for the report.
        let shapes: String
        /// In Quartz screen coordinates.
        let bounds: CGRect
    }

    private let log = Logger(subsystem: "dev.tilde.app", category: "drawing")
    private var panel: FloatingPanel?
    private var webView: WKWebView?
    private var openedAt: Date?
    private var isReady = false
    private var isLoaded = false
    private var isPreparing = false
    private var releaseTask: Task<Void, Never>?
    private var pendingTool = "arrow"
    var onEscape: () -> Void = {}

    var windowNumber: Int? {
        panel?.windowNumber
    }

    /// Loads the canvas ahead of the first drawing, without taking time from the main thread.
    /// It stays for the next sessions, and goes after some minutes with none.
    func prepare() {
        releaseTask?.cancel()
        guard panel == nil, !isPreparing else {
            return
        }
        isPreparing = true
        Task { [weak self] in
            let page = await Task.detached(priority: .utility) { Self.page() }.value
            guard let self else {
                return
            }
            self.isPreparing = false
            if self.panel == nil, let page, let screen = NSScreen.main {
                self.load(page, into: self.makePanel(on: screen))
            }
        }
    }

    func startDrawing(on screen: NSScreen, tool: String) {
        pendingTool = tool
        let panel = self.panel ?? makePanel(on: screen)
        if !isLoaded, let page = Self.page() {
            load(page, into: panel)
        }
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.makeKey()
        if isReady {
            setTool(tool)
        }
    }

    /// The session ended: its drawings go, and the canvas waits for the next one.
    func endSession() {
        panel?.orderOut(nil)
        panel?.ignoresMouseEvents = true
        webView?.evaluateJavaScript("window.tildeDraw && window.tildeDraw.clear()")
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled {
                self?.close()
            }
        }
    }

    func stopDrawing() {
        panel?.ignoresMouseEvents = true
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        isReady = false
        isLoaded = false
    }

    func setTool(_ tool: String) {
        pendingTool = tool
        panel?.makeKey()
        webView?.evaluateJavaScript("window.tildeDraw && window.tildeDraw.setTool(\"\(tool)\")")
    }

    func undo() {
        webView?.evaluateJavaScript("window.tildeDraw && window.tildeDraw.undo()")
    }

    /// The shapes drawn since the last call, or nil when there are none.
    func takeNewShapes() async -> Drawing? {
        guard let webView, let panel,
              let text = try? await webView.evaluateJavaScript("window.tildeDraw ? window.tildeDraw.takeNewShapes() : \"\"") as? String,
              let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bounds = object["bounds"] as? [Double], bounds.count == 4,
              let shapes = object["shapes"],
              let shapesData = try? JSONSerialization.data(withJSONObject: shapes, options: [.sortedKeys])
        else {
            return nil
        }
        let origin = panel.frame.flipped.origin
        return Drawing(
            shapes: String(decoding: shapesData, as: UTF8.self),
            bounds: CGRect(x: origin.x + bounds[0], y: origin.y + bounds[1], width: bounds[2], height: bounds[3])
        )
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.body as? String {
        case "ready":
            isReady = true
            let took = openedAt.map { Date().timeIntervalSince($0) } ?? 0
            log.notice("drawing canvas ready after \(Int(took * 1000), privacy: .public) ms")
            setTool(pendingTool)
        case "escape":
            onEscape()
        case let text as String where text.hasPrefix("error: "):
            log.error("drawing canvas \(text, privacy: .public)")
        default:
            break
        }
    }

    private func load(_ page: String, into panel: FloatingPanel) {
        openedAt = Date()
        isLoaded = true
        // One document: scripts from files hide the text of their errors.
        webView?.loadHTMLString(page, baseURL: URL(string: "https://drawing.tilde.invalid/"))
    }

    nonisolated private static func page() -> String? {
        func resource(_ name: String, _ type: String) -> String? {
            Bundle.main.url(forResource: name, withExtension: type).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let html = resource("draw", "html"), let script = resource("draw", "js"), let style = resource("draw", "css") else {
            return nil
        }
        return html
            .replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"draw.css\">", with: "<style>\(style)</style>")
            .replacingOccurrences(of: "<script src=\"draw.js\"></script>", with: "<script>\(script.replacingOccurrences(of: "</script", with: "<\\/script"))</script>")
    }

    private func makePanel(on screen: NSScreen) -> FloatingPanel {
        let panel = FloatingPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: OverlayWindow.overlayLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.setFrame(screen.frame, display: false)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "tilde")
        let web = CanvasWebView(frame: panel.contentLayoutRect, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        panel.contentView = web
        self.panel = panel
        webView = web
        return panel
    }
}

/// The first drag after a click on the HUD draws, instead of only taking the keyboard back.
private final class CanvasWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
