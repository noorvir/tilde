import AppKit
import Carbon.HIToolbox

/// The window of the session that has the keyboard, with what only that window knows.
enum KeySurface {
    /// An overlay. `hoveredNote`: the note whose label is under the pointer.
    case overlay(hoveredNote: Draft.ID?)
    /// Tilde's browser. `isTyping`: a text field, such as the address or a note, has the
    /// keyboard. `isInPage`: the page has it.
    case browser(isTyping: Bool, isInPage: Bool)
    /// The preview card. `isTyping`: its comment is being edited.
    case preview(isTyping: Bool)
    /// The drawing canvas, outside its text fields.
    case canvas
}

/// What a letter or a digit does for wireframe mode.
enum WireframeKey: Equatable {
    /// W starts the mode, also from Draw.
    case start
    /// W resumes the mode when it is paused.
    case resume
    case tool(String)
    /// Another letter or digit in the mode does nothing: Draw's tools and colours, and the
    /// modes' keys, would change the canvas behind the HUD.
    case ignored

    /// The event of the key; a tool changes no mode.
    var event: SessionFlow.Event? {
        switch self {
        case .start: .startWireframe
        case .resume: .resume
        case .tool, .ignored: nil
        }
    }
}

/// What a key does in the session's windows. Each window gives its key to `handleKey` first
/// and keeps only keys of its own: back and forward in the browser, the end of editing in the
/// preview. The canvas has keys of its own too: in a text field, and in wireframe mode ⌘Z, ⇧⌘Z,
/// Delete and the first Esc on a selected component. The comment box has no key codes: its text view sends ↩ as the event `submitComment`, Esc
/// as `escapePressed` and ⌘↩ as Send. A question takes Esc and ↩ before any window, through
/// `handleConfirmationKey`.
extension AnnotationController {
    /// Returns whether the session took the key.
    func handleKey(_ event: NSEvent, in surface: KeySurface) -> Bool {
        let key = Int(event.keyCode)
        switch surface {
        case .overlay(let hoveredNote):
            if key == kVK_Escape {
                escapePressed()
                return true
            }
            // A question takes every key; ↩ alone confirms.
            if confirmation != nil {
                if key == kVK_Return, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    dispatch(.confirm)
                }
                return true
            }
            let isCommand = event.modifierFlags.contains(.command)
            // Back and forward belong to the page under the overlay.
            if isCommand, key == kVK_ANSI_LeftBracket || key == kVK_ANSI_RightBracket {
                navigateHistory(event)
                return true
            }
            // The same action and rule as the Send button, paused too; the flow ignores it while
            // choosing a window or with nothing to send.
            if isCommand, key == kVK_Return {
                // In Draw and Wireframe it is their Done.
                dispatch(isDrawing ? .finishDrawing : .send)
                return true
            }
            // Space on a note's marker previews it, before Space pauses.
            if !pauses.contains(.user), key == kVK_Space, let hoveredNote {
                preview(hoveredNote)
                return true
            }
            return performShortcut(event)

        case .browser(let isTyping, let isInPage):
            guard session != nil else {
                return false
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Esc and ↩ for the session, unless a text field has the keyboard.
            if modifiers.isEmpty, key == kVK_Escape || key == kVK_Return {
                if isTyping {
                    return false
                }
                if key == kVK_Escape {
                    escapePressed()
                    return true
                }
                if confirmation != nil {
                    dispatch(.confirm)
                    return true
                }
                return false
            }
            if modifiers == .command {
                // ⌘↩ follows the Send button, also from the address field or a note.
                if key == kVK_Return {
                    dispatch(.send)
                    return true
                }
                return false
            }
            // The HUD's keys, but never while the page or a text field has the keyboard.
            if isTyping || isInPage {
                return false
            }
            return performShortcut(event)

        case .preview(let isTyping):
            // ⌘↩ follows the Send button, also while the comment is edited.
            if key == kVK_Return, event.modifierFlags.contains(.command) {
                dispatch(.send)
                return true
            }
            // Esc goes back from an enlarged image, then closes.
            if key == kVK_Escape {
                if previewCard.expandedImage != nil {
                    previewCard.expandedImage = nil
                } else {
                    dispatch(.closePreview)
                }
                return true
            }
            if !isTyping, key == kVK_LeftArrow {
                previewCard.step(-1, in: drafts)
                return true
            }
            if !isTyping, key == kVK_RightArrow {
                previewCard.step(1, in: drafts)
                return true
            }
            return false

        case .canvas:
            // Esc closes the wireframe bar's Adjust popover, then its style mode, before it
            // steps back on the canvas. An open menu takes Esc itself.
            if key == kVK_Escape, wireframe.bar.handle(.escape) {
                return true
            }
            // ⌘↩ is Done in Draw and Wireframe.
            if isDrawing, key == kVK_Return, event.modifierFlags.contains(.command) {
                dispatch(.finishDrawing)
                return true
            }
            return performShortcut(event)
        }
    }

