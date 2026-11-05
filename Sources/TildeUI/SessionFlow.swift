import Foundation

/// What a session does next: a pure function of its state and an event. The controller keeps
/// the state on screen and runs the effects. Tests/Contract/transitions pins this table.
struct SessionFlow: Codable, Equatable {
    enum Event: String, Codable {
        case escape, togglePause, resume, startShortcut, requestClearAll, requestCancel, confirm, dismissConfirmation
        case holdBegan, holdEnded, otherAppInFront, scopeAppInFront, clickAway, startDrawing, finishDrawing, undoDrawing, redoDrawing, shapeFinished
        case leaveRecording
    }

    enum Effect: String, Codable {
        case applyPause, closeComposer, saveComment, showCanvas, keepDrawing, undoShape, redoShape, openShapeComment, closePreview, cancelWindowPick
        case keepKeyboard, giveKeyboardBack, takeKeyboard
        case showEscapeNotice, showOtherAppNotice, clearNotice
        case cancelSession, clearDrafts, restoreDrafts
        case startLocalSession, showHUD
        case plainClicksOn, plainClicksOff
        /// Back to annotating from recording mode, throwing away a clip in progress.
        case exitRecording
    }

    var isAnnotating = true
    var hasSession = true
    var notes = 0
    var paused = false
    var autoPaused = false
    var holdPaused = false
    var drawing = false
    var commentOpen = false
    var commentHasText = false
    var commentIsOnDrawing = false
    var previewOpen = false
    var pickingWindow = false
    /// In recording mode.
    var recording = false
    /// A clip is being recorded or is paused, not yet stopped.
    var clipInProgress = false
    /// "clearAll", "cancelSession", "discardComment", "discardRecording" or "restore".
    var confirmation: String?

    private enum CodingKeys: String, CodingKey {
        case isAnnotating, hasSession, notes, paused, autoPaused, holdPaused, drawing, commentOpen, commentHasText, commentIsOnDrawing, previewOpen, pickingWindow
        case recording, clipInProgress, confirmation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isAnnotating = try values.decodeIfPresent(Bool.self, forKey: .isAnnotating) ?? true
        hasSession = try values.decodeIfPresent(Bool.self, forKey: .hasSession) ?? true
        notes = try values.decodeIfPresent(Int.self, forKey: .notes) ?? 0
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        autoPaused = try values.decodeIfPresent(Bool.self, forKey: .autoPaused) ?? false
        holdPaused = try values.decodeIfPresent(Bool.self, forKey: .holdPaused) ?? false
        drawing = try values.decodeIfPresent(Bool.self, forKey: .drawing) ?? false
        commentOpen = try values.decodeIfPresent(Bool.self, forKey: .commentOpen) ?? false
        commentHasText = try values.decodeIfPresent(Bool.self, forKey: .commentHasText) ?? false
        commentIsOnDrawing = try values.decodeIfPresent(Bool.self, forKey: .commentIsOnDrawing) ?? false
        previewOpen = try values.decodeIfPresent(Bool.self, forKey: .previewOpen) ?? false
        pickingWindow = try values.decodeIfPresent(Bool.self, forKey: .pickingWindow) ?? false
        recording = try values.decodeIfPresent(Bool.self, forKey: .recording) ?? false
        clipInProgress = try values.decodeIfPresent(Bool.self, forKey: .clipInProgress) ?? false
        confirmation = try values.decodeIfPresent(String.self, forKey: .confirmation)
    }

    /// Leaving a comment with text asks first, and pauses, so that the screen can be used
    /// meanwhile; the comment waits. An empty comment just goes.
    private mutating func leaveComment() -> [Effect] {
        guard commentHasText else {
            return [.closeComposer]
        }
        confirmation = "discardComment"
        paused = true
        return [.applyPause]
    }

    private mutating func keepWriting() -> [Effect] {
        confirmation = nil
        paused = false
        return [.applyPause]
    }

    /// While choosing a window, only Esc (which stops choosing), a hold key let go, and other
    /// apps coming to the front count; every control and shortcut waits for the choice.
    private static let whilePicking: Set<Event> = [.escape, .holdEnded, .otherAppInFront, .scopeAppInFront]

