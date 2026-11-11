import AppKit

/// What the pointer does on the overlay: it highlights the element under it, chooses a
/// source while choosing, and a click or a drag makes a new note.
extension AnnotationController {
    /// While choosing a source, a session limited to a window also takes the other windows.
    func allows(_ point: CGPoint) -> Bool {
        SessionScope.allows(point, scope: isPickingWindow ? nil : scope.window?.frame)
    }

    func mouseMoved(to point: CGPoint) {
        guard composer == nil, previewID == nil else {
            return
        }
        hoverPicker.pointerMoved(isOverPanel: isOverPanel(point))
        if hoverPicker.isOverPanel || !allows(point) || tracker.label(at: point) != nil {
            hoverPicker.clear()
            return
        }
        if isPickingWindow {
            hover = isSourcePickerOpen ? nil : picker.windowTarget(at: point)
            return
        }

        hoverPicker.pick(at: point)
    }

    /// Picks again under the pointer after the page moved under it, such as on scroll, so the
    /// hover highlight stays on the element.
    func refreshHover() {
        guard hover != nil else {
            return
        }
        mouseMoved(to: NSEvent.mouseLocation.flipped)
    }

    /// Scrolling always goes to the window under the pointer, as if Tilde were not there; the
    /// hover highlight then follows the page. Tilde's browser reports its own scrolling.
    func scroll(_ event: NSEvent, at point: CGPoint) {
        guard let window = picker.window(at: point) else {
            return
        }
        ScrollForwarder.forward(event, at: point, to: window)
        if window.number != browser.windowNumber {
            tracker.scrolled()
            hoverPicker.scrolled()
        }
    }

    func mouseExited() {
        hoverPicker.clear()
    }

    func click(at point: CGPoint) {
        if previewID != nil {
            dispatch(.closePreview)
            return
        }
        if isPickingWindow {
            guard !isSourcePickerOpen else {
                return
            }
            // A window, or outside windows the screen.
            if let window = picker.window(at: point) {
                choose(.window(window))
            } else if let display = NSScreen.screens.first(where: { $0.frame.contains(point.flipped) })?.displayID {
                choose(.screen(display))
            }
            return
        }
        guard allows(point) else {
            return
        }
        if composer != nil {
            dispatch(.clickAway)
            return
        }

        Task {
            var picked = hover
            if picked?.frame.contains(point) != true {
                picked = await picker.pick(at: point, in: scope.window)
            }
            if let picked {
                openComposer(NewNote(picked, at: point))
            }
        }
    }

    func dragEnded(with rect: CGRect) {
        if previewID != nil {
            dispatch(.closePreview)
            return
        }
        // While choosing, only a click chooses.
        if isPickingWindow {
            return
        }
        guard let rect = SessionScope.clamped(rect, scope: scope.window?.frame) else {
            return
        }
        if composer != nil {
            dispatch(.clickAway)
            return
        }
        let marker = CGPoint(x: rect.maxX, y: rect.minY)
        let window = scope.window ?? picker.window(at: CGPoint(x: rect.midX, y: rect.midY))
        let isOverBrowser = window?.number == browser.windowNumber
        Task {
            let anchor = isOverBrowser ? await browser.regionAnchor(for: rect) : nil
            openComposer(NewNote(target: .region, frame: rect, marker: marker, chip: "Region", window: window, anchor: anchor))
        }
    }
}
