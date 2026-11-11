import AppKit
import ApplicationServices
import SwiftUI
import TildeCore

/// Wireframe mode: skeletons of components drawn over the screen in the drawing canvas, each
/// with an optional label, sent together as one note with the screen under them.
struct Wireframe: Equatable {
    var tool = "card"
    /// The window of the first press: the components keep their place on it when it moves.
    var window: ElementPicker.WindowInfo?
    /// The note being edited again: Done updates it instead of making a new one.
    var note: Draft.ID?

    /// Card, Rectangle and Circle stand in for any component not in the list.
    static let tools = [
        (tool: "section", symbol: "rectangle.split.3x1", key: "s", help: "Section"),
        (tool: "card", symbol: "square.text.square", key: "c", help: "Card"),
        (tool: "table", symbol: "tablecells", key: "t", help: "Table"),
        (tool: "button", symbol: "capsule", key: "b", help: "Button"),
        (tool: "dropdown", symbol: "chevron.down.square", key: "d", help: "Dropdown"),
        (tool: "list", symbol: "list.bullet.rectangle", key: "l", help: "List"),
        (tool: "rectangle", symbol: "rectangle", key: "r", help: "Rectangle"),
        (tool: "ellipse", symbol: "circle", key: "o", help: "Circle"),
    ]

    var style = Style()

    var json: String {
        DrawingPanel.json(["tool": tool])
    }

    /// The Style menu's rows: corner radius and shadow, of the selected component, or else of
    /// the components drawn next.
    struct Style: Equatable {
        var radius = "medium"
        var shadow = "none"
        var isSelection = false

        static let rows = [
            (key: "radius", title: "Corner Radius", options: [("none", "None"), ("small", "Small"), ("medium", "Medium"), ("large", "Large")]),
            (key: "shadow", title: "Shadow", options: [("none", "None"), ("small", "Small"), ("medium", "Medium"), ("large", "Large")]),
        ]

        init() {}

        /// From the canvas's JSON.
        init(json: String) {
            let values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            radius = values["radius"] as? String ?? radius
            shadow = values["shadow"] as? String ?? shadow
            isSelection = values["isSelection"] as? Bool ?? false
        }

        func value(of key: String) -> String {
            key == "radius" ? radius : shadow
        }
    }

    /// The edges of the element at a point, of its containers up to the window, and of their
    /// children: the layout lines a wireframe snaps to. `containers` are the larger ancestors,
    /// innermost first, whose thirds and halves it snaps to as well.
    nonisolated static func layout(at point: CGPoint, pid: pid_t) -> (rects: [CGRect], containers: [CGRect]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var current = hit else {
            return ([], [])
        }

        var rects: [CGRect] = []
        var containers: [CGRect] = []
        for _ in 0..<12 {
            guard let (role, frame) = roleAndFrame(of: current), role != kAXWindowRole, role != kAXApplicationRole else {
                break
            }
            rects.append(frame)
            if frame.width >= 120, frame.height >= 80, containers.count < 2 {
                containers.append(frame)
            }
            var children: CFTypeRef?
            if rects.count < 300, AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                rects += children.prefix(60).compactMap { roleAndFrame(of: $0)?.frame }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else {
                break
            }
            current = parent as! AXUIElement
        }
        return (rects.filter { $0.width >= 4 && $0.height >= 4 }, containers)
    }

    nonisolated private static func roleAndFrame(of element: AXUIElement) -> (role: String, frame: CGRect)? {
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let values = values as? [Any], values.count == 3,
              let role = values[0] as? String
        else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let position = values[1] as CFTypeRef
        let length = values[2] as CFTypeRef
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(length) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(length as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return (role, CGRect(origin: origin, size: size))
    }
}

extension AnnotationController {
    /// Starts wireframe mode, or switches Draw to it.
    func startWireframe() {
        if !isDrawing {
            dispatch(.startDrawing)
        }
        guard isDrawing else {
            return
        }
        drawingPanel.setSnapFrame(nil)
        hover = nil
        drawingPanel.onWireframeStyle = { [weak self] json in
            self?.wireframe?.style = Wireframe.Style(json: json)
        }
        let next = Wireframe()
        wireframe = next
        drawingPanel.setWireframe(next.json)
        _ = focusWireframeCanvas()
    }

    /// In wireframe mode the canvas, not the overlay, takes the keyboard and so the pointer's
    /// moves: the cursor ring shows at once, and the screen behind shows no hover highlight.
    func focusWireframeCanvas() -> Bool {
        guard wireframe != nil else {
            return false
        }
        drawingPanel.focus()
        return true
    }