    mutating func handle(_ event: Event) -> [Effect] {
        if pickingWindow, !Self.whilePicking.contains(event) {
            return []
        }
        switch event {
        case .escape:
            if commentOpen {
                return confirmation == "discardComment" ? keepWriting() : leaveComment()
            }
            if previewOpen {
                return [.closePreview]
            }
            if drawing {
                return handle(.finishDrawing)
            }
            if pickingWindow {
                return [.cancelWindowPick]
            }
            if confirmation != nil {
                confirmation = nil
                return []
            }
            if recording {
                return handle(.leaveRecording)
            }
            if isAnnotating, !paused {
                paused = true
                return [.applyPause, .showEscapeNotice, .keepKeyboard]
            }
            return handle(.requestCancel)

        case .togglePause:
            guard isAnnotating else {
                return []
            }
            if confirmation == "discardComment" {
                return keepWriting()
            }
            // The canvas would keep the mouse from the screen that a pause gives back.
            let finished: [Effect] = drawing ? handle(.finishDrawing) : []
            paused.toggle()
            if !paused {
                // Annotate pressed on purpose resumes, whatever app was last in front.
                autoPaused = false
            }
            return finished + (paused ? [.applyPause, .giveKeyboardBack, .takeKeyboard] : [.applyPause, .takeKeyboard])

        case .resume:
            if paused {
                return handle(.togglePause)
            }
            guard autoPaused else {
                return []
            }
            autoPaused = false
            return [.applyPause]

        case .startShortcut:
            guard hasSession else {
                return [.startLocalSession]
            }
            return paused ? handle(.togglePause) : [.showHUD]

        case .requestClearAll:
            guard notes > 0 else {
                return []
            }
            confirmation = "clearAll"
            return []

        case .requestCancel:
            guard notes > 0 else {
                return [.clearNotice, .cancelSession]
            }
            confirmation = "cancelSession"
            return [.clearNotice]

        case .confirm:
            guard let asked = confirmation else {
                return []
            }
            confirmation = nil
            switch asked {
            case "clearAll": return [.clearDrafts]
            case "cancelSession": return [.cancelSession]
            case "discardComment":
                paused = false
                return [.closeComposer, .applyPause]
            case "discardRecording": return [.exitRecording]
            default: return [.restoreDrafts]
            }

        case .dismissConfirmation:
            if confirmation == "discardComment" {
                return keepWriting()
            }
            confirmation = nil
            return []

        case .holdBegan:
            // Not while typing a comment, where these keys are for the text.
            guard isAnnotating, !commentOpen, !previewOpen, !paused else {
                return []
            }
            holdPaused = true
            return [.plainClicksOn, .applyPause]

        case .holdEnded:
            guard isAnnotating, holdPaused else {
                return []
            }
            holdPaused = false
            return [.plainClicksOff, .applyPause]

        case .startDrawing:
            guard isAnnotating, !drawing else {
                return []
            }
            // A comment with text asks first, like leaving it any other way.
            if commentOpen, commentHasText {
                return leaveComment()
            }
            var effects: [Effect] = commentOpen ? [.closeComposer] : []
            if previewOpen {
                effects.append(.closePreview)
            }
            drawing = true
            return effects + [.showCanvas]

        case .shapeFinished:
            return drawing && !commentOpen ? [.openShapeComment] : []

        case .undoDrawing:
            return drawing ? [.undoShape] : []

        case .redoDrawing:
            return drawing ? [.redoShape] : []

        case .finishDrawing:
            guard drawing else {
                return []
            }
            drawing = false
            return [.keepDrawing]

        case .clickAway:
            guard commentOpen, confirmation != "discardComment" else {
                return []
            }
            // A shape is worth keeping without words; words are not thrown away unasked.
            if commentIsOnDrawing, !commentHasText {
                return [.saveComment]
            }
            return leaveComment()

        case .otherAppInFront:
            // Recording mode records whatever app is in front.
            guard isAnnotating, !autoPaused else {
                return []
            }
            autoPaused = true
            return [.applyPause, .showOtherAppNotice]

        case .leaveRecording:
            guard recording else {
                return []
            }
            // A clip that is not stopped is lost, so that asks first.
            guard clipInProgress else {
                return [.exitRecording]
            }
            confirmation = "discardRecording"
            return []

        case .scopeAppInFront:
            guard autoPaused else {
                return []
            }
            autoPaused = false
            return [.applyPause]
        }
    }
}
