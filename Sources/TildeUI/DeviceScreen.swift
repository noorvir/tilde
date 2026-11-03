import AppKit
import ApplicationServices

/// The screen of a simulated device inside its window, such as the phone in Device Hub. Its
/// zoom can change; a note on it is kept relative to it, so the note follows the zoom.
enum DeviceScreen {
    /// The device's screen: the largest group that only wraps a group of the same frame, with
    /// a device's shape, inside the window. Call off the main thread: it waits for the app.
    static func find(pid: pid_t, windowFrame: CGRect) -> CGRect? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        guard let window = windows.first(where: { frame(of: $0).map { $0.insetBy(dx: -2, dy: -2).contains(windowFrame.insetBy(dx: 2, dy: 2)) } ?? false }) else {
            return nil
        }

        var best: CGRect?
        var queue = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            let role: String? = attribute(element, kAXRoleAttribute)
            if role == kAXGroupRole, children.count == 1, let rect = frame(of: element), let inner = frame(of: children[0]),
               inner == rect, isDeviceShaped(rect, in: windowFrame), rect.width * rect.height > (best.map { $0.width * $0.height } ?? 0)
            {
                best = rect
            }
            if depth < 10 {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return best
    }

    /// A phone or tablet held either way, narrower than the window. Zoomed in, it can reach past
    /// the window's edges.
    static func isDeviceShaped(_ rect: CGRect, in window: CGRect) -> Bool {
        let ratio = max(rect.width, rect.height) / max(min(rect.width, rect.height), 1)
        return ratio > 1.2 && ratio < 2.6 && min(rect.width, rect.height) >= 80 && rect.width < window.width * 0.9 && rect.intersects(window)
    }

    /// Where a point of the device's screen at `old` is when the screen is at `new`.
    static func map(_ point: CGPoint, from old: CGRect, to new: CGRect) -> CGPoint {
        CGPoint(
            x: new.minX + (point.x - old.minX) / old.width * new.width,
            y: new.minY + (point.y - old.minY) / old.height * new.height
        )
    }

    static func map(_ rect: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        let origin = map(rect.origin, from: old, to: new)
        return CGRect(x: origin.x, y: origin.y, width: rect.width / old.width * new.width, height: rect.height / old.height * new.height)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success
        else {
            return nil
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        // swiftlint:disable:next force_cast
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}
