import AppKit

/// The windows on screen that the user sees and can annotate, front to back, as the window list
/// last gave them: other apps' windows and Tilde's browser, not Tilde's overlays, HUD or the
/// menu bar. It is the one reader of the window list during a session. It reads off the main
/// thread when an app comes to the front, when a mouse button comes up or a window is dragged,
/// and once a second, so a pointer move or a scroll only looks up the last result.
@MainActor
final class WindowStack {
    private(set) var windows: [ElementPicker.WindowInfo] = []
    /// After each read, with whether the stack is another one: a window moved, came, went or
    /// changed its order.
    var onRead: (_ isChanged: Bool) -> Void = { _ in }
    /// A mouse button came up or a key went down, here or in another app.
    var onInput: () -> Void = {}

    private let browserWindow: () -> Int?
    private let queue = DispatchQueue(label: "tilde.windows")
    private var isReading = false
    private var readsAgain = false
    private var waiting: [CheckedContinuation<[ElementPicker.WindowInfo], Never>] = []
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var monitors: [Any] = []
    private var lastDragRead = Date.distantPast

    init(browserWindow: @escaping () -> Int?) {
        self.browserWindow = browserWindow
    }

    var isRunning: Bool {
        timer != nil
    }

    /// Reads the windows now, then keeps them current until `stop()`.
    func start() {
        guard timer == nil else {
            return
        }
        windows = Self.read(browserWindow: browserWindow(), screenFrames: Self.screenFrames, overlayLevel: Self.overlayLevel)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        let events: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .keyDown]
        let handle: (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                self?.inputHappened(type)
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handle) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activation {
            NSWorkspace.shared.notificationCenter.removeObserver(activation)
        }
        activation = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        windows = []
    }

    /// The topmost window under a Quartz point, from the last read; read now outside a session.
    func window(at point: CGPoint) -> ElementPicker.WindowInfo? {
        let windows = isRunning ? windows : Self.read(browserWindow: browserWindow(), screenFrames: Self.screenFrames, overlayLevel: Self.overlayLevel)
        return windows.first { $0.frame.contains(point) }
    }

    /// Reads the windows again, off the main thread. Calls while a read is under way make one
    /// more read after it, not one each.
    func refresh() {
        guard !isReading else {
            readsAgain = true
            return
        }
        isReading = true
        let browserWindow = browserWindow()
        let screenFrames = Self.screenFrames
        let overlayLevel = Self.overlayLevel
        queue.async { [weak self] in
            let windows = Self.read(browserWindow: browserWindow, screenFrames: screenFrames, overlayLevel: overlayLevel)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(windows)
                }
            }
        }
    }

    /// The windows from a read that starts now, such as for a click, which must not pick a
    /// window from before it.
    func refreshed() async -> [ElementPicker.WindowInfo] {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if isReading {
                readsAgain = true
            } else {
                refresh()
            }
        }
    }

    private func apply(_ read: [ElementPicker.WindowInfo]) {
        isReading = false
        let isChanged = read != windows
        if isRunning {
            windows = read
        }
        if readsAgain {
            readsAgain = false
            refresh()
        } else {
            let waiting = self.waiting
            self.waiting = []
            waiting.forEach { $0.resume(returning: read) }
        }
        if isRunning {
            onRead(isChanged)
        }
    }

    /// A drag moves windows: read at most four times a second while it lasts.
    private func inputHappened(_ type: NSEvent.EventType) {
        if type == .leftMouseDragged {
            guard Date().timeIntervalSince(lastDragRead) >= 0.25 else {
                return
            }
            lastDragRead = Date()
        } else {
            onInput()
        }
        if type != .keyDown {
            refresh()
        }
    }

    private static var screenFrames: [CGRect] {
        NSScreen.screens.map(\.frame.flipped)
    }

    private static var overlayLevel: Int {
        OverlayWindow.overlayLevel.rawValue
    }

    nonisolated static func read(browserWindow: Int?, screenFrames: [CGRect], overlayLevel: Int) -> [ElementPicker.WindowInfo] {
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
            return ElementPicker.WindowInfo(number: number, pid: pid, app: app, title: title, frame: frame)
        }
    }
}
