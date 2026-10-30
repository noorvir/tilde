import TildeCore
import AppKit
import os
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
    /// The window the element belongs to; set by `ElementPicker.pick`.
    var window: ElementPicker.WindowInfo?
    /// Where the element is on its web page; set for elements in Tilde's browser.
    var anchor: PageAnchor?
    /// The Accessibility element, for elements in other apps, so a note can follow it.
    var tracked: TrackedElement?

    /// The same element after its window moved by `delta`.
    func moved(by delta: CGVector) -> Picked {
        Picked(frame: frame.offsetBy(dx: delta.dx, dy: delta.dy), element: element, chip: chip, details: details, window: window, anchor: anchor, tracked: tracked)
    }
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

    /// With `scope`, picks only in that window, also where another window covers it.
    func pick(at point: CGPoint, in scope: WindowInfo? = nil) async -> Picked? {
        guard let window = window(at: point, in: scope) else {
            return nil
        }

        var picked: Picked?
        if window.number == browser.windowNumber {
            // Only the page knows its elements; Accessibility would give Tilde's own views.
            guard var element = await browser.inspect(at: point) else {
                return nil
            }
            element.window = window
            return element
        }
        if AXIsProcessTrusted() {
            picked = await withCheckedContinuation { continuation in
                accessibilityQueue.async {
                    let started = Date()
                    let picked = Self.accessibilityPick(at: point, in: window)
                    let took = Date().timeIntervalSince(started)
                    if took > 0.05 {
                        Self.log.notice("element lookup took \(Int(took * 1000), privacy: .public) ms in \(window.app, privacy: .public)")
                    }
                    continuation.resume(returning: picked)
                }
            }
        }

        var result = picked ?? windowPick(window)
        result.window = window
        return result
    }

    // MARK: - Windows

    struct WindowInfo: Sendable, Equatable {
        let number: Int
        let pid: pid_t
        let app: String
        let title: String?
        let frame: CGRect
    }

    /// The whole window under a Quartz point, for choosing the window to annotate.
    func windowTarget(at point: CGPoint) -> Picked? {
        guard let window = window(at: point) else {
            return nil
        }
        var picked = windowPick(window)
        picked.window = window
        return picked
    }

    /// Brings an app to the front, such as the agent's chat app after a session. Since macOS 14
    /// an app in the background cannot activate another one, but Accessibility can, so this
    /// uses it when Tilde is allowed and falls back to asking the app.
    static func bringToFront(_ app: NSRunningApplication) {
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        app.activate()
    }

    /// The window with this number as it is now, or nil when it is closed or hidden.
    func currentWindow(number: Int) -> WindowInfo? {
        // Tilde's own windows from AppKit, which knows of them before the window list does.
        if let own = NSApp.window(withWindowNumber: number) {
            guard own.isVisible, !own.isMiniaturized else {
                return nil
            }
            let title = own.title.isEmpty ? nil : own.title
            return WindowInfo(number: number, pid: ProcessInfo.processInfo.processIdentifier, app: "Tilde", title: title, frame: own.frame.flipped)
        }
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]] ?? []
        guard let info = list.first, info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds)
        else {
            return nil
        }
        let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let app = info[kCGWindowOwnerName as String] as? String ?? "App"
        let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WindowInfo(number: number, pid: pid, app: app, title: title, frame: frame)
    }

    /// The topmost window under a Quartz point that annotate mode can pick from, or `scope`
    /// (as it is now) when it is set and holds the point.
    func window(at point: CGPoint, in scope: WindowInfo? = nil) -> WindowInfo? {
        if let scope {
            return currentWindow(number: scope.number).flatMap { $0.frame.contains(point) ? $0 : nil }
        }
        return windowStack().first { $0.frame.contains(point) }
    }

    /// The windows on screen that the user sees and can annotate, front to back: other apps'
    /// windows and Tilde's browser, not Tilde's overlays, HUD or the menu bar.
    nonisolated private static let log = Logger(subsystem: "dev.tilde.app", category: "picker")

    func windowStack() -> [WindowInfo] {
        Self.windowStack(
            browserWindow: browser.windowNumber, screenFrames: NSScreen.screens.map(\.frame.flipped), overlayLevel: OverlayWindow.overlayLevel.rawValue
        )
    }

    /// The same, for a background queue: the window list can take a while to read.
    nonisolated static func windowStack(browserWindow: Int?, screenFrames: [CGRect], overlayLevel: Int) -> [WindowInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        return list.compactMap { info in
            let number = info[kCGWindowNumber as String] as? Int ?? 0
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let app = info[kCGWindowOwnerName as String] as? String ?? "App"
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else {
                return nil
            }
            // Windows above the overlay never receive its clicks; Window Server owns the menu bar.
            guard alpha > 0.01, layer < overlayLevel, app != "Window Server",
                  pid != ownPID || number == browserWindow
            else {
                return nil
            }
            // Screen-sized windows above the normal layer are invisible backdrops (the Dock's,
            // lock screen shields), not content.
            if layer != 0 && screenFrames.contains(frame) {
                return nil
            }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WindowInfo(number: number, pid: pid, app: app, title: title, frame: frame)
        }
    }

    private func windowPick(_ window: WindowInfo) -> Picked {
        let element = NativeElement(
            app: window.app, bundleID: Self.bundleID(of: window.pid), window: window.title, role: "AXWindow",
            title: window.title, value: nil, label: nil, identifier: nil, url: nil, path: []
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
        let ancestors = ancestors(of: element)

        let native = NativeElement(
            app: window.app,
            bundleID: bundleID(of: window.pid),
            window: window.title,
            role: role,
            title: title,
            value: value,
            label: label,
            identifier: identifier,
            url: ancestors.url,
            path: compactPath(ancestors.nodes)
        )

        // The plain role name, capitalised like the role description ("text" from AXStaticText).
        let chip = roleDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? friendlyRoleName(role)
        var details = ["\(chip)  \(Int(frame.width))×\(Int(frame.height))"]
        if let name = title ?? label ?? value {
            details.append("\"\(name.prefix(40))\"")
        }
        details.append(window.app)

        let tracked = TrackedElement(element: element, pid: window.pid, identity: ElementTracker.identity(of: element))
        return Picked(frame: frame, element: .native(native), chip: chip, details: details, tracked: tracked)
    }

    nonisolated private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    nonisolated private static func text(_ element: AXUIElement, _ name: String) -> String? {
        clipped(attribute(element, name), to: 200)
    }

    /// Trimmed text, cut to `limit` characters with an ellipsis; nil when empty.
    nonisolated private static func clipped(_ value: String?, to limit: Int) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count <= limit {
            return trimmed
        }
        return trimmed.prefix(limit) + "…"
    }

    nonisolated private static func bundleID(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
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
        selector(id: text(element, "AXDOMIdentifier"), classes: attribute(element, "AXDOMClassList") ?? [])
    }

    nonisolated private static func selector(id: String?, classes: [String]) -> String? {
        if id == nil && classes.isEmpty {
            return nil
        }

        var selector = ""
        if let id {
            selector += "#\(id)"
        }
        for name in classes.prefix(2) {
            selector += ".\(name)"
        }
        return selector
    }

    /// The element and its ancestors up to the window, outermost first, with the URL of the
    /// nearest web area. Reads each node's attributes in one Accessibility call.
    nonisolated private static func ancestors(of element: AXUIElement) -> (nodes: [AccessibilityNode], url: String?) {
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXURL", kAXParentAttribute] as CFArray
        var nodes: [AccessibilityNode] = []
        var url: String?
        var current: AXUIElement? = element

        while let node = current, nodes.count < 40 {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, names, [], &values) == .success,
                  let values = values as? [Any], values.count == 8
            else {
                break
            }

            let role = values[0] as? String ?? "AXUnknown"
            if role == kAXApplicationRole {
                break
            }
            if url == nil, role == "AXWebArea", let address = values[6] as? URL, address.absoluteString != "about:blank" {
                url = address.absoluteString
            }

            let name = clipped(values[1] as? String, to: 40) ?? clipped(values[2] as? String, to: 40) ?? clipped(values[3] as? String, to: 40)
            let selector = selector(id: clipped(values[4] as? String, to: 40), classes: values[5] as? [String] ?? [])
            nodes.append(AccessibilityNode(role: role, name: name, selector: selector))

            let parent = values[7] as CFTypeRef
            guard CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                break
            }
            current = (parent as! AXUIElement)
        }
        return (nodes.reversed(), url)
    }
}
