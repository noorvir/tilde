import AppKit
import TildeCore

/// Wireframe mode: skeletons of components drawn over the screen in the drawing canvas, each
/// with an optional label, sent together as one note with the screen under them. The flow says
/// when the mode is on; this has its tool, the window that its components are on, the lines
/// they snap to, and the note that Done makes of them.
@MainActor
final class WireframeMode: ObservableObject {
    /// The tool that draws. Nil after Esc put it down: nothing draws, and the components can
    /// still be selected, moved, resized, copied and changed.
    @Published private(set) var tool: String? = WireframeMode.firstTool
    /// The window that the session is limited to.
    var scope: () -> ElementPicker.WindowInfo? = { nil }
    /// Done's pictures are being made.
    private(set) var isTaking = false

    private let canvas: DrawingPanel
    private let picker: ElementPicker
    private let browser: BrowserController
    /// The window of the first press: the components keep their place on it when it moves.
    private var window: ElementPicker.WindowInfo?
    private let follower = ScopeFollower()
    /// The note whose components show again: Done updates it instead of making a new one.
    private var shownNote: Draft.ID?
    /// The lookup under way of the lines under the pointer.
    private var snaps: Task<Void, Never>?
    /// The newest point that came during the lookup, to look up next.
    private var nextPoint: CGPoint?
    /// The lines that the canvas has, so the same ones are not sent again at pointer rate.
    private var sentSnaps: Snaps?

    private struct Snaps: Equatable {
        let lines: WireframeLayout.Lines
        let window: CGRect?
        let screen: CGRect?
    }

    /// Card, Rectangle and Circle stand in for any component not in the list.
    nonisolated static let tools = [
        (tool: "section", symbol: "rectangle.split.3x1", key: "s", help: "Section"),
        (tool: "card", symbol: "square.text.square", key: "c", help: "Card"),
        (tool: "table", symbol: "tablecells", key: "t", help: "Table"),
        (tool: "button", symbol: "capsule", key: "b", help: "Button"),
        (tool: "dropdown", symbol: "chevron.down.square", key: "d", help: "Dropdown"),
        (tool: "list", symbol: "list.bullet.rectangle", key: "l", help: "List"),
        (tool: "rectangle", symbol: "rectangle", key: "r", help: "Rectangle"),
        (tool: "ellipse", symbol: "circle", key: "o", help: "Circle"),
    ]
    nonisolated static let firstTool = "card"
    /// The chip of a wireframe's note.
    nonisolated static let chip = "Wireframe"

    init(canvas: DrawingPanel, picker: ElementPicker, browser: BrowserController) {
        self.canvas = canvas
        self.picker = picker
        self.browser = browser
        // The blurred screen under the components shows Tilde's browser, as Done's pictures do.
        canvas.underKeeps = { [weak browser] in Set(browser?.windowNumber.map { [CGWindowID($0)] } ?? []) }
    }

    // MARK: - The mode and its tool

    /// The canvas goes to wireframe mode, with the first tool and no window.
    func start() {
        reset()
        tool = Self.firstTool
        canvas.setSnapFrame(nil)
        sendTool()
    }

    /// The canvas leaves wireframe mode: the components that Done did not take go.
    func end() {
        reset()
        canvas.setWireframe("null")
    }

    func setTool(_ tool: String) {
        self.tool = tool
        sendTool()
    }

    func putToolDown() {
        tool = nil
        sendTool()
    }

    func undo() {
        canvas.undoWireframe()
    }

    func redo() {
        canvas.redoWireframe()
    }

    private func reset() {
        follower.stop()
        window = nil
        shownNote = nil
        snaps?.cancel()
        snaps = nil
        nextPoint = nil
        sentSnaps = nil
    }

    private func sendTool() {
        canvas.setWireframe(DrawingPanel.json(["tool": tool ?? "", "icons": Self.icons]))
    }

