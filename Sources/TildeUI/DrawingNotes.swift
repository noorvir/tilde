import AppKit
import TildeCore

/// Draw mode: the canvas with its tool and colour, and the notes that shapes become. A shape
/// is on the canvas only while its comment is open; the note that remains is a label on what
/// is under the shape.
@MainActor
final class DrawingNotes: ObservableObject {
    let panel = DrawingPanel()
    @Published private(set) var tool = "arrow"
    @Published private(set) var color = "#2F76FF"
    /// Esc put the tool down: nothing draws until one is chosen.
    @Published private(set) var isToolDown = false
    /// The window that the session is limited to.
    var scope: () -> ElementPicker.WindowInfo? = { nil }
    /// Whether a note's label is at a Quartz point.
    var isOnLabel: (CGPoint) -> Bool = { _ in false }

    private let picker: ElementPicker
    /// Notes of drawings that Undo took out, for Redo.
    private var undone: [Draft] = []
    private var isFindingSnapFrame = false

    init(picker: ElementPicker) {
        self.picker = picker
    }

    /// Opens the canvas on the screen with the pointer.
    func start() {
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
            isToolDown = false
            panel.startDrawing(on: screen, tool: tool)
        }
    }

    func setTool(_ tool: String) {
        self.tool = tool
        isToolDown = false
        panel.setTool(tool)
    }

    /// Draw and Wireframe stay through a pause: what was drawn stays on screen, and the mouse
    /// goes through the canvas.
    func setPaused(_ isPaused: Bool) {
        if isPaused {
            panel.stopDrawing()
        } else {
            panel.resumeDrawing()
        }
    }

    func putToolDown() {
        isToolDown = true
        panel.setNoTool()
    }

    func setColor(_ color: String) {
        self.color = color
        panel.setColor(color)
    }

    // MARK: - Shapes to notes

    /// What was just drawn, as a new note with the window and the whole screen as they are
    /// with the drawing on them. Nil when nothing was drawn.
    func takeNote() async -> NewNote? {
        guard let drawing = await panel.takeNewShapes(), !drawing.ids.isEmpty else {
            return nil
        }
        undone = []
        let point = DrawingShapes.linkPoint(of: drawing.shapes)
        let link = await link(at: point, fallback: drawing.bounds)
        let center = CGPoint(x: drawing.bounds.midX, y: drawing.bounds.midY)
        let screen = NSScreen.screens.first { $0.frame.flipped.contains(center) }?.frame.flipped
        let origin = (link.window?.frame ?? screen ?? drawing.bounds).origin
        let captures = await captures(of: drawing.bounds, in: link.window?.frame)
        return NewNote(
            target: .drawing(shapes: DrawingShapes.encode(drawing.shapes, origin: origin, element: link.element)), frame: link.frame,
            marker: link.marker, chip: "Drawing", window: link.window, anchor: link.anchor, tracked: link.tracked,
            pictureArea: link.pictureArea, captures: captures, drawingIDs: drawing.ids
        )
    }

    /// Shapes of an open comment as they are after an edit, with what their label is now
    /// attached to. Nil when the shapes are gone.
    func edit(of ids: [String]) async -> ShapeEdit? {
        let shapes = await panel.shapes(ids)
        let bounds = DrawingShapes.bounds(of: shapes)
        let link = await link(at: DrawingShapes.linkPoint(of: shapes), fallback: bounds)
        guard !shapes.isEmpty else {
            return nil
        }
        return ShapeEdit(shapes: shapes, bounds: bounds, link: link)
    }

    /// The comment of `pending` is saved: its shape leaves the canvas. Returns the note's
    /// screenshots; an edited shape gets new ones first, without its handles.
    func finish(_ pending: Pending, windowFrame: CGRect?) -> Task<Captures, Never> {
        guard pending.isDrawingEdited else {
            panel.remove(pending.drawingIDs)
            return pending.capture
        }
        let bounds = pending.drawingBounds ?? pending.frame
        return Task {
            // The canvas has to paint without the handles first.
            try? await Task.sleep(for: .milliseconds(100))
            let captures = await captures(of: bounds, in: windowFrame)
            panel.remove(pending.drawingIDs)
            return captures
        }
    }

    /// The window (or else the screen) and the whole screen, with the drawings on them.
    private func captures(of bounds: CGRect, in windowFrame: CGRect?) async -> Captures {
        let keeping = Set(panel.windowNumbers.map { CGWindowID($0) })
        return await NoteCaptures.ofDrawing(bounds: bounds, in: windowFrame, keeping: keeping)
    }

    /// The smallest element at a point. A window that shows no elements gets a label at the
    /// point, as a click does; `fallback` is then the frame of the note.
    private func link(at point: CGPoint, fallback: CGRect) async -> NoteLink {
        guard let picked = await picker.pick(at: point, in: scope()) else {
            let window = scope() ?? picker.window(at: point)
            return NoteLink(frame: fallback, marker: point, element: nil, window: window, anchor: nil, tracked: nil, pictureArea: NoteFingerprint.area(around: point))
        }

        guard picked.isWholeWindow else {
            let marker = CGPoint(x: picked.frame.maxX, y: picked.frame.minY)
            return NoteLink(frame: picked.frame, marker: marker, element: picked.element, window: picked.window, anchor: picked.anchor, tracked: picked.tracked, pictureArea: nil)
        }

        return NoteLink(frame: fallback, marker: point, element: nil, window: picked.window, anchor: nil, tracked: nil, pictureArea: NoteFingerprint.area(around: point))
    }

    // MARK: - Undo

    /// Keeps a drawing's note that Undo took out of the list.
    func keepUndone(_ draft: Draft) {
        undone.append(draft)
    }

    /// The note that Redo puts back in the list.
    func takeUndone() -> Draft? {
        undone.popLast()
    }

    // MARK: - Snap

    /// Shows the element under the pointer as the one a shape snaps to, unless the pointer is
    /// over a note's label. It reuses the hover lookup, which leaves out apps too slow to ask.
    func pointerMoved(to point: CGPoint, isOverLabel: Bool) {
        panel.setOverLabel(isOverLabel)
        if isOverLabel {
            panel.setSnapFrame(nil)
            return
        }

        guard !isFindingSnapFrame, UserDefaults.standard.object(forKey: "drawingSnaps") as? Bool ?? true else {
            return
        }
        isFindingSnapFrame = true
        Task {
            let picked = await picker.pick(at: point, isMoving: true, in: scope())
            isFindingSnapFrame = false
            guard !isOnLabel(point) else {
                return
            }

            // Only the snap ring shows the element: no outline or label, as on hover.
            panel.setSnapFrame(picked?.chip == "window" ? nil : picked?.frame)
        }
    }
}

