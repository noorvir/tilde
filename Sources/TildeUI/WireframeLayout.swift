import AppKit
import ApplicationServices

/// The layout of an app's window around a point, from Accessibility: the lines that a
/// wireframe's components snap to.
enum WireframeLayout {
    struct Lines: Equatable, Sendable {
        /// The element at the point, its containers up to the window, and their children.
        var rects: [CGRect] = []
        /// The larger containers, innermost first, whose thirds and halves count as well.
        var containers: [CGRect] = []
    }

    /// Reads the layout at a Quartz point in the app `pid`. It asks the app, so it runs off
    /// the main thread.
    static func lines(at point: CGPoint, pid: pid_t) -> Lines {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var current = hit else {
            return Lines()
        }

        var lines = Lines()
        for _ in 0..<12 {
            guard let (role, frame) = roleAndFrame(of: current), role != kAXWindowRole, role != kAXApplicationRole else {
                break
            }
            lines.rects.append(frame)
            if frame.width >= 120, frame.height >= 80, lines.containers.count < 2 {
                lines.containers.append(frame)
            }
            var children: CFTypeRef?
            if lines.rects.count < 300, AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                lines.rects += children.prefix(60).compactMap { roleAndFrame(of: $0)?.frame }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else {
                break
            }
            current = parent as! AXUIElement
        }
        lines.rects = lines.rects.filter { $0.width >= 4 && $0.height >= 4 }
        return lines
    }

    private static func roleAndFrame(of element: AXUIElement) -> (role: String, frame: CGRect)? {
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
