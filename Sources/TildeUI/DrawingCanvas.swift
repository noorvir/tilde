import AppKit
import WebKit
import os

/// The canvas of one screen. It tells its panel what happens on its page.
@MainActor
final class DrawingCanvas: NSObject, WKScriptMessageHandler {
    private let log = Logger(subsystem: "dev.tilde.app", category: "drawing")
    let frame: CGRect
    private weak var owner: DrawingPanel?
    private var panel: FloatingPanel?
    private var webView: WKWebView?
    private var underBlur: UnderBlurView?
    private var underCapture: Task<Void, Never>?
    private var openedAt: Date?
    private var isReady = false
    private var isLoaded = false
    private var isPreparing = false
    private var pendingTool = "arrow"
    private var pendingColor: String?
    private let passThrough = PointerPassThrough()
    /// The page has no tool, and takes a press only on what it shows, such as a component.
    private var hasNoTool = false {
        didSet {
            passThrough.update()
        }
    }
    var wireframe = "null" {
        didSet {
            run("setWireframe(\(wireframe))")
        }
    }
    /// A wireframe note's components to show again once the page is ready.
    var restoredWireframe: String? {
        didSet {
            if isReady, let restoredWireframe {
                run("restoreWireframe(\(restoredWireframe))")
                self.restoredWireframe = nil
            }
        }
    }
    var look = WireframeLook() {
        didSet {
            applyLook()
        }
    }

    init(frame: CGRect, owner: DrawingPanel) {
        self.frame = frame
        self.owner = owner
        super.init()
        passThrough.takesPointer = { [weak self] point in
            await self?.takesPointer(at: point) ?? false
        }
        passThrough.onWentThrough = { [weak self] isPress in
            self?.run("pointerWentThrough(\(isPress))")
        }
    }

    /// Draw has shapes that no comment has taken yet.
    private(set) var hasGroup = false

    var windowNumber: Int? {
        panel?.windowNumber
    }

