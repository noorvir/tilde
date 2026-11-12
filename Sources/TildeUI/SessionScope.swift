import AppKit
import os

/// What the session annotates and records: a window (which limits the session to it), a
/// screen or a phone; nil until the user chooses, which means everything on screen. A chosen
/// window is followed while it is on screen.
@MainActor
final class SessionScope: ObservableObject {
    @Published private(set) var source: RecordingSource?

    /// The source is another one.
    var onChange: () -> Void = {}
    /// The window was checked. `delta`: how far it moved, or nil when it is where it was.
    var onCheck: (_ delta: CGVector?) -> Void = { _ in }
    /// The window closed, was hidden or minimised, or its app quit.
    var onGone: () -> Void = {}
    /// Another app came to the front, or the window is another one.
    var onFrontApp: (pid_t?) -> Void = { _ in }
    /// Whether the session's source can change now: no clip in progress, not choosing.
    var canChange: () -> Bool = { true }
    /// The browser's window did not come on screen in time for `limitToBrowser()`.
    var onBrowserMissing: () -> Void = {}

    private let picker: ElementPicker
    private let browser: BrowserController
    private let follower = ScopeFollower()
    /// What annotating was limited to (nothing, or Tilde's browser) before recording mode,
    /// which it gets back after.
    private var annotationSource: RecordingSource?
    private var waitsForBrowser = false
    private let browserTime = Countdown()
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")

    init(picker: ElementPicker, browser: BrowserController) {
        self.picker = picker
        self.browser = browser
    }

    /// The window annotations are limited to; nil means anything on screen.
    var window: ElementPicker.WindowInfo? {
        if case .window(let window) = source {
            return window
        }
        return nil
    }

    /// Whether the session is limited to Tilde's browser, which then shows the notes panel.
    var isBrowser: Bool {
        window != nil && window?.number == browser.windowNumber
    }

    /// The name the HUD shows for the window: its app's name.
    var name: String? {
        guard let window else {
            return nil
        }
        if window.pid == ProcessInfo.processInfo.processIdentifier {
            return "Tilde Browser"
        }
        return NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? window.app
    }

    /// Annotates and records `source` from now on: a window limits the session to it, a screen
    /// or a phone lifts the limit; nil is everything on screen.
    func set(_ source: RecordingSource?) {
        let old = window
        self.source = source
        if window != old {
            log.notice("scope \(self.window.map { "window \($0.number) of \($0.app)" } ?? "none", privacy: .public)")
        }
        follower.stop()
        onChange()
        guard let window else {
            return
        }

        follower.onCheck = { [weak self] frame in self?.check(frame: frame) }
        follower.onAppQuit = { [weak self] in
            if self?.window?.pid == window.pid {
                self?.onGone()
            }
        }
        follower.onFrontApp = { [weak self] pid in self?.onFrontApp(pid) }
        follower.start(window, page: window.number == browser.windowNumber ? browser.webView : nil)
        onFrontApp(Self.frontmostPID)
    }

    /// The user's choice: a window as it is now. A request for the browser's window no longer
    /// counts.
    func choose(_ source: RecordingSource) {
        dropBrowserRequest()
        if case .window(let window) = source {
            set(.window(picker.currentWindow(number: window.number) ?? window))
        } else {
            set(source)
        }
    }

    /// A session starts or ends: nothing is chosen, and nothing waits.
    func reset() {
        dropBrowserRequest()
        set(nil)
    }

    /// Takes the window's new frame, or says that the window is gone, hidden or minimised.
    /// `frame`: the window's frame as the window itself reported it, which can be ahead of the
    /// window list.
    func check(frame: CGRect? = nil) {
        guard let window else {
            return
        }
        guard var current = picker.currentWindow(number: window.number) else {
            onGone()
            return
        }
        if let frame {
            current = ElementPicker.WindowInfo(number: current.number, pid: current.pid, app: current.app, title: current.title, frame: frame)
        }

        var delta: CGVector?
        if current.frame != window.frame {
            source = .window(current)
            delta = CGVector(dx: current.frame.minX - window.frame.minX, dy: current.frame.minY - window.frame.minY)
        }
        onCheck(delta)
    }

    /// The window list was read: also for windows that send no move notifications, and for a
    /// window that came forward over its overlay.
    func windowsRead() {
        check(frame: follower.frame)
        if waitsForBrowser {
            takeBrowser()
        }
    }

    // MARK: - Recording mode

    func enterRecording() {
        annotationSource = source
    }

    /// What a clip recorded does not limit the notes: back to what annotating had.
    func exitRecording() {
        if source != annotationSource {
            set(annotationSource)
        }
    }

    // MARK: - Tilde's browser

    /// Limits the session to the window of Tilde's browser once that window is on screen: after
    /// this turn, and at each read of the window list, while the source can change and the
    /// user chose no other one. A window that is not there 0.8 s from now never came.
    func limitToBrowser() {
        waitsForBrowser = true
        Task { [weak self] in
            self?.takeBrowser()
        }
        browserTime.start(0.8) { [weak self] in
            self?.stopWaitingForBrowser()
        }
    }

    @discardableResult
    private func takeBrowser() -> Bool {
        guard waitsForBrowser, canChange(), let number = browser.windowNumber, let window = picker.currentWindow(number: number) else {
            return false
        }
        dropBrowserRequest()
        if self.window?.number != number {
            set(.window(window))
        }
        return true
    }

    private func stopWaitingForBrowser() {
        guard waitsForBrowser else {
            return
        }
        let isAllowed = canChange()
        let isTaken = takeBrowser()
        dropBrowserRequest()
        if isAllowed, !isTaken {
            onBrowserMissing()
        }
    }

    private func dropBrowserRequest() {
        waitsForBrowser = false
        browserTime.cancel()
    }

    // MARK: - Rules

    /// Whether annotate mode takes a Quartz point: anywhere, or only inside the scoped window.
    nonisolated static func allows(_ point: CGPoint, scope: CGRect?) -> Bool {
        scope?.contains(point) ?? true
    }

    /// The part of a dragged region inside the scoped window, or nil when none is left.
    nonisolated static func clamped(_ rect: CGRect, scope: CGRect?) -> CGRect? {
        guard let scope else {
            return rect
        }
        let inside = rect.intersection(scope)
        return inside.isNull || inside.width < 8 || inside.height < 8 ? nil : inside
    }

    /// Whether a session limited to one window waits while another app is in front.
    nonisolated static func autoPauses(frontmost: pid_t?, scopePID: pid_t?, ownPID: pid_t) -> Bool {
        guard let scopePID, let frontmost else {
            return false
        }
        return frontmost != scopePID && frontmost != ownPID
    }

    /// The frontmost app. Right after Tilde activates, NSWorkspace can still name the app
    /// before it, so Tilde's own state wins.
    private static var frontmostPID: pid_t? {
        if NSApp.isActive {
            return ProcessInfo.processInfo.processIdentifier
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

#if DEBUG
extension SessionScope {
    /// Sets the source without following its window.
    func setStateForTesting(source: RecordingSource?) {
        self.source = source
    }
}
#endif