    /// Each tool's symbol as a white PNG, for the kind menu in a component's chip, so that it
    /// shows the same icons as the bar.
    private static let icons: [String: String] = Dictionary(uniqueKeysWithValues: tools.compactMap { entry in
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration),
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2), bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else {
            return nil
        }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return (entry.tool, "data:image/png;base64,\(png.base64EncodedString())")
    })

    // MARK: - The window

    /// A press on the canvas: the first one chooses the wireframe's window, which the
    /// components then follow while it moves, until the mode ends.
    func pressed(at point: CGPoint) {
        guard window == nil, let pressed = picker.window(at: point, in: scope()) else {
            return
        }
        follow(pressed)
    }

    /// The window list was read: also for windows that send no move notifications.
    func windowsRead() {
        checkWindow()
    }

    private func follow(_ window: ElementPicker.WindowInfo) {
        self.window = window
        canvas.setWireframeWindow(window.frame)
        follower.onCheck = { [weak self] frame in self?.checkWindow(frame: frame) }
        follower.start(window, page: nil)
    }

    /// Takes the window's new frame. `frame`: its frame as the window itself reported it,
    /// which can be ahead of the window list. A window that is gone leaves the components
    /// where they are.
    private func checkWindow(frame: CGRect? = nil) {
        guard let window, var current = picker.currentWindow(number: window.number) else {
            return
        }
        if let frame {
            current = ElementPicker.WindowInfo(number: current.number, pid: current.pid, app: current.app, title: current.title, frame: frame)
        }
        guard current.frame != window.frame else {
            return
        }
        self.window = current
        // The canvas drops the lines it has: they were where the window was.
        sentSnaps = nil
        canvas.setWireframeWindow(current.frame)
    }

    // MARK: - Snapping

    /// The pointer moved on the canvas: finds the lines under it to snap to, from
    /// Accessibility, or in Tilde's own windows the element that the page reports. One lookup
    /// runs at a time; of the points that come meanwhile, the newest is looked up next, so the
    /// lines are those where the pointer stopped.
    func pointerMoved(to point: CGPoint) {
        guard snaps == nil else {
            nextPoint = point
            return
        }
        let scope = scope()
        let window = window ?? scope ?? picker.window(at: point)
        let screen = NSScreen.screens.first { $0.frame.flipped.contains(point) }?.frame.flipped
        let isOwn = window?.number == browser.windowNumber || window?.pid == ProcessInfo.processInfo.processIdentifier
        snaps = Task {
            var lines = WireframeLayout.Lines()
            if isOwn {
                if let picked = await picker.pick(at: point, isMoving: true, in: scope) {
                    lines.rects = [picked.frame]
                }
            } else if let pid = window?.pid, AXIsProcessTrusted() {
                lines = await Task.detached(priority: .userInitiated) { WireframeLayout.lines(at: point, pid: pid) }.value
            }
            // The mode ended meanwhile.
            if Task.isCancelled {
                return
            }
            snaps = nil
            let found = Snaps(lines: lines, window: window?.frame, screen: screen)
            if found != sentSnaps {
                sentSnaps = found
                canvas.setSnapTargets(rects: lines.rects, containers: lines.containers, window: window?.frame, screen: screen)
            }
            if let next = nextPoint {
                nextPoint = nil
                pointerMoved(to: next)
            }
        }
    }

    // MARK: - The note

    /// What Done makes of the components.
    struct Taken {
        let note: NewNote
        /// The note whose components were shown again, which this one replaces.
        let replaces: Draft.ID?
    }

    /// Takes the components off the canvas's list of new shapes, as one note with the screen
    /// as it is with the wireframe on it and as it is under it. Nil when nothing was drawn.
    func take() async -> Taken? {
        isTaking = true
        defer {
            isTaking = false
        }
        guard let drawn = await canvas.takeNewShapes(), !drawn.ids.isEmpty else {
            return nil
        }
        // The pictures show the wireframe without the handles of a selected component.
        canvas.deselect()
        try? await Task.sleep(for: .milliseconds(100))

        let bounds = drawn.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let chosen = window.flatMap { picker.currentWindow(number: $0.number) }
        let window = chosen ?? scope() ?? picker.window(at: center)
        let screen = NSScreen.screens.first { $0.frame.flipped.contains(center) }?.frame.flipped ?? bounds
        // The wireframe's window; else the window when the wireframe is in it, else the whole screen.
        let inside = window.map(\.frame).flatMap { NoteCaptures.isMostlyInside(bounds, $0) ? $0 : nil }
        let area = chosen?.frame ?? inside ?? screen
        let replaces = shownNote

        let canvasWindows = Set(canvas.windowNumbers.map { CGWindowID($0) })
        let page = Set(browser.windowNumber.map { [CGWindowID($0)] } ?? [])
        let captures = await NoteCaptures.ofWireframe(area: area, canvas: canvasWindows, page: page)
        let target = Target.drawing(shapes: Self.report(of: drawn.shapes, origin: area.origin, isOnWindow: chosen != nil))
        let note = NewNote(
            target: target, frame: bounds, marker: CGPoint(x: bounds.maxX, y: bounds.minY), chip: Self.chip, window: window,
            captures: captures, drawingIDs: drawn.ids
        )
        return Taken(note: note, replaces: replaces)
    }

    /// The components for the report: relative to `origin`, the top left of their window or
    /// of the screen, with what the pictures show.
    nonisolated static func report(of shapes: [[String: Any]], origin: CGPoint, isOnWindow: Bool) -> String {
        let encoded = DrawingShapes.encode(shapes, origin: origin, element: nil)
        var report = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [String: Any] ?? [:]
        report["wireframe"] = "A wireframe of the change: the image shows it drawn over the screen, the context image the screen under it."
        report["originIs"] = isOnWindow ? "window" : "screen"
        return DrawingPanel.json(report)
    }

    /// A wireframe note's components, as its report has them.
    struct Saved {
        let shapes: [[String: Any]]
        /// The top left of the window or the screen that the components are from.
        let origin: CGPoint
        let isOnWindow: Bool

        /// Nil when the note is not of a wireframe.
        init?(_ draft: Draft) {
            guard case .drawing(let json) = draft.annotation.target,
                  let report = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], report["wireframe"] != nil,
                  let shapes = report["shapes"] as? [[String: Any]], let origin = report["origin"] as? [Double], origin.count == 2
            else {
                return nil
            }
            self.shapes = shapes
            self.origin = CGPoint(x: origin[0], y: origin[1])
            isOnWindow = report["originIs"] as? String == "window"
        }
    }

    /// Shows a note's components again, on its window where they were on one, to edit them:
    /// Done then replaces that note.
    func show(_ saved: Saved, of draft: Draft) {
        shownNote = draft.id
        // Components on a window are from its top left, which may have moved since.
        var window: ElementPicker.WindowInfo?
        if saved.isOnWindow {
            window = draft.sourceWindow.flatMap { picker.currentWindow(number: $0) }
        }
        canvas.restoreWireframe(shapes: saved.shapes, origin: window?.frame.origin ?? saved.origin)
        if let window {
            follow(window)
        }
    }
}

extension Draft {
    var isWireframe: Bool {
        chip == WireframeMode.chip
    }

    /// The note with its wireframe drawn again: the new components and their pictures, and
    /// the comment it had.
    func redrawn(as note: NewNote) -> Draft {
        let captures = note.captures ?? Captures(image: annotation.image, contextImage: annotation.contextImage)
        let annotation = Annotation(
            id: id, comment: annotation.comment, target: note.target, frame: note.frame, image: captures.image, contextImage: captures.contextImage
        )
        var fingerprint = fingerprint
        if let window = note.window {
            let frame = note.frame
            fingerprint = Task { await NoteFingerprint.capture(window: CGWindowID(window.number), area: frame) }
        }
        return Draft(
            annotation: annotation, marker: note.marker, chip: chip, capture: Task { captures }, anchor: anchor,
            sourceWindow: note.window?.number ?? sourceWindow, fingerprint: fingerprint, page: page, sourcePID: note.window?.pid ?? sourcePID,
            pictureArea: pictureArea
        )
    }
}
