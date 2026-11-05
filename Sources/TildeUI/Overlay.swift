import AppKit
import Combine

/// Transparent window that receives hover, click and drag while annotating: one per screen
/// above everything, or, for a session limited to one window, one the size of that window
/// ordered just above it, so windows brought in front of it cover it too.
final class OverlayWindow: NSPanel {
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    /// On one window, ordered just above it, instead of on a whole screen.
    let isWindowSized: Bool

    /// Whether the overlay takes the pointer; without it, clicks and moves go to the windows
    /// under it, and it only draws.
    var takesInput = true {
        didSet {
            guard takesInput != oldValue else {
                return
            }
            ignoresMouseEvents = !takesInput
            acceptsMouseMovedEvents = takesInput
            contentView?.updateTrackingAreas()
        }
    }

    convenience init(screen: NSScreen, controller: AnnotationController) {
        self.init(frame: screen.frame, level: Self.overlayLevel, isWindowSized: false, controller: controller)
    }

    /// `frame` in AppKit screen coordinates.
    init(frame: CGRect, level: NSWindow.Level, isWindowSized: Bool, controller: AnnotationController) {
        self.isWindowSized = isWindowSized
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        // A window's overlay stays on that window's Space; screen overlays show on every Space.
        collectionBehavior = isWindowSized ? [.fullScreenAuxiliary, .ignoresCycle] : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // Fully transparent windows let clicks through unless this is set explicitly.
        ignoresMouseEvents = false
        setFrame(frame, display: false)
        let view = OverlayView(controller: controller)
        contentView = view
        // Esc and ⌘↩ reach the view only when it is the first responder.
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }

    /// Covers exactly the frame it is given, also under the menu bar, like the window it is on.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Draws the hover highlight, drafts with numbered markers, the pending target and the drag
/// rectangle. Uses a flipped coordinate space so Quartz rects map by a plain offset.
final class OverlayView: NSView {
    private let controller: AnnotationController
    private var subscription: AnyCancellable?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var hoveredMarker: Draft.ID?
    private var handCursorTimer: Timer?
    /// Where the comment cards of the browser's page notes are, in view coordinates, for clicks.
    private var noteCards: [(id: Draft.ID, rect: CGRect)] = []

    init(controller: AnnotationController) {
        self.controller = controller
        super.init(frame: .zero)
        // The browser's notes move with its page; the hover highlight changes on its own.
        subscription = controller.objectWillChange.merge(with: controller.browser.objectWillChange, controller.hoverHighlight.objectWillChange)
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
        // Without input the overlay only draws: no hover, cursor or enter and exit.
        guard (window as? OverlayWindow)?.takesInput == true else {
            return
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: NSEvent.mouseLocation.flipped, source: "cursorUpdate")
    }

    /// The only place that sets the cursor while annotating: an arrow over the HUD and
    /// outside a scoped window, a crosshair elsewhere. Over the comment box and the preview it sets nothing,
    /// so their text fields keep the text cursor.
    private func updateCursor(at point: CGPoint, source: String) {
        let cursor: NSCursor?
        if controller.isOverTextPanel(point) {
            cursor = nil
        } else if controller.isOverPanel(point) || controller.previewID != nil || !controller.allows(point) {
            cursor = .arrow
        } else if controller.noteLabel(at: point) != nil {
            cursor = .pointingHand
        } else {
            cursor = .crosshair
        }

        if CursorDebug.isEnabled {
            let target = cursor.map(CursorDebug.name(of:)) ?? "none"
            CursorDebug.log.notice("overlay \(self.window?.windowNumber ?? 0, privacy: .public) \(source, privacy: .public) at \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public) wants \(target, privacy: .public)")
        }
        if cursor == .pointingHand {
            holdHandCursor()
        } else {
            handCursorTimer?.invalidate()
            handCursorTimer = nil
        }
        if let cursor, NSCursor.current != cursor {
            cursor.set()
        }
    }

    /// The app in front can set its own cursor, and `NSCursor.current` does not tell: the hand
    /// is set again for as long as the pointer is on a label.
    private func holdHandCursor() {
        NSCursor.pointingHand.set()
        guard handCursorTimer == nil else {
            return
        }
        handCursorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            NSCursor.pointingHand.set()
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
        let marker = controller.noteLabel(at: point)
        if marker != hoveredMarker {
            hoveredMarker = marker
            needsDisplay = true
        }
        controller.mouseMoved(to: point)
    }