    func prepare() {
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
            if self.panel == nil, let page {
                self.makePanel()
                self.load(page)
            }
        }
    }

    func startDrawing(tool: String, color: String) {
        pendingTool = tool
        pendingColor = color
        if panel == nil {
            makePanel()
        }
        if !isLoaded, let page = Self.page() {
            load(page)
        }
        passThrough.isActive = true
        panel?.orderFrontRegardless()
        panel?.makeKey()
        if isReady {
            setTool(tool)
            setColor(color)
        }
        captureUnder()
    }

    func stopDrawing() {
        passThrough.isActive = false
    }

    func hide() {
        passThrough.isActive = false
        panel?.orderOut(nil)
        underBlur?.forget()
    }

    func focus() {
        panel?.makeKey()
    }

    func resumeDrawing() {
        passThrough.isActive = true
        panel?.makeKey()
        captureUnder()
    }

    func setSnapFrame(_ frame: CGRect?) {
        guard let frame else {
            run("setSnapFrame(null)")
            return
        }
        let origin = self.frame.flipped.origin
        run("setSnapFrame([\(frame.minX - origin.x), \(frame.minY - origin.y), \(frame.width), \(frame.height)])")
    }

    func shapes(_ ids: [String]) async -> [[String: Any]] {
        guard let webView, !ids.isEmpty,
              let text = try? await webView.evaluateJavaScript("window.tildeDraw ? window.tildeDraw.shapesOf(\(DrawingPanel.json(ids))) : \"\"") as? String,
              let shapes = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]]
        else {
            return []
        }
        let origin = frame.flipped.origin
        return shapes.map { DrawingShapes.moved($0, by: CGVector(dx: origin.x, dy: origin.y)) }
    }

    func reset() {
        panel?.orderOut(nil)
        passThrough.isActive = false
        run("clear()")
        underBlur?.forget()
    }

    func close() {
        passThrough.isActive = false
        hasNoTool = false
        panel?.orderOut(nil)
        panel = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        underBlur = nil
        isReady = false
        isLoaded = false
        hasGroup = false
    }

    func setTool(_ tool: String) {
        pendingTool = tool
        panel?.makeKey()
        run("setTool(\"\(tool)\")")
    }

    func setColor(_ color: String) {
        pendingColor = color
        panel?.makeKey()
        run("setColor(\"\(color)\")")
    }

    func run(_ call: String) {
        webView?.evaluateJavaScript("window.tildeDraw && window.tildeDraw.\(call); 0")
    }

    func takeNewShapes() async -> DrawingPanel.Drawing? {
        guard let webView,
              let text = try? await webView.evaluateJavaScript("window.tildeDraw ? window.tildeDraw.takeNewShapes() : \"\"") as? String,
              let shapes = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]]
        else {
            return nil
        }
        let origin = frame.flipped.origin
        let moved = shapes.map { DrawingShapes.moved($0, by: CGVector(dx: origin.x, dy: origin.y)) }
        return DrawingPanel.Drawing(
            shapes: moved, ids: shapes.compactMap { $0["id"] as? String }, bounds: DrawingShapes.bounds(of: moved)
        )
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else {
            return
        }
        switch text {
        case "ready":
            isReady = true
            let took = openedAt.map { Date().timeIntervalSince($0) } ?? 0
            log.notice("drawing canvas ready after \(Int(took * 1000), privacy: .public) ms")
            setTool(pendingTool)
            if let pendingColor {
                setColor(pendingColor)
            }
            run("setWireframe(\(wireframe))")
            applyLook()
            if let restoredWireframe {
                run("restoreWireframe(\(restoredWireframe))")
                self.restoredWireframe = nil
            }
        case "escape":
            owner?.onEscape()
        case "group", "noGroup":
            hasGroup = text == "group"
        case "edited":
            owner?.onEdited()
        case "clickAway":
            owner?.onClickAway()
        case "typing", "notTyping":
            (panel as? CanvasPanel)?.isTyping = text == "typing"
            owner?.onTyping(text == "typing")
        case "noTool", "tool":
            hasNoTool = text == "noTool"
        case _ where text.hasPrefix("pointer:"):
            let values = text.dropFirst(8).split(separator: ",").compactMap { Double($0) }
            if values.count == 2 {
                let origin = frame.flipped.origin
                owner?.onPointer(CGPoint(x: origin.x + values[0], y: origin.y + values[1]))
            }
        case _ where text.hasPrefix("under:"):
            underChanged(text.dropFirst("under:".count))
        case _ where text.hasPrefix("error: "):
            log.error("drawing canvas \(text, privacy: .public)")
        default:
            break
        }
    }

    /// Whether a press at a Quartz point is for the canvas: never over one of Tilde's own
    /// windows; else with a tool every press, and with none a press on a note's label or on what
    /// the page takes a press on.
    private func takesPointer(at point: CGPoint) async -> Bool {
        if owner?.isOverTildeWindow(point) == true {
            return false
        }
        if !hasNoTool || owner?.isOnLabel(point) == true {
            return true
        }
        guard let webView else {
            return false
        }
        let origin = frame.flipped.origin
        let call = "window.tildeDraw ? window.tildeDraw.takesPointer(\(point.x - origin.x), \(point.y - origin.y)) : true"
        return (try? await webView.evaluateJavaScript(call) as? Bool) ?? true
    }

    // MARK: - The look and the blur under the components

    /// A new radius blurs the same picture again; a blur that was off needs a picture.
    private func applyLook() {
        run("setWireframeLook(\(look.pageJSON))")
        underBlur?.radius = look.blur
        if underBlur?.picture == nil {
            captureUnder()
        }
    }

    /// The page's components moved, came or went: the blur follows their shapes. The first
    /// ones take a picture of the screen under the canvas.
    private func underChanged(_ json: Substring) {
        guard let underBlur, let values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[Double]] else {
            return
        }
        underBlur.shapes = values.filter { $0.count == 5 }.map {
            UnderBlurView.Shape(rect: CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]), isEllipse: $0[4] == 1)
        }
        if underBlur.shapes.isEmpty {
            underBlur.forget()
        } else if underBlur.picture == nil {
            captureUnder()
        }
    }

    /// A new picture of the screen under the canvas, when the blur shows: one capture, without
    /// Tilde's windows, which the shapes then only mask.
    private func captureUnder() {
        guard let underBlur, look.blur > 0, !underBlur.shapes.isEmpty, panel?.isVisible == true else {
            return
        }
        underCapture?.cancel()
        let keeps = owner?.underKeeps() ?? []
        underCapture = Task { [weak self, frame] in
            let capture = await ScreenCapture.image(of: frame.flipped, keeping: keeps)
            guard let self, !Task.isCancelled, let capture else {
                return
            }
            self.underBlur?.show(capture.image)
        }
    }

    /// The screen under the canvas changed, such as a window that moved: a new picture once it
    /// has rested for a moment.
    func captureUnderSoon() {
        underCapture?.cancel()
        underCapture = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled {
                self?.captureUnder()
            }
        }
    }

    private func load(_ page: String) {
        openedAt = Date()
        isLoaded = true
        // One document: scripts from files hide the text of their errors.
        webView?.loadHTMLString(page, baseURL: URL(string: "https://drawing.tilde.invalid/"))
    }

    /// The canvas's page as one document, from the files in `folder`: the app's resources.
    nonisolated static func page(in folder: URL? = Bundle.main.resourceURL) -> String? {
        func resource(_ name: String) -> String? {
            folder.flatMap { try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) }
        }
        guard let html = resource("draw.html"), let script = resource("draw.js"), let style = resource("draw.css") else {
            return nil
        }
        return html
            .replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"draw.css\">", with: "<style>\(style)</style>")
            .replacingOccurrences(of: "<script src=\"draw.js\"></script>", with: "<script>\(script.replacingOccurrences(of: "</script", with: "<\\/script"))</script>")
    }

    private func makePanel() {
        let panel = CanvasPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: OverlayWindow.overlayLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.setFrame(frame, display: false)
        passThrough.window = panel
        panel.onPress = { [weak self] in self?.owner?.onPress($0) ?? false }
        panel.onKey = { [weak self] in self?.owner?.onKey($0) ?? false }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "tilde")
        let web = CanvasWebView(frame: panel.contentLayoutRect, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        // The blurred screen under the components, under the page.
        let blur = UnderBlurView(frame: panel.contentLayoutRect)
        blur.autoresizingMask = [.width, .height]
        blur.radius = look.blur
        let content = NSView(frame: panel.contentLayoutRect)
        content.addSubview(blur)
        content.addSubview(web)
        panel.contentView = content
        panel.initialFirstResponder = web
        panel.makeFirstResponder(web)
        self.panel = panel
        webView = web
        underBlur = blur
    }
}

