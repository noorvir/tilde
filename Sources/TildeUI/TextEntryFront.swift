import AppKit

/// Puts Tilde in front while a text view of one of its panels has the keyboard, and gives the
/// front back after. The panels do not activate Tilde, so the app behind them stays in front,
/// and a tool that pastes into the focused field of the app in front, such as a dictation app,
/// would look for its text there.
@MainActor
enum TextEntryFront {
    /// The app that was in front, and the panel that Tilde is in front for.
    private static var lender: NSRunningApplication?
    private static weak var holder: NSPanel?
    private static var observers: [NSObjectProtocol] = []

    /// A text view of `panel` has the keyboard.
    static func take(for panel: NSPanel) {
        if lender != nil {
            holder = panel
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front != .current else {
            return
        }
        stopObserving()
        lender = front
        holder = panel
        NSApp.activate()
        // Another app in front while the user writes is the user's choice: it keeps the front.
        observe(NSWorkspace.didActivateApplicationNotification, from: NSWorkspace.shared.notificationCenter) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app != .current {
                lender = nil
                holder = nil
                stopObserving()
            }
        }
    }

    /// The text view of `panel` let go of the keyboard for good: its box closed, or its
    /// editing ended.
    static func giveBack(from panel: NSPanel) {
        guard holder === panel, let app = lender else {
            return
        }
        lender = nil
        holder = nil
        stopObserving()
        guard !app.isTerminated else {
            return
        }

        // Tilde loses its key window with the front. The window that has the keyboard then,
        // such as the overlay, takes it again, as before the text view had it.
        var keyWindow: NSWindow?
        observe(NSApplication.willResignActiveNotification, from: .default) { _ in
            keyWindow = NSApp.keyWindow
        }
        observe(NSApplication.didResignActiveNotification, from: .default) { _ in
            stopObserving()
            if let keyWindow, keyWindow.isVisible, keyWindow.canBecomeKey {
                keyWindow.makeKey()
            }
        }
        NSApp.yieldActivation(to: app)
        ElementPicker.bringToFront(app)
    }

    private static func observe(_ name: Notification.Name, from center: NotificationCenter, _ handle: @escaping @MainActor (Notification) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                handle(note)
            }
        })
    }

    private static func stopObserving() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }
}
