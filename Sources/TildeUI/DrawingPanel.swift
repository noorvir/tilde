import AppKit

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
    var onEdited: () -> Void = {}
    /// The shapes or the wireframe's components changed.
    var onCanvasChanged: () -> Void = {}
    /// A text field of the canvas got the keyboard, or lost it.
    var onTyping: (Bool) -> Void = { _ in }
    var onClickAway: () -> Void = {}
    /// Add comment in the canvas's context menu.
    var onAddComment: () -> Void = {}
    /// A press, in Quartz screen coordinates. True: it was for something else, such as a label.
    var onPress: (CGPoint) -> Bool = { _ in false }
    /// The pointer moved, in Quartz screen coordinates.
    var onPointer: (CGPoint) -> Void = { _ in }
    /// A key press on the canvas, outside its text fields. True: it was taken.
    var onKey: (NSEvent) -> Bool = { _ in false }
    /// Whether a note's label, which a press opens, is at a Quartz point.
    var isOnLabel: (CGPoint) -> Bool = { _ in false }
    /// Whether one of Tilde's own windows, such as Settings, is under a Quartz point: no stroke or
    /// component starts there.
    var isOverTildeWindow: (CGPoint) -> Bool = { _ in false }
    /// Tilde's windows that the blurred screen under the wireframe's components shows.
    var underKeeps: () -> Set<CGWindowID> = { [] }
    private var look = WireframeLook.saved()
    private var lookObserver: NSObjectProtocol?

    init() {
        // A change in Settings shows at once on an open wireframe.
        lookObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lookChanged()
            }
        }
    }

    private func lookChanged() {
        let look = WireframeLook.saved()
        guard look != self.look else {
            return
        }
        self.look = look
        canvases.forEach { $0.look = look }
    }

    /// Draw has shapes that no comment has taken yet: Esc ends the group and opens its comment.
    var hasGroup: Bool {
        active?.hasGroup ?? false
    }

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
        canvas.startDrawing(tool: tool, color: color)
    }

    func stopDrawing() {
        deselect()
        active?.stopDrawing()
    }

    /// No shape is selected, so none shows its handles.
    func deselect() {
        active?.run("deselect()")
    }

    /// No tool: nothing draws until `setTool`.
    func setNoTool() {
        active?.run("setNoTool()")
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

    /// The canvas takes the keyboard, and with it the pointer's moves.
    func focus() {
        active?.focus()
    }


    /// Wireframe mode's tool and icons as JSON, or `null` to leave the mode.
    func setWireframe(_ json: String) {
        active?.wireframe = json
    }

    /// Undo and redo of the canvas's changes, in Draw and Wireframe. Saved notes are not in its
    /// history.
    func undoCanvas() {
        active?.run("undoCanvas()")
    }

    func redoCanvas() {
        active?.run("redoCanvas()")
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

    /// The window a wireframe is on, in Quartz screen coordinates; its components move with it.
    func setWireframeWindow(_ frame: CGRect) {
        guard let active else {
            return
        }
        let origin = active.frame.flipped.origin
        let values = [frame.minX - origin.x, frame.minY - origin.y, frame.width, frame.height]
        active.run("setWireframeWindow(\(Self.json(values)))")
        active.captureUnderSoon()
    }

    /// A wireframe note's shapes, as its report has them, from `origin` in Quartz screen
    /// coordinates.
    func restoreWireframe(shapes: [[String: Any]], origin: CGPoint) {
        guard let active else {
            return
        }
        let canvasOrigin = active.frame.flipped.origin
        let state: [String: Any] = ["shapes": shapes, "origin": [origin.x - canvasOrigin.x, origin.y - canvasOrigin.y]]
        active.restoredWireframe = Self.json(state)
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

    func newShapes(_ done: @escaping (Drawing?) -> Void) {
        guard let active else {
            done(nil)
            return
        }
        active.newShapes(done)
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

    private func canvas(for frame: CGRect) -> DrawingCanvas {
        if let canvas = canvases.first(where: { $0.frame == frame }) {
            return canvas
        }
        let canvas = DrawingCanvas(frame: frame, owner: self)
        canvas.look = look
        canvases.append(canvas)
        return canvas
    }

    nonisolated static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
