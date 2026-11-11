import AppKit
import TildeCore
import WebKit
import os

/// Drawing on the screen: a transparent canvas above the overlay, one for each screen drawn on.
/// A shape is on it only while its comment is open; the note that remains is a label on an element.
@MainActor
final class DrawingPanel {
    struct Drawing {
        /// In points from the top left of the screen of its canvas.
        let shapes: [[String: Any]]
        let ids: [String]
        /// In Quartz screen coordinates.
        let bounds: CGRect
    }

    /// One for each screen frame drawn on.
    private var canvases: [DrawingCanvas] = []
    private var active: DrawingCanvas?
    private var color = "#2F76FF"
    private var releaseTask: Task<Void, Never>?
    private var isOverLabel = false
    var onEscape: () -> Void = {}
    var onShape: () -> Void = {}
    var onEdited: () -> Void = {}
    var onClickAway: () -> Void = {}
    /// A press, in Quartz screen coordinates. True: it was for something else, such as a label.
    var onPress: (CGPoint) -> Bool = { _ in false }
    /// The pointer moved, in Quartz screen coordinates.
    var onPointer: (CGPoint) -> Void = { _ in }
    /// A key press on the canvas, outside its text fields. True: it was taken.
    var onKey: (NSEvent) -> Bool = { _ in false }

    /// Windows Tilde must keep in a screenshot of what was drawn.
    var windowNumbers: [Int] {
        canvases.compactMap(\.windowNumber)
    }

    /// Loads a canvas ahead of the first drawing, without taking time from the main thread.
    /// It stays for the next sessions, and goes after some minutes with none.
    func prepare() {
        releaseTask?.cancel()
        if let screen = NSScreen.main {
            canvas(for: screen.frame).prepare()
        }
    }

    func startDrawing(on screen: NSScreen, tool: String) {
        let canvas = canvas(for: screen.frame)
        active = canvas
        canvas.onEscape = { [weak self] in self?.onEscape() }
        canvas.onShape = { [weak self] in self?.onShape() }
        canvas.onEdited = { [weak self] in self?.onEdited() }
        canvas.onClickAway = { [weak self] in self?.onClickAway() }
        canvas.onPress = { [weak self] in self?.onPress($0) ?? false }
        canvas.onPointer = { [weak self] in self?.onPointer($0) }
        canvas.onKey = { [weak self] in self?.onKey($0) ?? false }
        canvas.startDrawing(tool: tool, color: color)
    }

    func stopDrawing() {
        active?.run("deselect()")
        active?.stopDrawing()
    }

    func setTool(_ tool: String) {
        active?.setTool(tool)
    }

    func setColor(_ color: String) {
        self.color = color
        active?.setColor(color)
    }

    /// While the comment of a shape is open, the canvas edits that shape and draws nothing new.
    func editShapes(_ ids: [String]) {
        active?.run("editShapes(\(Self.json(ids)))")
    }

    func endEditing() {
        active?.run("endEditing()")
    }

    /// The hand cursor over a note's label, which a press opens.
    func setOverLabel(_ isOverLabel: Bool) {
        guard isOverLabel != self.isOverLabel else {
            return
        }
        self.isOverLabel = isOverLabel
        active?.run("setOverLabel(\(isOverLabel))")
    }

    func resumeDrawing() {
        active?.resumeDrawing()
    }

    /// The element to snap to, in Quartz screen coordinates.
    func setSnapFrame(_ frame: CGRect?) {
        active?.setSnapFrame(frame)
    }

    /// Wireframe mode's tool and fill as JSON, or `null` to leave it.
    func setWireframe(_ json: String) {
        active?.wireframe = json
    }

    func runWireframe(_ call: String) {
        active?.run(call)
    }

    /// Lines for wireframe shapes to snap to, in Quartz screen coordinates.
    func setSnapTargets(rects: [CGRect], containers: [CGRect], window: CGRect?, screen: CGRect?) {
        guard let active else {
            return
        }
        let origin = active.frame.flipped.origin
        func values(_ rect: CGRect) -> [Double] {
            [rect.minX - origin.x, rect.minY - origin.y, rect.width, rect.height]
        }
        let targets: [String: Any] = [
            "rects": rects.map(values), "containers": containers.map(values),
            "window": window.map(values) ?? NSNull(), "screen": screen.map(values) ?? NSNull(),
        ]
        active.run("setSnapTargets(\(Self.json(targets)))")
    }

    /// The shapes with these ids, wherever they are.
    func shapes(_ ids: [String]) async -> [[String: Any]] {
        for canvas in canvases {
            let shapes = await canvas.shapes(ids)
            if !shapes.isEmpty {
                return shapes
            }
        }
        return []
    }

    func takeNewShapes() async -> Drawing? {
        await active?.takeNewShapes()
    }

    func remove(_ ids: [String]) {
        active?.run("remove(\(Self.json(ids)))")
    }

    /// Off the screen, nothing can take the mouse or a scroll from the apps below.
    func hide() {
        active?.hide()
    }

    /// The session ended: its drawings go, and the canvases wait for the next one.
    func endSession() {
        active = nil
        canvases.forEach { $0.reset() }
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled {
                self?.canvases.forEach { $0.close() }
                self?.canvases = []
            }
        }
    }

    func clear() {
        canvases.forEach { $0.run("clear()") }
    }

    private func canvas(for frame: CGRect) -> DrawingCanvas {
        if let canvas = canvases.first(where: { $0.frame == frame }) {
            return canvas
        }
        let canvas = DrawingCanvas(frame: frame)
        canvases.append(canvas)
        return canvas
    }

    nonisolated static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

