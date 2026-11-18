import AppKit
import ApplicationServices

/// Where the keyboard is when a key is typed during a session.
enum KeyFocus: Equatable {
    /// A window of Tilde: its own key handling takes the key.
    case tilde
    /// An element of another app that takes text: a text field or area, a search field, a
    /// combo box, editable web content, or a terminal.
    case text
    /// Anything else in another app, such as a button, a list or a page.
    case other
    /// The app did not answer in time, or could not say.
    case unknown

    /// How long the focused app may take to answer: the key waits for it.
    static let timeout: Float = 0.05

    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, "AXSearchField", kAXComboBoxRole]
    /// Terminals whose text view may have no accessibility role of text.
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper",
    ]

    /// The apps asked to build their tree of elements. Only the tap's thread uses it.
    nonisolated(unsafe) private static var askedForTree: Set<pid_t> = []

    /// The system's keyboard focus now. Each call to the focused app waits at most `timeout`.
    /// Call on one thread only, the session key tap's.
    static func current() -> KeyFocus {
        let system = AXUIElementCreateSystemWide()
        var appValue: CFTypeRef?
        let appError = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue)
        if appError == .noValue {
            return .other
        }
        guard appError == .success, let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let app = appValue as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        if pid == getpid() {
            return .tilde
        }
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, terminals.contains(bundle) {
            return .text
        }

        AXUIElementSetMessagingTimeout(app, timeout)
        // Chromium and Electron apps build their tree of elements only when asked.
        if askedForTree.insert(pid).inserted {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var elementValue: CFTypeRef?
        let elementError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &elementValue)
        if elementError == .noValue || elementError == .attributeUnsupported {
            return .other
        }
        guard elementError == .success, let elementValue, CFGetTypeID(elementValue) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let element = elementValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)

        var role: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if roleError == .cannotComplete {
            return .unknown
        }
        if let role = role as? String, textRoles.contains(role) {
            return .text
        }
        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable) == .success, isSettable.boolValue {
            return .text
        }
        // Editable web content that is not a text field, such as a rich text editor.
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editable) == .success {
            return .text
        }
        return .other
    }
}

/// While a session is on screen, the session's single keys also work after a click in another
/// app gave that app the keyboard. Every key down passes through `onKey` on the tap's own
/// thread, so typing never waits for Tilde's main thread; it is dropped when `onKey` returns
/// true. Needs Accessibility; without it, nothing is tapped.
final class SessionKeyTap: @unchecked Sendable {
    private let onKey: (CGEvent) -> Bool
    private var port: CFMachPort?
    private var loop: CFRunLoop?

    init(onKey: @escaping (CGEvent) -> Bool) {
        self.onKey = onKey
    }

    /// Call on the main thread, as `stop()`.
    func start() {
        guard port == nil else {
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, info in
            let tap = Unmanaged<SessionKeyTap>.fromOpaque(info!).takeUnretainedValue()
            // macOS turns a tap off when it is slow; the next key must reach it again.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = tap.port {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            return tap.onKey(event) ? nil : Unmanaged.passUnretained(event)
        }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "tilde.session-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func stop() {
        guard let port else {
            return
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop {
            CFRunLoopStop(loop)
        }
        self.port = nil
        loop = nil
    }
}