    func setWireframeTool(_ tool: String) {
        wireframe?.tool = tool
        drawingPanel.setWireframe(wireframe?.json ?? "null")
        _ = focusWireframeCanvas()
    }

    func setWireframeStyle(_ key: String, to value: String) {
        drawingPanel.runWireframe("setStyle(\(DrawingPanel.json([key: value])))")
    }

    func undoWireframe() {
        drawingPanel.runWireframe("undoWireframe()")
    }

    func redoWireframe() {
        drawingPanel.runWireframe("redoWireframe()")
    }

    /// Leaves wireframe mode: its shapes not sent yet go. Drawing ends as it does for Draw.
    func endWireframe() {
        guard wireframe != nil else {
            return
        }
        wireframe = nil
        drawingPanel.setWireframe("null")
    }

    /// Done: what was drawn becomes one note, with the screen as it is with the wireframe on it
    /// and as it is under it. Nothing drawn: wireframe mode only ends.
    func finishWireframe() {
        Task {
            await openWireframeComment()
            dispatch(.finishDrawing)
        }
    }

    /// The keys of wireframe mode: W starts it, also from Draw; in it, its tools, and
    /// no other letter or digit, as Draw's tools would change the canvas behind the HUD.
    func performWireframeShortcut(_ event: NSEvent) -> Bool {
        guard session != nil, confirmation == nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1, key != " "
        else {
            return false
        }
        guard wireframe != nil else {
            if key == "w", !isRecordMode {
                if !event.isARepeat {
                    startWireframe()
                }
                return true
            }
            return false
        }
        if let tool = Wireframe.tools.first(where: { $0.key == key }) {
            setWireframeTool(tool.tool)
        }
        return key.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private func openWireframeComment() async {
        guard let drawing = await drawingPanel.takeNewShapes(), !drawing.ids.isEmpty else {
            return
        }
        // The pictures show the wireframe without the handles of a selected shape.
        drawingPanel.runWireframe("deselect()")
        try? await Task.sleep(for: .milliseconds(100))
        let bounds = drawing.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let chosen = wireframe?.window.flatMap { picker.currentWindow(number: $0.number) }
        let window = chosen ?? scope ?? picker.window(at: center)
        let screen = NSScreen.screens.first { $0.frame.flipped.contains(center) }?.frame.flipped ?? bounds
        // The wireframe's window; else the window when the wireframe is in it, else the whole screen.
        let area = chosen?.frame ?? window.map(\.frame).flatMap { Self.isMostlyInside(bounds, $0) ? $0 : nil } ?? screen

        let canvas = Set(drawingPanel.windowNumbers.map { CGWindowID($0) })
        let page = Set(browser.windowNumber.map { [CGWindowID($0)] } ?? [])
        async let drawn = ScreenCapture.png(of: area, outline: nil, keeping: canvas.union(page), maxSide: 2048)
        async let under = ScreenCapture.png(of: area, outline: nil, keeping: page, maxSide: 2048)
        let captures = await Captures(image: drawn, contextImage: under)

        var shapes = (try? JSONSerialization.jsonObject(with: Data(DrawingShapes.encode(drawing.shapes, origin: area.origin, element: nil).utf8))) as? [String: Any] ?? [:]
        shapes["wireframe"] = "A wireframe of the change: the image shows it drawn over the screen, the context image the screen under it."
        shapes["originIs"] = chosen == nil ? "screen" : "window"
        let target = Target.drawing(shapes: DrawingPanel.json(shapes))
        if let note = wireframe?.note {
            updateWireframeNote(note, target: target, frame: bounds, window: window, captures: captures)
            drawingPanel.remove(drawing.ids)
            return
        }
        openComposer(
            target: target, frame: bounds, marker: CGPoint(x: bounds.maxX, y: bounds.minY),
            chip: "Wireframe", outline: nil, window: window, captures: captures, drawingIDs: drawing.ids
        )
    }

    /// The first press in wireframe mode chooses its window, which the components then follow
    /// while it moves, until wireframe mode ends.
    func chooseWireframeWindow(at point: CGPoint) {
        guard wireframe != nil, wireframe?.window == nil, let window = picker.window(at: point, in: scope) else {
            return
        }
        followWireframeWindow(window)
    }

    private func followWireframeWindow(_ window: ElementPicker.WindowInfo) {
        wireframe?.window = window
        drawingPanel.setWireframeWindow(window.frame)
        Task {
            while let current = wireframe?.window, current.number == window.number {
                try? await Task.sleep(for: .milliseconds(33))
                guard let now = picker.currentWindow(number: window.number), wireframe?.window?.number == window.number,
                      now.frame != wireframe?.window?.frame
                else {
                    continue
                }
                wireframe?.window = now
                drawingPanel.setWireframeWindow(now.frame)
            }
        }
    }

    /// Shows a wireframe note's components again, on its window where it was on one, to edit
    /// them: Done then updates that note, with new pictures, and keeps its comment.
    func editWireframe(_ id: Draft.ID) {
        guard wireframe == nil, let draft = drafts.first(where: { $0.id == id }), case .drawing(let json) = draft.annotation.target,
              let saved = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], saved["wireframe"] != nil,
              let shapes = saved["shapes"] as? [[String: Any]], let origin = saved["origin"] as? [Double], origin.count == 2
        else {
            return
        }
        closePreview()
        startWireframe()
        guard wireframe != nil else {
            return
        }
        wireframe?.note = id
        // Shapes on a window are from its top left, which may have moved since.
        let window = saved["originIs"] as? String == "window" ? draft.sourceWindow.flatMap { picker.currentWindow(number: $0) } : nil
        drawingPanel.restoreWireframe(shapes: shapes, origin: window?.frame.origin ?? CGPoint(x: origin[0], y: origin[1]))
        if let window {
            followWireframeWindow(window)
        }
    }

