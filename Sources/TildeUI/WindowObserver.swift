import AppKit
import ApplicationServices

/// Calls `onChange` as soon as a window moves, resizes, comes forward or closes, so the window
/// scope follows it without lag. Tilde's own windows use AppKit notifications; other apps' windows use
/// Accessibility notifications (when Tilde is allowed). It passes the window's new frame in
/// Quartz coordinates, from the window itself, as the window list can lag behind; nil when
/// the window closed or the frame is unknown.
@MainActor
final class WindowObserver {
    private var tokens: [NSObjectProtocol] = []
    private var observer: AXObserver?
    private var element: AXUIElement?
    private let onChange: (CGRect?) -> Void

    init?(window: ElementPicker.WindowInfo, onChange: @escaping (CGRect?) -> Void) {
        self.onChange = onChange
        if window.pid == ProcessInfo.processInfo.processIdentifier {
            guard let own = NSApp.windows.first(where: { $0.windowNumber == window.number }) else {
                return nil
            }
            let center = NotificationCenter.default
            // A click raises the window above its overlay; coming forward is a change too.
            tokens = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification].map { name in
                center.addObserver(forName: name, object: own, queue: .main) { [weak own] _ in
                    MainActor.assumeIsolated { onChange(own?.frame.flipped) }
                }
            } + [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification].map { name in
                center.addObserver(forName: name, object: own, queue: .main) { _ in
                    MainActor.assumeIsolated { onChange(nil) }
                }
            }
            return
        }
        guard AXIsProcessTrusted(), let element = Self.element(for: window) else {
            return nil
        }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else {
                return
            }
            let observer = Unmanaged<WindowObserver>.fromOpaque(context).takeUnretainedValue()
            let moved = [kAXMovedNotification, kAXResizedNotification].contains(notification as String)
            let frame = moved ? WindowObserver.frame(of: element) : nil
            MainActor.assumeIsolated { observer.onChange(frame) }
        }
        guard AXObserverCreate(window.pid, callback, &observer) == .success, let observer else {
            return nil
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        self.element = element
    }

    func invalidate() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens = []
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        element = nil
    }

    /// The app's Accessibility window with the same frame as the Quartz window.
    nonisolated private static func element(for window: ElementPicker.WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            return nil
        }
        return windows.first { candidate in
            frame(of: candidate).map { abs($0.minX - window.frame.minX) < 2 && abs($0.minY - window.frame.minY) < 2 && abs($0.width - window.frame.width) < 2 } ?? false
        }
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success
        else {
            return nil
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}
