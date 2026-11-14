import AppKit

/// Whether a window of the session takes the mouse where the pointer is: the drawing canvas only
/// where it has something to take a press, and no window of the session over Tilde's own windows,
/// such as Settings. Anywhere else the pointer goes to the window behind. The window server sends
/// a click to a window before the window can look at it, so the window decides at each place that
/// the pointer moves to, and takes or ignores the mouse from there.
@MainActor
final class PointerPassThrough {
    weak var window: NSWindow?
    /// The window is on screen to take the pointer: shown, and not paused. Without it, the window
    /// ignores the mouse.
    var isActive = false {
        didSet {
            update()
        }
    }
    /// Whether the window takes a press at a Quartz point.
    var takesPointer: (CGPoint) async -> Bool = { _ in true }
    /// The pointer went through the window to the one behind. `isPress`: it pressed there.
    var onWentThrough: (_ isPress: Bool) -> Void = { _ in }

    private var monitors: [Any] = []
    /// The answer under way for the pointer's place.
    private var check: Task<Void, Never>?
    /// The newest place that came meanwhile, to check next.
    private var nextPoint: CGPoint?

    /// Asks `takesPointer` again where the pointer is, such as after a change of what it answers.
    func update() {
        guard isActive else {
            stopWatching()
            window?.ignoresMouseEvents = true
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
