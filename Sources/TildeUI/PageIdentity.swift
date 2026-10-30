import AppKit
import ApplicationServices
import os

/// Which page a window shows: its web address, or else its title. It tells pages apart in
/// browsers (also when a page changes its address without loading) and in most apps.
struct PageIdentity: Equatable, Sendable, Codable {
    /// The address without its fragment; nil outside web content.
    var url: String?
    var title: String?

    /// Whether this is the same page: true or false when the identities can tell, nil when
    /// they cannot, such as in the Simulator, whose window title never changes.
    func isSamePage(as other: PageIdentity) -> Bool? {
        if let url, let otherURL = other.url {
            return url == otherURL
        }
        if let title, let otherTitle = other.title, title != otherTitle {
            return false
        }
        return nil
    }

    private static let askedApps = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// Chromium browsers and Electron apps describe web content only when asked, and it takes
    /// them a moment: ask when a session starts, so the first note finds its element.
    static func askAppsToDescribeWebContent() {
        guard AXIsProcessTrusted() else {
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        Task.detached {
            for pid in apps {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.25)
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
        }
    }

    /// Reads a window's page through Accessibility. Call off the main thread: it waits for
    /// the other app.
    static func read(pid: pid_t, windowFrame: CGRect) -> PageIdentity? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // The app may have opened after the session started. Asked once: it is not free.
        if askedApps.withLock({ $0.insert(pid).inserted }) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        guard let window = windows.first(where: { frame(of: $0).map { $0.insetBy(dx: -2, dy: -2).contains(windowFrame.insetBy(dx: 2, dy: 2)) } ?? false }) else {
            return nil
        }
        let title: String? = attribute(window, kAXTitleAttribute)
        return PageIdentity(url: webAddress(in: window), title: title)
    }

    /// The address of the first web area, breadth first, within a budget.
    private static func webAddress(in window: AXUIElement) -> String? {
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let element = queue.removeFirst()
            visited += 1
            let role: String? = attribute(element, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let url: URL = attribute(element, "AXURL") {
                    return withoutFragment(url.absoluteString)
                }
                if let text: String = attribute(element, "AXURL") {
                    return withoutFragment(text)
                }
            }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children)
        }
        return nil
    }

    /// A plain fragment is a place on the page; `#/` and `#!` are routes of a single page app.
    static func withoutFragment(_ address: String) -> String {
        guard let hash = address.firstIndex(of: "#") else {
            return address
        }
        let fragment = address[address.index(after: hash)...]
        return fragment.hasPrefix("/") || fragment.hasPrefix("!") ? address : String(address[..<hash])
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute)
        else {
            return nil
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else {
            return nil
        }
        if T.self == AXValue.self, CFGetTypeID(value) == AXValueGetTypeID() {
            return (value as! T)
        }
        return value as? T
    }
}
