import Foundation

/// What a session does next: a pure function of its state and an event. The controller keeps
/// the state on screen and runs the effects. Tests/Contract/transitions pins this table.
struct SessionFlow: Codable, Equatable {
    enum Event: String, Codable {
        case escape, togglePause, resume, startShortcut, requestClearAll, requestCancel, confirm, dismissConfirmation
        case holdBegan, holdEnded, otherAppInFront, scopeAppInFront, clickAway
    }

    enum Effect: String, Codable {
        case applyPause, closeComposer, saveComment, closePreview, cancelWindowPick
        case keepKeyboard, giveKeyboardBack, takeKeyboard
        case showEscapeNotice, showOtherAppNotice, clearNotice
        case cancelSession, clearDrafts, restoreDrafts
        case startLocalSession, showHUD
        case plainClicksOn, plainClicksOff
    }

    var isAnnotating = true
    var hasSession = true
    var notes = 0
    var paused = false
    var autoPaused = false
    var holdPaused = false
    var commentOpen = false
    var commentHasText = false
    var previewOpen = false
    var pickingWindow = false
    /// "clearAll", "cancelSession", "discardComment" or "restore".
    var confirmation: String?

    private enum CodingKeys: String, CodingKey {
        case isAnnotating, hasSession, notes, paused, autoPaused, holdPaused, commentOpen, commentHasText, previewOpen, pickingWindow, confirmation
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
        commentOpen = try values.decodeIfPresent(Bool.self, forKey: .commentOpen) ?? false
        commentHasText = try values.decodeIfPresent(Bool.self, forKey: .commentHasText) ?? false
        previewOpen = try values.decodeIfPresent(Bool.self, forKey: .previewOpen) ?? false
        pickingWindow = try values.decodeIfPresent(Bool.self, forKey: .pickingWindow) ?? false
        confirmation = try values.decodeIfPresent(String.self, forKey: .confirmation)
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .escape:
            if commentOpen {
                // Esc on a comment with text asks first, and Esc again keeps writing.
                if confirmation == "discardComment" {
                    confirmation = nil
                    return []
                }
                if commentHasText {
                    confirmation = "discardComment"
                    return []
                }
                return [.closeComposer]
            }
            if previewOpen {
                return [.closePreview]
            }
            if pickingWindow {
                return [.cancelWindowPick]
            }
            if confirmation != nil {
                confirmation = nil
                return []
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
            paused.toggle()
            if !paused {
                // Annotate pressed on purpose resumes, whatever app was last in front.
                autoPaused = false
            }
            return paused ? [.applyPause, .giveKeyboardBack, .takeKeyboard] : [.applyPause, .takeKeyboard]

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
            case "discardComment": return [.closeComposer]
            default: return [.restoreDrafts]
            }

        case .dismissConfirmation:
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

        case .clickAway:
            // What was written is never lost by a click; an empty note is not worth keeping.
            guard commentOpen else {
                return []
            }
            return commentHasText ? [.saveComment] : [.closeComposer]

        case .otherAppInFront:
            guard !autoPaused else {
                return []
            }
            autoPaused = true
            return [.applyPause, .showOtherAppNotice]

        case .scopeAppInFront:
            guard autoPaused else {
                return []
            }
            autoPaused = false
            return [.applyPause]
        }
    }
}