    override func scrollWheel(with event: NSEvent) {
        controller.scroll(event, at: screenPoint(event))
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

        let point = screenPoint(event)
        let viewPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if let rect = dragRect, rect.width >= 8, rect.height >= 8 {
            controller.dragEnded(with: rect)
        } else if let id = controller.noteLabel(at: point) {
            controller.preview(id)
        } else if let card = noteCards.last(where: { $0.rect.contains(viewPoint) }) {
            controller.showNoteInPanel(card.id)
        } else {
            controller.click(at: screenPoint(event))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            controller.escapePressed()
            return
        }
        if controller.confirmation != nil {
            if event.keyCode == 36 {
                controller.confirm()
            }
            return
        }
        // Back and forward belong to the page under the overlay.
        if event.modifierFlags.contains(.command), event.keyCode == 33 || event.keyCode == 30 {
            controller.navigateHistory(event)
            return
        }
        // The same action and rule as the Send button, paused too; the flow ignores it while
        // choosing a window or with nothing to send.
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            controller.send()
            return
        }
        if controller.pauses.contains(.user) {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 49, let id = hoveredMarker {
            controller.preview(id)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor.tildeBlue

        // A window-sized overlay outlines its window; Tilde's browser has its dark frame.
        if controller.scope != nil, !controller.isInBrowser, (window as? OverlayWindow)?.isWindowSized == true {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            outline.lineWidth = 2
            blue.withAlphaComponent(0.6).setStroke()
            outline.stroke()
        }

        // Notes on a web page in Tilde's browser are drawn by the browser, attached to their
        // elements, so they scroll with the page; the overlay's marks would stay behind.
        drawNotes()

        if let pending = controller.pendingTarget {
            let rect = pending.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            let isRegion: Bool
            if case .region = pending.target {
                isRegion = true
            } else {
                isRegion = false
            }
            if pending.drawingIDs.isEmpty {
                drawRect(rect, fill: blue.withAlphaComponent(0.08), stroke: blue, dashed: isRegion)
            }
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

        // Page notes show their comment already.
        if let id = hoveredMarker, let draft = controller.drafts.first(where: { $0.id == id }), controller.composer == nil,
           !controller.pageNotes.contains(where: { $0.draft.id == id })
        {
            if let marker = controller.noteMarker(draft) {
                drawTooltip(Self.commentText(draft), at: marker)
            }
        }
    }

    private static func commentText(_ draft: Draft) -> String {
        draft.annotation.comment.isEmpty ? "(no comment)" : draft.annotation.comment
    }

    /// Every note not on a web page in Tilde's browser (those the browser draws, unless its
    /// notes panel is hidden), back window first: a note is drawn, then cleared where windows
    /// in front of its window cover it, so a window in front hides the notes behind it.
    private func drawNotes() {
        struct Note {
            let number: Int
            let draft: Draft
            let frame: CGRect
            let marker: CGPoint
            let window: Int?
            let isOnPage: Bool
        }
        var notes: [Note] = []
        for (index, draft) in controller.drafts.enumerated() where draft.anchor == nil {
            // Notes on elements in other apps follow them, and hide while out of view.
            guard let frame = controller.noteFrame(draft), let marker = controller.noteMarker(draft) else {
                continue
            }
            notes.append(Note(number: index + 1, draft: draft, frame: frame, marker: marker, window: draft.sourceWindow, isOnPage: false))
        }
        let browserWindow = controller.browser.windowNumber
        for note in controller.pageNotes {
            notes.append(Note(number: note.number, draft: note.draft, frame: note.frame, marker: note.marker, window: browserWindow, isOnPage: true))
        }
        notes = notes.filter { note in note.window.map { !controller.hiddenWindows.contains($0) } ?? true }
        notes.sort { (controller.windowDepth[$0.window ?? -1] ?? 0) > (controller.windowDepth[$1.window ?? -1] ?? 0) }

        noteCards = []
        for note in notes {
            // Once made, a note is only its number; its box shows on hover or selection.
            if hoveredMarker == note.draft.id || controller.browser.selectedNote == note.draft.id {
                drawNote(note.draft, frame: note.frame.offsetBy(dx: -origin.x, dy: -origin.y))
            }
            drawMarker(note.number, at: note.marker)
            if note.isOnPage {
                let anchor = CGPoint(x: note.marker.x - origin.x, y: note.marker.y - origin.y)
                let element = note.frame.offsetBy(dx: -origin.x, dy: -origin.y)
                let card = drawCommentCard(Self.commentText(note.draft), beside: anchor, element: element, avoiding: noteCards.map(\.rect), maxLines: 3)
                noteCards.append((note.draft.id, card))
            }
            for cover in note.window.flatMap({ controller.windowCovers[$0] }) ?? [] {
                NSColor.clear.setFill()
                cover.offsetBy(dx: -origin.x, dy: -origin.y).fill(using: .copy)
            }
        }
    }

    /// A note's outline: dashed and lightly filled for a region, a light line for an element.
    private func drawNote(_ draft: Draft, frame rect: CGRect) {
        let blue = NSColor.tildeBlue
        if case .region = draft.annotation.target {
            drawRect(rect, fill: blue.withAlphaComponent(0.06), stroke: blue.withAlphaComponent(0.7), dashed: true)
        } else {
            drawRect(rect, fill: .clear, stroke: blue.withAlphaComponent(0.35), dashed: false)
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

    /// A note's comment in the tooltip's card, at most `maxLines` lines and 240 pt wide, right
    /// of its marker, or left of the element when there is no room; moved down below cards in
    /// `avoiding`. Returns where it was drawn.
    private func drawCommentCard(_ comment: String, beside anchor: CGPoint, element: CGRect, avoiding placed: [CGRect], maxLines: Int) -> CGRect {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: comment, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: 0.12, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let limit = NSSize(width: 240, height: lineHeight * CGFloat(maxLines))
        let size = text.boundingRect(with: limit, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]).size
        let width = ceil(size.width) + 24
        let height = min(ceil(size.height), limit.height) + 16

        var box = NSRect(x: anchor.x + 16, y: anchor.y - height / 2, width: width, height: height)
        if box.maxX > bounds.width - 4 {
            box.origin.x = element.minX - 16 - width
        }
        box.origin.x = max(box.minX, 4)
        while let overlap = placed.first(where: { $0.insetBy(dx: 0, dy: -3).intersects(box) }) {
            box.origin.y = overlap.maxY + 6
        }

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

        text.draw(with: NSRect(x: box.minX + 12, y: box.minY + 8, width: box.width - 24, height: box.height - 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return box
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
