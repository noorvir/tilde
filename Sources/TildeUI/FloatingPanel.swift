import AppKit
import Carbon.HIToolbox

/// Borderless panel that can take keyboard focus without activating other windows.
///
/// While one of its text views has the keyboard, Tilde is the app in front, as with any text
/// field on the Mac: dictation and paste tools look for the focused element in the app in
/// front. The app that was in front before gets it back when the text view lets go.
///
/// It is the end of its keys' way. A key that nothing in it used, such as Return on the
/// overlay or on the canvas's page, comes here as the key, and from a text field or a web view
/// also as the key's command, such as `insertNewline:`. Neither does anything here, and neither
/// plays the alert sound that a window plays for them.
class FloatingPanel: NSPanel {
    private var returnApp: NSRunningApplication?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {}

    override func doCommand(by selector: Selector) {
        _ = tryToPerform(selector, with: nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, insertNewlineOnShiftReturn(event, in: self) {
            return
        }
        super.sendEvent(event)
    }

    @discardableResult
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        updateActivation()
        return made
    }

    override func becomeKey() {
        super.becomeKey()
        updateActivation()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        updateActivation()
    }

    /// `NSApp.isActive` is already true while a non-activating panel has the keyboard, so the
    /// app in front is what tells whether Tilde is in front.
    private func updateActivation() {
        let isEditing = isVisible && firstResponder is NSTextView
        let own = NSRunningApplication.current.processIdentifier
        if isEditing {
            guard isKeyWindow, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own else {
                return
            }
            returnApp = front
            NSApp.activate()
            return
        }

        guard let returnApp else {
            return
        }
        self.returnApp = nil
        // As before the text view had it, a panel of Tilde keeps the keyboard while that app is
        // in front: the one the caller makes key in this turn, such as the overlay after the
        // comment box. The app's activation takes the keyboard when it lands, a moment later, so
        // that panel takes it back then.
        Task { @MainActor in
            // The user or Tilde went to another app meanwhile: that app keeps the keyboard.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == own else {
                return
            }
            let keyWindow = NSApp.keyWindow
            NSApp.yieldActivation(to: returnApp)
            returnApp.activate()
            guard let keyWindow else {
                return
            }
            for _ in 0..<40 where keyWindow.isKeyWindow {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if !keyWindow.isKeyWindow, keyWindow.isVisible {
                keyWindow.makeKey()
            }
        }
    }
}

/// Shift-Return and Option-Return add a line in a text field of a panel, as in chat apps; a
/// SwiftUI field would take Shift-Return as Return and submit. Returns whether it did.
func insertNewlineOnShiftReturn(_ event: NSEvent, in window: NSWindow) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)), modifiers == .shift || modifiers == .option, let editor = window.firstResponder as? NSTextView else {
        return false
    }
    editor.insertNewlineIgnoringFieldEditor(nil)
    return true
}