    /// A key for one of the HUD's buttons while Tilde has the keyboard, under the rule that
    /// enables that button. True when the key is one of them, whether it did anything or not.
    func performShortcut(_ event: NSEvent) -> Bool {
        if let key = wireframeKey(of: event) {
            if case .tool(let tool) = key {
                setWireframeTool(tool)
            }
            if let next = key.event, !event.isARepeat {
                dispatch(next)
            }
            return true
        }
        guard session != nil, confirmation == nil,
              let action = shortcuts.inAppAction(keyCode: event.keyCode, modifiers: event.modifierFlags, isDrawing: isDrawing)
        else {
            return false
        }
        if event.isARepeat {
            return true
        }
        if let tool = action.drawingTool {
            setDrawingTool(tool)
        } else if let color = action.drawingColor {
            setDrawingColor(color.hex)
        }
        for next in flow.events(forKey: action) {
            dispatch(next)
        }
        return true
    }

    /// What a key does for wireframe mode, before the keys of the HUD's buttons; nil when the
    /// key is not one of its keys.
    private func wireframeKey(of event: NSEvent) -> WireframeKey? {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let key = event.charactersIgnoringModifiers else {
            return nil
        }
        return Self.wireframeKey(key.lowercased(), flow: flow, wireframesOn: wireframes.isOn)
    }

    /// The rule of wireframe mode's keys, for a key without ⌘, ⌃ or ⌥, in lower case. W starts
    /// the mode outside recording mode while the beta is on, and resumes it when it is paused. In the mode, a
    /// tool's letter chooses the tool, and every other letter and digit does nothing. Under a
    /// question no key is one of them.
    nonisolated static func wireframeKey(_ key: String, flow: SessionFlow, wireframesOn: Bool) -> WireframeKey? {
        guard let open = flow.session, open.question == nil, key.count == 1, key != " " else {
            return nil
        }
        guard open.canvas == .wireframe else {
            return key == "w" && wireframesOn && !flow.isRecordMode ? .start : nil
        }
        if !open.pauses.isEmpty {
            return key == "w" ? .resume : nil
        }
        if let tool = WireframeMode.tools.first(where: { $0.key == key }) {
            return .tool(tool.tool)
        }
        return key.allSatisfy { $0.isLetter || $0.isNumber } ? .ignored : nil
    }

    /// Esc while the session holds the keyboard, from its system-wide hot key: the app in front
    /// never gets it. It goes on to the window of Tilde that has the keyboard as a key typed
    /// there, so a text field, the canvas or a question takes it first, as before. With none,
    /// the session takes it.
    func globalEscapePressed() {
        guard let window = NSApp.keyWindow else {
            escapePressed()
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)
            )
            if let event {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Returns whether the key answered the question on screen: Esc, or ↩ alone, typed in one of
    /// the session's windows (its panels or Tilde's browser), never in Settings. ⌘↩ is Send and
    /// never answers.
    func handleConfirmationKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow?) -> Bool {
        let isSessionWindow = window is NSPanel || (window != nil && window === browser.window)
        guard confirmation != nil, modifiers.isEmpty, isSessionWindow else {
            return false
        }
        switch Int(keyCode) {
        case kVK_Escape:
            dispatch(.dismissConfirmation)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            dispatch(.confirm)
            return true
        default:
            return false
        }
    }

    /// ⌘[ or ⌘] while the overlay has the keyboard: in Tilde's browser, or else in the app in
    /// front, as if the overlay were not there.
    private func navigateHistory(_ event: NSEvent) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let front, front != getpid() {
            event.cgEvent?.postToPid(front)
        } else if Int(event.keyCode) == kVK_ANSI_LeftBracket {
            browser.goBack(nil)
        } else {
            browser.goForward(nil)
        }
    }

    // MARK: - Double tap and hold

    enum DoubleTapAction: Equatable {
        case start
        case resume
        case togglePause
    }

    /// What a double tap of `key` does. The start key brings annotating up: it starts a
    /// session, or resumes a paused one, and does nothing while annotating. The pause key is
    /// the pause command of the mode, as in the HUD and the menu. One key may do both.
    nonisolated static func doubleTapAction(
        for key: DoubleTapKey, startKey: DoubleTapKey?, pauseKey: DoubleTapKey?, isPaused: Bool, hasSession: Bool
    ) -> DoubleTapAction? {
        if key == startKey {
            if !hasSession {
                return .start
            }
            if isPaused {
                return .resume
            }
        }
        if key == pauseKey, hasSession {
            return .togglePause
        }
        return nil
    }

    func doubleTapped(_ key: DoubleTapKey) {
        guard !shortcuts.isRecording else {
            return
        }
        let action = Self.doubleTapAction(
            for: key, startKey: shortcuts.shortcut(for: .startAnnotation)?.doubleTapKey, pauseKey: shortcuts.shortcut(for: .togglePause)?.doubleTapKey,
            isPaused: pauses.contains(.user), hasSession: session != nil
        )
        switch action {
        case .togglePause, .resume:
            dispatch(.togglePause)
        case .start:
            startLocal()
        case nil:
            break
        }
    }

    /// The hold key went down or up: while it is down, the mouse works as usual.
    func holdChanged(_ output: HoldGesture.Output) {
        switch output {
        case .began:
            dispatch(.holdBegan)
            // With the browser in front, its page takes the first click only when it is key.
            if pauses.contains(.hold), NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), browser.window?.isVisible == true {
                browser.window?.makeKey()
            }
        case .ended:
            dispatch(.holdEnded)
        }
    }
}
