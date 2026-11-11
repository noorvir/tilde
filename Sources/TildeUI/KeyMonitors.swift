import AppKit

/// The keys that reach the session past its windows: a double tap of a modifier (always), the
/// hold key (while a session is on screen) and the answers to a question (while it shows).
@MainActor
final class KeyMonitors {
    var onDoubleTap: (DoubleTapKey) -> Void = { _ in }
    var onHold: (HoldGesture.Output) -> Void = { _ in }
    /// A key typed in a window of Tilde while a question shows. True when it answered the
    /// question, and no window gets it.
    var onQuestionKey: (_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ window: NSWindow?) -> Bool = { _, _, _ in false }
    /// The hold key that is watched, to take out of the clicks made while it is down.
    private(set) var holdFlag: NSEvent.ModifierFlags = []

    private let shortcuts: ShortcutStore
    private var doubleTap: DoubleTapMonitor?
    private var hold: HoldMonitor?
    private var questionMonitor: Any?

    init(shortcuts: ShortcutStore) {
        self.shortcuts = shortcuts
        doubleTap = DoubleTapMonitor { [shortcuts] in
            shortcuts.doubleTapKeys
        } onDoubleTap: { [weak self] key in
            self?.onDoubleTap(key)
        }
    }

    /// Watches the hold key, if the user has one, until `stopHold()`.
    func startHold() {
        stopHold()
        guard let key = shortcuts.holdKey else {
            return
        }
        holdFlag = key.flag
        hold = HoldMonitor(key: key) { [weak self] output in
            self?.onHold(output)
        }
    }

    func stopHold() {
        hold?.invalidate()
        hold = nil
    }

    /// While a question shows, its answers come from whichever of Tilde's windows has the
    /// keyboard, also from a text field. Keys typed in other apps never reach it.
    func watchQuestion(_ isAsking: Bool) {
        guard isAsking else {
            if let questionMonitor {
                NSEvent.removeMonitor(questionMonitor)
            }
            questionMonitor = nil
            return
        }
        guard questionMonitor == nil else {
            return
        }
        questionMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isAnswer = MainActor.assumeIsolated {
                self?.onQuestionKey(keyCode, modifiers, event.window) == true
            }
            return isAnswer ? nil : event
        }
    }
}
