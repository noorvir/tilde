import AppKit
import ApplicationServices
import os

/// Calls `onChange` as soon as a window moves, resizes, comes forward or closes, so the window
/// scope follows it without lag. Tilde's own windows use AppKit notifications; other apps' windows use
/// Accessibility notifications (when Tilde is allowed). It passes the window's new frame in
/// Quartz coordinates, from the window itself, as the window list can lag behind; nil when
/// the window closed or the frame is unknown.
@MainActor
final class WindowObserver {
    private var tokens: [NSObjectProtocol] = []
    private var observer: AXObserver?
    private var reader: FrameReader?
    private weak var own: NSWindow?
    private let onChange: (CGRect?) -> Void

    /// The window's frame now, in Quartz coordinates, from the window itself: ahead of the
    /// window list while the window moves. Nil when it is unknown.
    var frame: CGRect? {
        if let own {
            return own.frame.flipped
        }
        return reader?.latest
    }

    init?(window: ElementPicker.WindowInfo, onChange: @escaping (CGRect?) -> Void) {
        self.onChange = onChange
        if window.pid == ProcessInfo.processInfo.processIdentifier {
            guard let own = NSApp.windows.first(where: { $0.windowNumber == window.number }) else {
                return nil
            }
            self.own = own
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
            MainActor.assumeIsolated {
                if moved {
                    observer.reader?.wake()
                } else {
                    observer.onChange(nil)
                }
            }
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
        reader = FrameReader(element: element, frame: window.frame) { frame in
            onChange(frame)
        }
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
        reader?.stop()
        reader = nil
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
            candidate.frame.map { abs($0.minX - window.frame.minX) < 2 && abs($0.minY - window.frame.minY) < 2 && abs($0.width - window.frame.width) < 2 } ?? false
        }
    }
}

/// Reads another app's window frame through Accessibility on a thread of its own, at display
/// rate while the window moves, and hands only the newest frame to the main thread. A read
/// waits for the app, which can take 100 ms while it moves its window: the main thread, which
/// moves what follows the window, never waits for it.
private final class FrameReader: @unchecked Sendable {
    private struct State {
        var latest: CGRect?
        /// Reads go on until then; a move notification moves it on.
        var readsUntil = Date.distantPast
        var isReading = false
        var isPosting = false
        var isStopped = false
    }

    private let element: AXUIElement
    private let state: OSAllocatedUnfairLock<State>
    private let queue = DispatchQueue(label: "dev.tilde.window-frame", qos: .userInteractive)
    private let onFrame: @MainActor (CGRect) -> Void

    init(element: AXUIElement, frame: CGRect, onFrame: @escaping @MainActor (CGRect) -> Void) {
        self.element = element
        self.onFrame = onFrame
        state = OSAllocatedUnfairLock(initialState: State(latest: frame))
    }

    /// The newest frame read; it never waits for the app.
    var latest: CGRect? {
        state.withLock { $0.latest }
    }

    /// The window moved: read it at display rate for the next 300 ms, as move notifications
    /// come in bursts and end before the last frame.
    func wake() {
        let starts = state.withLock { state in
            state.readsUntil = Date().addingTimeInterval(0.3)
            guard !state.isReading, !state.isStopped else {
                return false
            }
            state.isReading = true
            return true
        }
        if starts {
            queue.async { [self] in read() }
        }
    }

    func stop() {
        state.withLock { $0.isStopped = true }
    }

    private func read() {
        while true {
            let started = Date()
            let frame = element.frame
            let goesOn = state.withLock { state in
                if let frame, frame != state.latest {
                    state.latest = frame
                    if !state.isPosting {
                        state.isPosting = true
                        DispatchQueue.main.async { [self] in post() }
                    }
                }
                guard !state.isStopped, started < state.readsUntil else {
                    state.isReading = false
                    return false
                }
                return true
            }
            guard goesOn else {
                return
            }
            let next = started.addingTimeInterval(1.0 / 120)
            if next > Date() {
                Thread.sleep(until: next)
            }
        }
    }

    /// On the main thread: the newest frame only, however many were read meanwhile.
    private func post() {
        let frame = state.withLock { state -> CGRect? in
            state.isPosting = false
            return state.isStopped ? nil : state.latest
        }
        guard let frame else {
            return
        }
        MainActor.assumeIsolated { onFrame(frame) }
    }
}
