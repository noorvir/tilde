import AppKit
import Combine

/// Transparent full-screen window that receives hover, click and drag while annotating.
final class OverlayWindow: NSPanel {
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    init(screen: NSScreen, controller: AnnotationController) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Fully transparent windows let clicks through unless this is set explicitly.
        ignoresMouseEvents = false
        setFrame(screen.frame, display: false)
        let view = OverlayView(controller: controller)
        contentView = view
        // Esc and ⌘↩ reach the view only when it is the first responder.
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

/// Draws the hover highlight, drafts with numbered markers, the pending target and the drag
/// rectangle. Uses a flipped coordinate space so Quartz rects map by a plain offset.
final class OverlayView: NSView {
    private let controller: AnnotationController
    private var subscription: AnyCancellable?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var hoveredMarker: Draft.ID?

    init(controller: AnnotationController) {
        self.controller = controller
        super.init(frame: .zero)
        subscription = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: NSEvent.mouseLocation.flipped, source: "cursorUpdate")
    }

    /// The only place that sets the cursor while annotating: an arrow over the HUD, a
    /// crosshair outside Tilde's panels. Over the comment box and the preview it sets nothing,
    /// so their text fields keep the text cursor.
    private func updateCursor(at point: CGPoint, source: String) {
        let cursor: NSCursor?
        if controller.isOverTextPanel(point) {
            cursor = nil
        } else if controller.isOverPanel(point) || controller.previewID != nil {
            cursor = .arrow
        } else {
            cursor = .crosshair
        }

        if CursorDebug.isEnabled {
            let target = cursor.map(CursorDebug.name(of:)) ?? "none"
            CursorDebug.log.notice("overlay \(self.window?.windowNumber ?? 0, privacy: .public) \(source, privacy: .public) at \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public) wants \(target, privacy: .public)")
        }
        if let cursor, NSCursor.current != cursor {
            cursor.set()
        }
    }

    // MARK: - Events

    /// Quartz screen point of an event. Converts through the event's own window: a moved
    /// event can belong to another overlay's window, and this window would give a wrong point.
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        guard let window = event.window ?? window else {
            return .zero
        }
        return window.convertPoint(toScreen: event.locationInWindow).flipped
    }

    /// Origin of this screen in Quartz coordinates; subtract it to get view coordinates.
    private var origin: CGPoint {
        window?.frame.flipped.origin ?? .zero
    }

    override func mouseMoved(with event: NSEvent) {
        let point = screenPoint(event)
        updateCursor(at: point, source: "mouseMoved")
        let marker = controller.drafts.last { hypot($0.marker.x - point.x, $0.marker.y - point.y) <= 13 }?.id
        if marker != hoveredMarker {
            hoveredMarker = marker
            needsDisplay = true
        }
        controller.mouseMoved(to: point)
    }

    override func mouseEntered(with event: NSEvent) {
        controller.makeOverlayKey()
    }

    override func mouseExited(with event: NSEvent) {
        controller.mouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = screenPoint(event)
        dragRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else {
            return
        }
        let point = screenPoint(event)
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        if dragRect != nil || rect.width > 6 || rect.height > 6 {
            dragRect = rect
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragRect = nil
            needsDisplay = true
        }

        if let rect = dragRect, rect.width >= 8, rect.height >= 8 {
            controller.dragEnded(with: rect)
        } else {
            controller.click(at: screenPoint(event))
        }
    }

    override func keyDown(with event: NSEvent) {
        if controller.isPaused {
            super.keyDown(with: event)
            return
        }
        if controller.confirmation != nil {
            if event.keyCode == 53 {
                controller.dismissConfirmation()
            } else if event.keyCode == 36 {
                controller.confirm()
            }
            return
        }
        if event.keyCode == 49, let id = hoveredMarker {
            controller.preview(id)
            return
        }
        if event.keyCode == 53 {
            if controller.composer != nil {
                controller.closeComposer()
            }
            return
        }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            controller.send()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor.tildeBlue

        for (index, draft) in controller.drafts.enumerated() {
            let rect = draft.annotation.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            if case .region = draft.annotation.target {
                drawRect(rect, fill: blue.withAlphaComponent(0.06), stroke: blue.withAlphaComponent(0.7), dashed: true)
            } else {
                drawRect(rect, fill: .clear, stroke: blue.withAlphaComponent(0.35), dashed: false)
            }
            drawMarker(index + 1, at: draft.marker)
        }

        if let pending = controller.pendingTarget {
            let rect = pending.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            let isRegion: Bool
            if case .region = pending.target {
                isRegion = true
            } else {
                isRegion = false
            }
            drawRect(rect, fill: blue.withAlphaComponent(0.08), stroke: blue, dashed: isRegion)
            drawMarker(controller.drafts.count + 1, at: pending.marker)
        }

        if let rect = dragRect?.offsetBy(dx: -origin.x, dy: -origin.y) {
            drawRect(rect, fill: blue.withAlphaComponent(0.1), stroke: blue, dashed: true)
            drawLabel(["\(Int(rect.width))×\(Int(rect.height))"], near: rect)
        } else if let hover = controller.hover {
            let rect = hover.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            drawRect(rect, fill: blue.withAlphaComponent(0.08), stroke: blue, dashed: false)
            drawLabel(hover.details, near: rect)
        }

        if let id = hoveredMarker, let draft = controller.drafts.first(where: { $0.id == id }), controller.composer == nil {
            drawTooltip(draft.annotation.comment.isEmpty ? "(no comment)" : draft.annotation.comment, at: draft.marker)
        }
    }

    private func drawRect(_ rect: CGRect, fill: NSColor, stroke: NSColor, dashed: Bool) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1.5
        if dashed {
            path.setLineDash([5, 3], count: 2, phase: 0)
        }
        path.stroke()
    }

    private func drawMarker(_ number: Int, at point: CGPoint) {
        let center = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let circle = NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.set()
        NSColor.tildeBlue.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()

        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    /// Dark monospaced label above the highlight, or below it near the top of the screen.
    private func drawLabel(_ lines: [String], near rect: CGRect) {
        let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        var box = NSRect(x: rect.minX, y: rect.minY - size.height - 14, width: size.width + 14, height: size.height + 8)
        if box.minY < 4 {
            box.origin.y = rect.maxY + 6
        }
        box.origin.x = min(max(box.minX, 4), bounds.width - box.width - 4)
        box.origin.y = min(max(box.minY, 4), bounds.height - box.height - 4)

        NSColor.tildeInk.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 4))
    }

    private func drawTooltip(_ comment: String, at point: CGPoint) {
        let text = NSAttributedString(string: String(comment.prefix(140)), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.12, alpha: 1),
        ])
        let size = text.boundingRect(with: NSSize(width: 280, height: 200), options: [.usesLineFragmentOrigin]).size
        let anchor = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let box = NSRect(x: anchor.x + 16, y: anchor.y - size.height / 2 - 8, width: ceil(size.width) + 24, height: ceil(size.height) + 16)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.set()
        let radius = min(12, box.height / 2)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()

        text.draw(with: NSRect(x: box.minX + 12, y: box.minY + 8, width: ceil(size.width), height: ceil(size.height)), options: [.usesLineFragmentOrigin])
    }
}
