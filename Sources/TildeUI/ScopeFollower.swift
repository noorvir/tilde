import AppKit

/// Follows the window that a session is limited to: it says when the window may have moved or
/// resized, when its app quits, and when another app comes to the front. The window list's
/// reads check the window too, for windows that send no move notifications.
@MainActor
final class ScopeFollower {
    /// Check the window now. `frame`: its frame as the window itself reported it, which can be
    /// ahead of the window list; nil to read it.
    var onCheck: (_ frame: CGRect?) -> Void = { _ in }
    var onAppQuit: () -> Void = {}
    var onFrontApp: (pid_t?) -> Void = { _ in }

    private var windowObserver: WindowObserver?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var followTimer: Timer?
    private var followsUntil = Date.distantPast

    /// Follows `window`; `page` is the view of Tilde's browser page when it is the browser's.
    func start(_ window: ElementPicker.WindowInfo, page: NSView?) {
        stop()
        windowObserver = WindowObserver(window: window) { [weak self] frame in
            self?.windowMoved(to: frame)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.didTerminateApplicationNotification, in: workspace) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == window.pid {
                self?.onAppQuit()
            }
        }
        observe(NSWorkspace.didActivateApplicationNotification, in: workspace) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.onFrontApp(app?.processIdentifier)
        }
        // The browser's page also moves in its window, such as when the notes panel opens.
        if let page {
            page.postsFrameChangedNotifications = true
            observe(NSView.frameDidChangeNotification, in: .default, object: page) { [weak self] _ in
                self?.onCheck(nil)
            }
        }
    }

    func stop() {
        windowObserver?.invalidate()
        windowObserver = nil
        followTimer?.invalidate()
        followTimer = nil
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers = []
    }

    /// The window moved or resized: check it at once, then at display rate for 300 ms, as move
    /// notifications can come in bursts and end before the last frame.
    private func windowMoved(to frame: CGRect?) {
        onCheck(frame)
        followsUntil = Date().addingTimeInterval(0.3)
        guard followTimer == nil else {
            return
        }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, Date() < self.followsUntil else {
                    timer.invalidate()
                    self?.followTimer = nil
                    return
                }
                self.onCheck(nil)
            }
        }
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter, object: Any? = nil, _ handle: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { note in
            MainActor.assumeIsolated {
                handle(note)
            }
        }
        observers.append((center, token))
    }
}