/// Excalidraw ignores a press on a page without focus, so a press first gives the canvas the
/// keyboard, and reaches the page once the page has focus. The comment box gets the keyboard
/// back when the press ends.
private final class CanvasPanel: FloatingPanel {
    var onPress: (CGPoint) -> Bool = { _ in false }
    /// Tilde's keys come before the page's, unless a text field on the page has the keyboard.
    var onKey: (NSEvent) -> Bool = { _ in false }
    var isTyping = false
    private var heldEvents: [NSEvent]?
    private var isPressTaken = false

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !isTyping, onKey(event) {
            return
        }
        if isPressTaken {
            isPressTaken = event.type != .leftMouseUp
            return
        }
        if event.type == .leftMouseDown, onPress(NSEvent.mouseLocation.flipped) {
            isPressTaken = true
            return
        }
        if heldEvents != nil {
            heldEvents?.append(event)
            return
        }
        guard event.type == .leftMouseDown, !isKeyWindow else {
            super.sendEvent(event)
            return
        }
        makeKey()
        heldEvents = [event]
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.sendHeldEvents()
        }
    }

    private func sendHeldEvents() {
        let events = heldEvents ?? []
        heldEvents = nil
        for event in events {
            super.sendEvent(event)
        }
    }
}

/// The first drag after a click on the HUD draws, instead of only taking the keyboard back.
private final class CanvasWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
