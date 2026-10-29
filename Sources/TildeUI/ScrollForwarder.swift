import AppKit

/// Sends scroll-wheel and trackpad scroll events that reach an overlay on to the window under
/// the pointer, so pages scroll while annotating. Each event keeps its deltas, phases and
/// momentum, and is aimed at that window: Tilde's own windows get it directly, other apps'
/// windows by posting it to their process (which needs Accessibility, as hover does).
@MainActor
enum ScrollForwarder {
    /// `point` and `window.frame` are in Quartz coordinates.
    @discardableResult
    static func forward(_ event: NSEvent, at point: CGPoint, to window: ElementPicker.WindowInfo) -> Bool {
        guard let copy = event.cgEvent?.copy() else {
            return false
        }
        copy.location = point
        for field in [CGEventField.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, windowNumberField] {
            copy.setIntegerValueField(field, value: Int64(window.number))
        }
        // Window-relative location, from the window's top left, so the app finds the view.
        setWindowLocation?(copy, CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY))

        if window.pid == ProcessInfo.processInfo.processIdentifier {
            guard let own = NSApp.window(withWindowNumber: window.number),
                  let aimed = setWindowLocation == nil ? nil : NSEvent(cgEvent: copy), aimed.window === own
            else {
                return false
            }
            own.sendEvent(aimed)
            return true
        }
        guard AXIsProcessTrusted() else {
            return false
        }
        copy.postToPid(window.pid)
        return true
    }

    /// The event field AppKit reads the target window from; it has no public name.
    private static let windowNumberField = CGEventField(rawValue: 51)!

    /// Sets an event's window-relative location; AppKit has no public way to build a scroll
    /// event for another window. Missing on a future macOS, forwarding to Tilde's windows stops.
    private static let setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
    }()
}