/// What a drawing's label is attached to.
struct NoteLink {
    let frame: CGRect
    let marker: CGPoint
    let element: Element?
    let window: ElementPicker.WindowInfo?
    let anchor: PageAnchor?
    let tracked: TrackedElement?
    let pictureArea: CGRect?
}

/// Shapes after an edit, and what their label is attached to now.
struct ShapeEdit {
    let shapes: [[String: Any]]
    let bounds: CGRect
    let link: NoteLink
}

extension Pending {
    /// Takes the edited shapes of its drawing: the target, the link and what the picture check
    /// looks at. Its picture waits for the end of the edit. False when it is not a drawing.
    @MainActor
    mutating func take(_ edit: ShapeEdit) -> Bool {
        guard case .drawing(let old) = target else {
            return false
        }
        let link = edit.link
        target = .drawing(shapes: DrawingShapes.encode(edit.shapes, origin: DrawingShapes.origin(of: old), element: link.element))
        drawingBounds = edit.bounds
        frame = link.frame
        marker = link.marker
        anchor = link.anchor
        tracked = link.tracked
        pictureArea = link.pictureArea
        isDrawingEdited = true
        if let window = sourceWindow {
            let area = link.pictureArea ?? link.frame
            fingerprint = Task { await NoteFingerprint.capture(window: CGWindowID(window), area: area) }
        }
        return true
    }
}
