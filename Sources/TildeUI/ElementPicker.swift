import TildeCore
import AppKit
import ApplicationServices

/// An element under the cursor, ready to be annotated.
struct Picked {
    /// Quartz screen frame.
    let frame: CGRect
    let element: Element
    /// Short type label, such as `div` or `button`.
    let chip: String
    /// Lines for the hover label next to the highlight.
    let details: [String]
}

/// Finds the element under a screen point: DOM data in Tilde's browser, the Accessibility
/// element in any other app, or the window when Accessibility is not allowed.
@MainActor
final class ElementPicker {
    private let browser: BrowserController
    private let accessibilityQueue = DispatchQueue(label: "tilde.accessibility")

    init(browser: BrowserController) {
        self.browser = browser
    }

    func pick(at point: CGPoint) async -> Picked? {
        guard let window = topWindow(at: point) else {
            return nil
        }

        if window.number == browser.windowNumber {
            let picked = await browser.inspect(at: point)
            if let picked {
                return picked
            }
        }

        guard AXIsProcessTrusted() else {
            return windowPick(window)
        }

        let picked = await withCheckedContinuation { continuation in
            accessibilityQueue.async {
                continuation.resume(returning: Self.accessibilityPick(at: point, in: window))
            }
        }
        return picked ?? windowPick(window)
    }

    // MARK: - Windows

    struct WindowInfo: Sendable {
        let number: Int
        let pid: pid_t
        let app: String
        let title: String?
        let frame: CGRect
    }

    private func topWindow(at point: CGPoint) -> WindowInfo? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenFrames = NSScreen.screens.map(\.frame.flipped)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for info in list {
            let number = info[kCGWindowNumber as String] as? Int ?? 0
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let app = info[kCGWindowOwnerName as String] as? String ?? "App"
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(point)
            else {
                continue
            }
            // Windows above the overlay never receive its clicks; Window Server owns the menu bar.
            guard alpha > 0.01, layer < OverlayWindow.overlayLevel.rawValue, app != "Window Server",
                  pid != ownPID || number == browser.windowNumber
            else {
                continue
            }
            // Screen-sized windows above the normal layer are invisible backdrops (the Dock's,
            // lock screen shields), not content.
            if layer != 0 && screenFrames.contains(frame) {
                continue
            }

            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WindowInfo(number: number, pid: pid, app: app, title: title, frame: frame)
        }
        return nil
    }

    private func windowPick(_ window: WindowInfo) -> Picked {
        let element = NativeElement(
            app: window.app, window: window.title, role: "AXWindow",
            title: window.title, value: nil, label: nil, identifier: nil, path: []
        )
        let size = "\(Int(window.frame.width))×\(Int(window.frame.height))"
        return Picked(frame: window.frame, element: .native(element), chip: "window", details: ["window  \(size)", window.app])
    }

    // MARK: - Accessibility

    nonisolated private static func accessibilityPick(at point: CGPoint, in window: WindowInfo) -> Picked? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit,
              let frame = frame(of: element),
              frame.width >= 1, frame.height >= 1
        else {
            return nil
        }

        let role: String = attribute(element, kAXRoleAttribute) ?? "AXUnknown"
        let roleDescription = text(element, kAXRoleDescriptionAttribute)
        let title = text(element, kAXTitleAttribute)
        let label = text(element, kAXDescriptionAttribute)
        let value = text(element, kAXValueAttribute)
        let identifier = text(element, "AXIdentifier") ?? domIdentifier(element)

        let native = NativeElement(
            app: window.app,
            window: window.title,
            role: role,
            title: title,
            value: value,
            label: label,
            identifier: identifier,
            path: rolePath(of: element)
        )

        let chip = roleDescription ?? String(role.dropFirst(role.hasPrefix("AX") ? 2 : 0))
        var details = ["\(chip)  \(Int(frame.width))×\(Int(frame.height))"]
        if let name = title ?? label ?? value {
            details.append("\"\(name.prefix(40))\"")
        }
        details.append(window.app)

        return Picked(frame: frame, element: .native(native), chip: chip, details: details)
    }

    nonisolated private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    nonisolated private static func text(_ element: AXUIElement, _ name: String) -> String? {
        guard let value: String = attribute(element, name) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return String(trimmed.prefix(200))
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = axValue(element, kAXPositionAttribute),
              let size: AXValue = axValue(element, kAXSizeAttribute)
        else {
            return nil
        }

        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else {
            return nil
        }
        return CGRect(origin: origin, size: extent)
    }

    nonisolated private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        return (value as! AXValue)
    }

    /// Browsers expose the DOM id and classes of web content as Accessibility attributes.
    nonisolated private static func domIdentifier(_ element: AXUIElement) -> String? {
        let id = text(element, "AXDOMIdentifier")
        let classes: [String] = attribute(element, "AXDOMClassList") ?? []
        if id == nil && classes.isEmpty {
            return nil
        }

        var selector = ""
        if let id {
            selector += "#\(id)"
        }
        for name in classes.prefix(4) {
            selector += ".\(name)"
        }
        return selector
    }

    nonisolated private static func rolePath(of element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = element

        while let node = current, roles.count < 12 {
            let role: String = attribute(node, kAXRoleAttribute) ?? "?"
            if role == kAXApplicationRole {
                break
            }
            roles.append(role)
            current = attribute(node, kAXParentAttribute)
        }
        return roles.reversed()
    }
}
