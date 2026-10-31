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
    private var pendingTool = "arrow"
    var onEscape: () -> Void = {}

    var windowNumber: Int? {
        panel?.windowNumber
    }

    func startDrawing(on screen: NSScreen, tool: String) {
        pendingTool = tool
        let panel = self.panel ?? makePanel(on: screen)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.makeKey()
        if isReady {
            setTool(tool)
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
    }

    func setTool(_ tool: String) {
        pendingTool = tool
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
        default:
            break
        }
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
        let web = WKWebView(frame: panel.contentLayoutRect, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        panel.contentView = web
        if let page = Bundle.main.url(forResource: "draw", withExtension: "html") {
            openedAt = Date()
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            log.error("the drawing canvas is not in the app")
        }
        self.panel = panel
        webView = web
        return panel
    }
}
