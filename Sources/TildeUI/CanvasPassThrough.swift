import AppKit

/// Whether the drawing canvas takes the mouse. With a tool, it takes it everywhere. With no
/// tool, it takes it only where it has something under the pointer, such as a wireframe's
/// component, its handles or a note's label; anywhere else the pointer goes to the app behind.
/// The window server sends a click to a window before the window can look at it, so the canvas
/// decides at each place that the pointer moves to, and takes or ignores the mouse from there.
@MainActor
final class CanvasPassThrough {
    weak var window: NSWindow?
    /// The canvas is on screen to draw on: shown, and not paused.
    var isActive = false {
        didSet {
            update()
        }
    }
    var hasNoTool = false {
        didSet {
            update()
        }
    }
    /// Whether the canvas has something at a Quartz point to take a press.
    var takesPointer: (CGPoint) async -> Bool = { _ in true }
    /// The pointer went through the canvas to the app behind. `isPress`: it pressed there.
    var onWentThrough: (_ isPress: Bool) -> Void = { _ in }

    private var monitors: [Any] = []
    /// The answer under way for the pointer's place.
    private var check: Task<Void, Never>?
    /// The newest place that came meanwhile, to check next.
    private var nextPoint: CGPoint?

    private func update() {
        guard isActive, hasNoTool else {
            stopWatching()
            window?.ignoresMouseEvents = !isActive
            return
        }
        startWatching()
        pointerMoved(to: NSEvent.mouseLocation.flipped)
    }

    /// Moves in any app, and the end of a press: a press keeps the window that it started in.
    /// A press in another app is one that went through.
    private func startWatching() {
        guard monitors.isEmpty else {
            return
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp, .leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stopWatching() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        check?.cancel()
        check = nil
        nextPoint = nil
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onWentThrough(true)
            return
        }
        pointerMoved(to: NSEvent.mouseLocation.flipped)
    }

    /// One answer at a time; of the places that come meanwhile, the newest is checked next.
    private func pointerMoved(to point: CGPoint) {
        guard check == nil else {
            nextPoint = point
            return
        }
        check = Task {
            let takes = await takesPointer(point)
            // Watching stopped meanwhile.
            if Task.isCancelled {
                return
            }
            check = nil
            let wasTaking = window?.ignoresMouseEvents == false
            window?.ignoresMouseEvents = !takes
            if wasTaking, !takes {
                onWentThrough(false)
            }
            if let next = nextPoint {
                nextPoint = nil
                pointerMoved(to: next)
            }
        }
    }
}