    private func updateWireframeNote(_ id: Draft.ID, target: Target, frame: CGRect, window: ElementPicker.WindowInfo?, captures: Captures) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else {
            return
        }
        let old = drafts[index]
        let annotation = Annotation(
            id: old.id, comment: old.annotation.comment, target: target, frame: frame, image: captures.image, contextImage: captures.contextImage
        )
        var fingerprint = old.fingerprint
        if let window {
            fingerprint = Task { await NoteFingerprint.capture(window: CGWindowID(window.number), area: frame) }
        }
        drafts[index] = Draft(
            annotation: annotation, marker: CGPoint(x: frame.maxX, y: frame.minY), chip: old.chip, capture: Task { captures }, anchor: old.anchor,
            sourceWindow: window?.number ?? old.sourceWindow, fingerprint: fingerprint, page: old.page, sourcePID: window?.pid ?? old.sourcePID,
            pictureArea: old.pictureArea
        )
    }

    /// The lines under the pointer to snap to, from Accessibility; in Tilde's browser, the
    /// element the page reports.
    func findWireframeSnaps(at point: CGPoint) {
        guard !isFindingSnapFrame else {
            return
        }
        isFindingSnapFrame = true
        let window = wireframe?.window ?? scope ?? picker.window(at: point)
        let screen = NSScreen.screens.first { $0.frame.flipped.contains(point) }?.frame.flipped
        let isOwn = window?.number == browser.windowNumber || window?.pid == ProcessInfo.processInfo.processIdentifier
        Task {
            var layout: (rects: [CGRect], containers: [CGRect]) = ([], [])
            if isOwn {
                if let picked = await picker.pick(at: point, isMoving: true, in: scope) {
                    layout.rects = [picked.frame]
                }
            } else if let pid = window?.pid, AXIsProcessTrusted() {
                layout = await Task.detached(priority: .userInitiated) { Wireframe.layout(at: point, pid: pid) }.value
            }
            isFindingSnapFrame = false
            if wireframe != nil {
                drawingPanel.setSnapTargets(rects: layout.rects, containers: layout.containers, window: window?.frame, screen: screen)
            }
        }
    }
}

/// The Style button of the wireframe bar and its popover: a row for each setting of the selected
/// component, or else of the components drawn next. The popover is at the HUD's level, above the
/// overlay and the canvas, where a menu would not take clicks.
struct WireframeStyleButton: View {
    @ObservedObject var controller: AnnotationController
    @State private var isShown = false

    var body: some View {
        HUDButton(image: Image(systemName: "paintbrush"), isOn: isShown, help: "Style") {
            isShown.toggle()
        }
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            let style = controller.wireframe?.style ?? Wireframe.Style()
            VStack(alignment: .leading, spacing: 10) {
                Text(style.isSelection ? "Selected Component" : "New Components")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Wireframe.Style.rows, id: \.key) { row in
                    HStack(spacing: 12) {
                        Text(row.title)
                            .frame(width: 92, alignment: .leading)
                        Picker(row.title, selection: Binding(
                            get: { style.value(of: row.key) },
                            set: { controller.setWireframeStyle(row.key, to: $0) }
                        )) {
                            ForEach(row.options, id: \.0) { value, title in
                                Text(title).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            .padding(14)
        }
    }
}
