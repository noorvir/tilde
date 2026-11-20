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

    /// The answer of a window that shows no elements, such as the iOS Simulator: a note stays
    /// where it was made, and only what is around that point tells whether it is still on
    /// screen. Such an app may also answer with one large group, as the phone in Device Hub.
    var isWholeWindow: Bool {
        let isLargeGroup = chip == "Group" && frame.width >= 150 && frame.height >= 150
        // A browser that has not described its page yet answers with the page itself.
        let isAboutTheWindow = window.map { window in
            frame.width * frame.height >= 0.7 * window.frame.width * window.frame.height
        } ?? false
        return chip == "window" || isLargeGroup || isAboutTheWindow
    }

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
    let windows: WindowStack
    private let accessibilityQueue = DispatchQueue(label: "tilde.accessibility")

    init(browser: BrowserController) {
        self.browser = browser
        windows = WindowStack { [weak browser] in browser?.windowNumber }
    }

    /// With `scope`, picks only in that window, also where another window covers it.
    private let slowApps = SlowApps()
    private var lastPicks: [pid_t: Picked] = [:]

    /// `isMoving`: for the highlight under a moving pointer, not for a click.
    func pick(at point: CGPoint, isMoving: Bool = false, in scope: WindowInfo? = nil) async -> Picked? {
        // A click picks from the windows as they are now; a moving pointer from the last read.
        if !isMoving, scope == nil, windows.isRunning {
            _ = await windows.refreshed()
        }
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
        // While the pointer moves, an app that answers slowly must not hold up the highlight.
        if AXIsProcessTrusted(), !isMoving || !slowApps.isSlow(window.pid) {
            let slowApps = self.slowApps
            picked = await withCheckedContinuation { continuation in
                accessibilityQueue.async {
                    let started = Date()
                    let picked = Self.accessibilityPick(at: point, in: window, isMoving: isMoving)
                    let took = Date().timeIntervalSince(started)
                    slowApps.record(window.pid, took: took)
                    if took > 0.05 {
                        Self.log.notice("element lookup took \(Int(took * 1000), privacy: .public) ms in \(window.app, privacy: .public)")
                    }
                    continuation.resume(returning: picked)
                }
            }
        }

        // An app too slow to ask keeps its last answer under the pointer, so that the highlight
        // does not jump to the whole window and back.
        if picked != nil {
            lastPicks[window.pid] = picked
        } else if isMoving, slowApps.isSlow(window.pid), let last = lastPicks[window.pid], last.frame.contains(point) {
            picked = last
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

    /// Whether a window is in full screen, so on a Space of its own, which is off screen while
    /// another Space shows: a normal window with its display's width and bottom edge. On a
    /// display with a notch, it can start under the notch.
    nonisolated static func isInFullScreen(frame: CGRect, layer: Int, displays: [CGRect]) -> Bool {
        layer == 0 && displays.contains { display in
            display.contains(frame) && frame.width == display.width && frame.maxY == display.maxY && frame.height >= display.height - 50
        }
    }

    /// The window with this number as it is now, or nil when it is closed, hidden or minimized.
    /// A window in full screen stays while another Space shows.
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
        guard let info = list.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds)
        else {
            return nil
        }
        let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
        if info[kCGWindowIsOnscreen as String] as? Bool != true {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let isAppHidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? true
            guard !isAppHidden, Self.isInFullScreen(frame: frame, layer: layer, displays: Self.displayFrames) else {
                return nil
            }
        }
        let app = info[kCGWindowOwnerName as String] as? String ?? "App"
        let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WindowInfo(number: number, pid: pid, app: app, title: title, frame: frame)
    }

    /// The displays' frames in Quartz coordinates.
    private static var displayFrames: [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.map(CGDisplayBounds)
    }

    /// The topmost window under a Quartz point that annotate mode can pick from, or `scope`
    /// (as it is now) when it is set and holds the point.
    func window(at point: CGPoint, in scope: WindowInfo? = nil) -> WindowInfo? {
        if let scope {
            return scopedWindow(scope).flatMap { $0.frame.contains(point) ? $0 : nil }
        }
        return windows.window(at: point)
    }

    /// The scoped window as it is now: Tilde's own from AppKit; another app's as the session
    /// follows it, which ends the scope when the window goes.
    private func scopedWindow(_ scope: WindowInfo) -> WindowInfo? {
        if NSApp.window(withWindowNumber: scope.number) != nil || !windows.isRunning {
            return currentWindow(number: scope.number)
        }
        return scope
    }

    nonisolated private static let log = Logger(subsystem: "dev.tilde.app", category: "picker")

    private func windowPick(_ window: WindowInfo) -> Picked {
        let element = NativeElement(
            app: window.app, bundleID: Self.bundleID(of: window.pid), window: window.title, role: "AXWindow",
            title: window.title, value: nil, label: nil, identifier: nil, url: nil, path: []
        )
        let size = "\(Int(window.frame.width))×\(Int(window.frame.height))"
        return Picked(frame: window.frame, element: .native(element), chip: "window", details: ["window  \(size)", window.app])
    }

    // MARK: - Accessibility

    nonisolated private static func accessibilityPick(at point: CGPoint, in window: WindowInfo, isMoving: Bool) -> Picked? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else {
            return nil
        }
        // Chromium and WebKit answer with the whole page at first and find the element
        // meanwhile. A click must get the element; a moving pointer asks again anyway.
        for _ in 0..<(isMoving ? 0 : 4) {
            guard let found = hit, let role: String = found.attribute(kAXRoleAttribute), ["AXScrollArea", "AXWebArea"].contains(role) else {
                break
            }
            Thread.sleep(forTimeInterval: 0.06)
            AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        }
        guard let element = hit,
              let frame = element.frame,
              frame.width >= 1, frame.height >= 1
        else {
            return nil
        }

        let role: String = element.attribute(kAXRoleAttribute) ?? "AXUnknown"
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

    nonisolated private static func text(_ element: AXUIElement, _ name: String) -> String? {
        clipped(element.attribute(name), to: 200)
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

    /// Browsers expose the DOM id and classes of web content as Accessibility attributes.
    nonisolated private static func domIdentifier(_ element: AXUIElement) -> String? {
        selector(id: text(element, "AXDOMIdentifier"), classes: element.attribute("AXDOMClassList") ?? [])
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

/// Apps whose Accessibility answers are too slow for a moving pointer. Three slow answers in a
/// row put an app here for 10 seconds; it is asked again after that.
final class SlowApps: @unchecked Sendable {
    private struct Record {
        var slowInARow = 0
        var until: Date?
    }
    private static let slow: TimeInterval = 0.2
    private let lock = NSLock()
    private var records: [pid_t: Record] = [:]

    func isSlow(_ pid: pid_t, now: Date = Date()) -> Bool {
        lock.withLock { records[pid]?.until.map { $0 > now } ?? false }
    }

    func record(_ pid: pid_t, took: TimeInterval, now: Date = Date()) {
        lock.withLock {
            var record = records[pid] ?? Record()
            record.slowInARow = took >= Self.slow ? record.slowInARow + 1 : 0
            record.until = record.slowInARow >= 3 ? now.addingTimeInterval(10) : nil
            records[pid] = record
        }
    }
}