/// The canvas of one screen.
@MainActor
final class DrawingCanvas: NSObject, WKScriptMessageHandler {
    private let log = Logger(subsystem: "dev.tilde.app", category: "drawing")
    let frame: CGRect
    private var panel: FloatingPanel?
    private var webView: WKWebView?
    private var openedAt: Date?
    private var isReady = false
    private var isLoaded = false
    private var isPreparing = false
    private var pendingTool = "arrow"
    private var pendingColor: String?
    var wireframe = "null" {
        didSet {
            run("setWireframe(\(wireframe))")
        }
    }
    var onEscape: () -> Void = {}
    var onShape: () -> Void = {}
    var onEdited: () -> Void = {}
    var onClickAway: () -> Void = {}
    var onPress: (CGPoint) -> Bool = { _ in false }
    var onPointer: (CGPoint) -> Void = { _ in }
    var onKey: (NSEvent) -> Bool = { _ in false }

    init(frame: CGRect) {
        self.frame = frame
    }

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
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()
        panel?.makeKey()
        if isReady {
            setTool(tool)
            setColor(color)
        }
    }

    func stopDrawing() {
        panel?.ignoresMouseEvents = true
    }

    func hide() {
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    func resumeDrawing() {
        panel?.ignoresMouseEvents = false
        panel?.makeKey()
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
        panel?.ignoresMouseEvents = true
        run("clear()")
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
        case "escape":
            onEscape()
        case "shape":
            onShape()
        case "edited":
            onEdited()
        case "clickAway":
            onClickAway()
        case "typing", "notTyping":
            (panel as? CanvasPanel)?.isTyping = text == "typing"
        case _ where text.hasPrefix("pointer:"):
            let values = text.dropFirst(8).split(separator: ",").compactMap { Double($0) }
            if values.count == 2 {
                let origin = frame.flipped.origin
                onPointer(CGPoint(x: origin.x + values[0], y: origin.y + values[1]))
            }
        case _ where text.hasPrefix("error: "):
            log.error("drawing canvas \(text, privacy: .public)")
        default:
            break
        }
    }

    private func load(_ page: String) {
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
        panel.onPress = { [weak self] in self?.onPress($0) ?? false }
        panel.onKey = { [weak self] in self?.onKey($0) ?? false }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "tilde")
        let web = CanvasWebView(frame: panel.contentLayoutRect, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        panel.contentView = web
        self.panel = panel
        webView = web
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

/// Shapes as data: what the report says, and what a restore draws again.
enum DrawingShapes {
    static func moved(_ shape: [String: Any], by offset: CGVector) -> [String: Any] {
        var shape = shape
        func point(_ value: Any?) -> [Double]? {
            guard let values = value as? [NSNumber], values.count >= 2 else {
                return nil
            }
            return [values[0].doubleValue + offset.dx, values[1].doubleValue + offset.dy]
        }
        if let rect = shape["rect"] as? [NSNumber], rect.count == 4 {
            shape["rect"] = [rect[0].doubleValue + offset.dx, rect[1].doubleValue + offset.dy, rect[2].doubleValue, rect[3].doubleValue]
        }
        for key in ["from", "to"] {
            if let moved = point(shape[key]) {
                shape[key] = moved
            }
        }
        if let points = shape["points"] as? [Any] {
            shape["points"] = points.compactMap(point)
        }
        return shape
    }

    /// Where an arrow's tip is, or else the centre of the shapes: what they are linked to is there.
    static func linkPoint(of shapes: [[String: Any]]) -> CGPoint {
        if shapes.count == 1, let tip = doubles(shapes[0]["to"]), tip.count == 2, let tail = doubles(shapes[0]["from"]), tail.count == 2 {
            // A little back along the arrow: a tip snapped to an edge is on the element's border.
            let length = max(hypot(tip[0] - tail[0], tip[1] - tail[1]), 1)
            let back = min(2, length)
            return CGPoint(x: tip[0] + (tail[0] - tip[0]) / length * back, y: tip[1] + (tail[1] - tip[1]) / length * back)
        }
        let bounds = bounds(of: shapes)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// The origin of `encode`.
    static func origin(of text: String) -> CGPoint {
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        guard let origin = object?["origin"] as? [NSNumber], origin.count == 2 else {
            return .zero
        }
        return CGPoint(x: origin[0].doubleValue, y: origin[1].doubleValue)
    }

    static func bounds(of shapes: [[String: Any]]) -> CGRect {
        var points: [[Double]] = []
        for shape in shapes {
            if let rect = doubles(shape["rect"]), rect.count == 4 {
                points += [[rect[0], rect[1]], [rect[0] + rect[2], rect[1] + rect[3]]]
            }
            for key in ["from", "to"] {
                if let point = doubles(shape[key]) {
                    points.append(point)
                }
            }
            for point in (shape["points"] as? [Any]) ?? [] {
                if let point = doubles(point) {
                    points.append(point)
                }
            }
        }
        guard let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
              let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max()
        else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func doubles(_ value: Any?) -> [Double]? {
        (value as? [NSNumber])?.map(\.doubleValue)
    }

    /// For the report: the shapes relative to `origin`, which is the top left of their window,
    /// or of the screen, and the element they are linked to.
    static func encode(_ shapes: [[String: Any]], origin: CGPoint, element: Element?) -> String {
        let relative = shapes.map { shape -> [String: Any] in
            var moved = Self.moved(shape, by: CGVector(dx: -origin.x, dy: -origin.y))
            moved["id"] = nil
            return moved
        }
        var report: [String: Any] = ["origin": [origin.x, origin.y], "shapes": relative]
        if let data = try? JSONEncoder().encode(element), let object = try? JSONSerialization.jsonObject(with: data), element != nil {
            report["element"] = object
        }
        return DrawingPanel.json(report)
    }
}
