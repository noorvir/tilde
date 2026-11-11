import AppKit
import ApplicationServices
import TildeCore

/// Wireframe mode: skeletons of components drawn over the screen in the drawing canvas, each
/// with an optional label, sent together as one note with the screen under them.
struct Wireframe: Equatable {
    var tool = "card"

    /// Card stands in for any component not in the list.
    static let tools = [
        (tool: "screen", symbol: "macwindow", key: "s", help: "Screen"),
        (tool: "card", symbol: "square.text.square", key: "c", help: "Card"),
        (tool: "table", symbol: "tablecells", key: "t", help: "Table"),
        (tool: "button", symbol: "capsule", key: "b", help: "Button"),
        (tool: "dropdown", symbol: "chevron.down.square", key: "d", help: "Dropdown"),
        (tool: "list", symbol: "list.bullet.rectangle", key: "l", help: "List"),
    ]

    var json: String {
        DrawingPanel.json(["tool": tool])
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
        let next = Wireframe()
        wireframe = next
        drawingPanel.setWireframe(next.json)
    }

    func setWireframeTool(_ tool: String) {
        wireframe?.tool = tool
        drawingPanel.setWireframe(wireframe?.json ?? "null")
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
        let window = scope ?? picker.window(at: center)
        let screen = NSScreen.screens.first { $0.frame.flipped.contains(center) }?.frame.flipped ?? bounds
        // The window when the wireframe is in it, else the whole screen.
        let area = window.map(\.frame).flatMap { Self.isMostlyInside(bounds, $0) ? $0 : nil } ?? screen

        let canvas = Set(drawingPanel.windowNumbers.map { CGWindowID($0) })
        let page = Set(browser.windowNumber.map { [CGWindowID($0)] } ?? [])
        async let drawn = ScreenCapture.png(of: area, outline: nil, keeping: canvas.union(page), maxSide: 2048)
        async let under = ScreenCapture.png(of: area, outline: nil, keeping: page, maxSide: 2048)
        let captures = await Captures(image: drawn, contextImage: under)

        var shapes = (try? JSONSerialization.jsonObject(with: Data(DrawingShapes.encode(drawing.shapes, origin: area.origin, element: nil).utf8))) as? [String: Any] ?? [:]
        shapes["wireframe"] = "A wireframe of the change: the image shows it drawn over the screen, the context image the screen under it."
        openComposer(
            target: .drawing(shapes: DrawingPanel.json(shapes)), frame: bounds, marker: CGPoint(x: bounds.maxX, y: bounds.minY),
            chip: "Wireframe", outline: nil, window: window, captures: captures, drawingIDs: drawing.ids
        )
    }

    /// The lines under the pointer to snap to, from Accessibility; in Tilde's browser, the
    /// element the page reports.
    func findWireframeSnaps(at point: CGPoint) {
        guard !isFindingSnapFrame else {
            return
        }
        isFindingSnapFrame = true
        let window = scope ?? picker.window(at: point)
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
