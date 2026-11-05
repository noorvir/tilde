import Foundation

/// What a session does next: a pure function of its mode and an event. The mode is the one
/// source of truth for what the session on screen does; the controller keeps it, runs the
/// effects, and holds the data that goes with it (the comment, the preview's note, the
/// recorder). Every user action and every async result goes through `handle(_:)`.
/// Tests/Contract/transitions pins this table.
struct SessionFlow: Equatable {
    var mode: Mode = .open(Open())
    /// Facts the rules read, which the controller keeps current: the number of notes, and the
    /// comment being written.
    var notes = 0
    var commentHasText = false
    var commentIsOnDrawing = false
    /// The last async operation started (a clip start or stop, a send, a confirmation); its
    /// result counts only while the mode still waits for that operation.
    var lastOperation = 0

    enum Mode: Equatable {
        case idle
        /// A session on screen.
        case open(Open)
        /// Send was pressed: the report is being made; `returnTo` is the session if it fails.
        case sending(operation: Int, returnTo: Open)
        /// The confirmation after Send, until `sentShown` of the same operation.
        case sent(operation: Int)
    }

    /// A session on screen.
    struct Open: Equatable {
        var activity = Activity.annotating
        /// Why annotating is paused; empty while annotating. Kept through recording mode and
        /// choosing a window, so the session comes back to the same pause.
        var pauses: Set<PauseReason> = []
        /// Draw mode, only while annotating.
        var isDrawing = false
        var panel: Panel?
        var question: Question?
    }

    enum Activity: Equatable {
        case annotating
        /// Recording mode.
        case recording(Clip)
        /// Choosing a window or screen, from annotating or from recording mode with no clip in
        /// progress; the session goes back there after the choice. The picker is open in full,
        /// or only its "Use window picker" button shows.
        case picking(isRecordMode: Bool, isPickerOpen: Bool)
    }

    /// The clip of recording mode.
    enum Clip: Equatable {
        case ready
        case starting(operation: Int)
        case recording
        case paused
        /// Stop was pressed; the clip is being saved, then goes to the list (and is sent).
        case finishing(operation: Int, thenSend: Bool)
    }

    enum PauseReason: String, Codable, Hashable, Comparable {
        /// The pause button, the pause shortcut or Esc.
        case user
        /// Another app is in front of a session limited to one window; ends when the window's
        /// app (or Tilde) comes back to the front.
        case otherApp
        /// The hold key is down, so the mouse and keyboard work as usual.
        case hold

        static func < (first: PauseReason, second: PauseReason) -> Bool {
            first.rawValue < second.rawValue
        }
    }

    /// A panel over the session.
    enum Panel: String, Codable {
        case comment
        case preview
    }

    /// A question in the pill, before something is lost.
    enum Question: String, Codable {
        case clearAll
        case cancelSession
        /// Throw away the comment being written; asked on the comment box.
        case discardComment
        /// Leave recording mode and throw away the clip that is not stopped.
        case discardRecording
        /// Replace the notes on screen with a saved session's.
        case restore
    }

    enum Event: Equatable {
        case begin(inBrowser: Bool)
        /// The session ended elsewhere, such as the agent cancelling it.
        case ended
        case escape, togglePause, resume, startShortcut, requestClearAll, requestCancel, askRestore, confirm, dismissConfirmation
        case holdBegan, holdEnded, otherAppInFront, scopeAppInFront
        case openComment, clickAway, submitComment, closeComment, openPreview, closePreview, toggleList
        case startDrawing, finishDrawing, undoDrawing, redoDrawing, shapeFinished
        case toggleRecordingMode, record, stop
        case clipStarted(Int), clipStartFailed(Int), clipFinished(Int), clipFailed(Int)
        /// The recorded window, screen or phone stopped sending frames.
        case captureStopped
        case windowButton, openPicker
        /// A window or screen (drawable) or a phone was chosen.
        case choose(drawable: Bool)
        case send, sendFinished(Int), sendFailed(Int), sentShown(Int), pushFailed
    }

    enum Effect: String, Codable {
        case applyPause, closeComposer, saveComment, showComment, showPreview, closePreview, toggleList
        case showCanvas, keepDrawing, undoShape, redoShape, openShapeComment
        case keepKeyboard, giveKeyboardBack, takeKeyboard
        case showEscapeNotice, showOtherAppNotice, clearNotice
        case endSession, cancelSession, clearDrafts, restoreDrafts, startLocalSession, showHUD
        case plainClicksOn, plainClicksOff
        /// Into recording mode, and out of it, throwing away a clip in progress.
        case enterRecording, exitRecording
        case startClip, pauseClip, resumeClip, finishClip
        /// The clip of a finished stop goes to the list; a result nobody waits for any more
        /// throws its recorder or file away.
        case keepClip, dropClip
        case showStartFailure, showSaveFailure, showSourceGone
        case startPicking, stopPicking, openPicker, closePicker, applySource
        case startSend, finishSend, showSendFailure, showPushFailure, hideHUD
    }

    // MARK: - Reading the mode

    /// The session on screen, also while it is sending.
    var session: Open? {
        switch mode {
        case .open(let open), .sending(_, let open): open
        case .idle, .sent: nil
        }
    }

    /// Whether annotating takes the overlay's clicks: annotating with no pause, or choosing.
    var overlayTakesInput: Bool {
        guard case .open(let open) = mode else {
            return false
        }
        switch open.activity {
        case .annotating: return open.pauses.isEmpty
        case .picking: return true
        case .recording: return false
        }
    }

    var clip: Clip? {
        if case .open(let open) = mode, case .recording(let clip) = open.activity {
            return clip
        }
        return nil
    }

    /// Recording mode, also while choosing the source of its next clip.
    var isRecordMode: Bool {
        switch session?.activity {
        case .recording, .picking(isRecordMode: true, _): true
        default: false
        }
    }

    var isPicking: Bool {
        if case .open(let open) = mode, case .picking = open.activity {
            return true
        }
        return false
    }

    /// A clip that a cancel would lose: recording, paused or being saved.
    var holdsClip: Bool {
        switch clip {
        case .recording, .paused, .finishing: true
        case .ready, .starting, nil: false
        }
    }

    /// The window button works: annotating, recording mode with no clip in progress, or
    /// choosing. The source of a clip in progress stays until Stop.
    var canPick: Bool {
        guard case .open(let open) = mode else {
            return false
        }
        switch open.activity {
        case .annotating, .recording(.ready), .picking: return true
        case .recording: return false
        }
    }

    /// Send and ⌘↩ have something to send, and nothing is starting or finishing.
    var canSend: Bool {
        guard case .open(let open) = mode, !isPicking else {
            return false
        }
        switch open.activity {
        case .recording(.starting), .recording(.finishing): return false
        default: return notes > 0 || holdsClip || open.panel == .comment
        }
    }

    // MARK: - Rules

    /// The session on screen, to read and change in the rules below.
    private var open: Open {
        get { session ?? Open() }
        set { mode = .open(newValue) }
    }

    private mutating func nextOperation() -> Int {
        lastOperation += 1
        return lastOperation
    }

    mutating func handle(_ event: Event) -> [Effect] {
        if case .begin(let inBrowser) = event {
            // A session in the browser starts paused, so the user can type an address and browse.
            mode = .open(Open(pauses: inBrowser ? [.user] : []))
            return []
        }
        switch mode {
        case .idle:
            return handleWithoutSession(event)
        case .sent(let operation):
            if event == .sentShown(operation) {
                mode = .idle
                return [.hideHUD]
            }
            return handleWithoutSession(event)
        case .sending(let operation, let returnTo):
            return handleSending(event, operation: operation, returnTo: returnTo)
        case .open(let current):
            if case .picking(let isRecordMode, let isPickerOpen) = current.activity {
                return handlePicking(event, isRecordMode: isRecordMode, isPickerOpen: isPickerOpen)
            }
            return handleOpen(event)
        }
    }

    private mutating func handleWithoutSession(_ event: Event) -> [Effect] {
        switch event {
        case .startShortcut:
            return [.startLocalSession]
        case .pushFailed:
            mode = .sent(operation: nextOperation())
            return [.showPushFailure]
        case .clipStarted, .clipFinished:
            return [.dropClip]
        default:
            return []
        }
    }

    private mutating func handleSending(_ event: Event, operation: Int, returnTo: Open) -> [Effect] {
        switch event {
        case .sendFinished(operation):
            mode = .sent(operation: nextOperation())
            return [.finishSend]
        case .sendFailed(operation):
            mode = .open(returnTo)
            return [.showSendFailure]
        case .ended:
            mode = .idle
            return [.endSession]
        case .clipStarted, .clipFinished:
            return [.dropClip]
        default:
            return []
        }
    }

    /// While choosing, only the window button, Esc (or the picker's Back), the picker and a
    /// choice act, and the front
    /// app and hold key keep the pause the session goes back to; nothing else does anything.
    private mutating func handlePicking(_ event: Event, isRecordMode: Bool, isPickerOpen: Bool) -> [Effect] {
        let back: Activity = isRecordMode ? .recording(.ready) : .annotating
        switch event {
        case .escape:
            // One level back at a time, as in the preview: the open picker, then choosing.
            if isPickerOpen {
                open.activity = .picking(isRecordMode: isRecordMode, isPickerOpen: false)
                return [.closePicker]
            }
            open.activity = back
            return [.stopPicking]
        case .windowButton:
            open.activity = back
            return [.stopPicking]
        case .openPicker:
            open.activity = .picking(isRecordMode: isRecordMode, isPickerOpen: true)
            return [.openPicker]
        case .choose(let drawable):
            // A phone only records; annotating takes only what it can draw on.
            guard drawable || isRecordMode else {
                return []
            }
            open.activity = back
            return [.applySource, .stopPicking]
        case .holdEnded:
            return endHold()
        case .otherAppInFront:
            return isRecordMode ? [] : pauseForOtherApp()
        case .scopeAppInFront:
            return endOtherAppPause()
        case .ended:
            mode = .idle
            return [.endSession]
        case .clipStarted, .clipFinished:
            return [.dropClip]
        default:
            return []
        }
    }

    private mutating func handleOpen(_ event: Event) -> [Effect] {
        switch event {
        case .begin:
            return []
        case .ended:
            mode = .idle
            return [.endSession]

        case .escape:
            return escape()

        case .togglePause:
            return togglePause()

        case .resume:
            guard open.activity == .annotating else {
                return []
            }
            return open.pauses.contains(.user) ? togglePause() : endOtherAppPause()

        case .startShortcut:
            return open.activity == .annotating && open.pauses.contains(.user) ? togglePause() : [.showHUD]

        case .requestClearAll:
            guard notes > 0 else {
                return []
            }
            open.question = .clearAll
            return []

        case .requestCancel:
            guard notes > 0 || holdsClip else {
                return [.clearNotice, .cancelSession]
            }
            open.question = .cancelSession
            return [.clearNotice]

        case .askRestore:
            open.question = .restore
            return []

        case .confirm:
            return confirm()

        case .dismissConfirmation:
            if open.question == .discardComment {
                return keepWriting()
            }
            open.question = nil
            return []

        case .holdBegan:
            // Not while typing a comment, where these keys are for the text.
            guard open.activity == .annotating, open.panel == nil, open.pauses.isEmpty else {
                return []
            }
            open.pauses.insert(.hold)
            return [.plainClicksOn, .applyPause]

        case .holdEnded:
            return endHold()

        case .otherAppInFront:
            // Recording mode records whatever app is in front.
            guard open.activity == .annotating else {
                return []
            }
            return pauseForOtherApp()

        case .scopeAppInFront:
            return endOtherAppPause()

        case .openComment:
            guard open.panel != .comment else {
                return []
            }
            let closes: [Effect] = open.panel == .preview ? [.closePreview] : []
            open.panel = .comment
            return closes + [.showComment]

        case .clickAway:
            guard open.panel == .comment, open.question != .discardComment else {
                return []
            }
            // A shape is worth keeping without words; words are not thrown away unasked.
            if commentIsOnDrawing, !commentHasText {
                return handle(.submitComment)
            }
            return leaveComment()

        case .submitComment:
            guard open.panel == .comment else {
                return []
            }
            open.panel = nil
            open.question = nil
            return [.saveComment]

        case .closeComment:
            guard open.panel == .comment else {
                return []
            }
            open.panel = nil
            // A comment that asked first had paused annotating.
            guard open.question == .discardComment else {
                return [.closeComposer]
            }
            open.question = nil
            open.pauses.remove(.user)
            return [.closeComposer, .applyPause]

        case .openPreview:
            guard open.panel != .comment else {
                return []
            }
            open.panel = .preview
            return [.showPreview]

        case .closePreview:
            guard open.panel == .preview else {
                return []
            }
            open.panel = nil
            return [.closePreview]

        case .toggleList:
            return [.toggleList]

        case .startDrawing:
            guard open.activity == .annotating, !open.isDrawing else {
                return []
            }
            // A comment with text asks first, like leaving it any other way.
            if open.panel == .comment, commentHasText {
                return leaveComment()
            }
            let closes = closePanel()
            open.isDrawing = true
            return closes + [.showCanvas]

        case .shapeFinished:
            return open.isDrawing && open.panel != .comment ? [.openShapeComment] : []

        case .undoDrawing:
            return open.isDrawing ? [.undoShape] : []

        case .redoDrawing:
            return open.isDrawing ? [.redoShape] : []

        case .finishDrawing:
            guard open.isDrawing else {
                return []
            }
            open.isDrawing = false
            return [.keepDrawing]

        case .toggleRecordingMode:
            if case .recording = open.activity {
                return leaveRecording()
            }
            return enterRecording()

        case .record:
            return record()

        case .stop:
            guard case .recording(let clip) = open.activity, clip == .recording || clip == .paused else {
                return []
            }
            open.activity = .recording(.finishing(operation: nextOperation(), thenSend: false))
            return [.finishClip]

        case .clipStarted(let operation):
            guard open.activity == .recording(.starting(operation: operation)) else {
                return [.dropClip]
            }
            open.activity = .recording(.recording)
            return []

        case .clipStartFailed(let operation):
            guard open.activity == .recording(.starting(operation: operation)) else {
                return []
            }
            open.activity = .recording(.ready)
            return [.showStartFailure]

        case .captureStopped:
            // The source went away: the clip ends at its last frame and goes to the list.
            guard case .recording(let clip) = open.activity, clip == .recording || clip == .paused else {
                return []
            }
            open.activity = .recording(.finishing(operation: nextOperation(), thenSend: false))
            return [.finishClip, .showSourceGone]

        case .clipFinished(let operation):
            guard case .recording(.finishing(operation, let thenSend)) = open.activity else {
                return [.dropClip]
            }
            open.activity = .recording(.ready)
            notes += 1
            return [.keepClip] + (thenSend ? handle(.send) : [])

        case .clipFailed(let operation):
            guard case .recording(.finishing(operation, _)) = open.activity else {
                return []
            }
            open.activity = .recording(.ready)
            return [.showSaveFailure]

        case .windowButton:
            guard canPick else {
                return []
            }
            if open.panel == .comment, commentHasText {
                return leaveComment()
            }
            let closes = finishDrawingAndPanel()
            open.question = nil
            open.activity = .picking(isRecordMode: open.activity != .annotating, isPickerOpen: false)
            return closes + [.startPicking]

        case .openPicker, .choose:
            return []

        case .send:
            return send()

        case .sendFinished, .sendFailed, .sentShown, .pushFailed:
            return []
        }
    }

    private mutating func escape() -> [Effect] {
        if open.panel == .comment {
            return open.question == .discardComment ? keepWriting() : leaveComment()
        }
        if open.panel == .preview {
            return handle(.closePreview)
        }
        if open.isDrawing {
            return handle(.finishDrawing)
        }
        if open.question != nil {
            return handle(.dismissConfirmation)
        }
        if case .recording = open.activity {
            return leaveRecording()
        }
        if open.pauses.isEmpty {
            open.pauses.insert(.user)
            return [.applyPause, .showEscapeNotice, .keepKeyboard]
        }
        return handle(.requestCancel)
    }

    /// The pause command, the same from the HUD, the menu and the shortcut: annotating pauses
    /// and resumes; recording mode pauses and resumes the clip.
    private mutating func togglePause() -> [Effect] {
        switch open.activity {
        case .recording(.recording):
            open.activity = .recording(.paused)
            return [.pauseClip]
        case .recording(.paused):
            open.activity = .recording(.recording)
            return [.resumeClip]
        case .recording, .picking:
            return []
        case .annotating:
            break
        }
        if open.question == .discardComment {
            return keepWriting()
        }
        // The canvas would keep the mouse from the screen that a pause gives back.
        let finished = handle(.finishDrawing)
        if open.pauses.contains(.user) {
            // Annotate pressed on purpose resumes, whatever app was last in front.
            open.pauses.remove(.user)
            open.pauses.remove(.otherApp)
            return finished + [.applyPause, .takeKeyboard]
        }
        open.pauses.insert(.user)
        return finished + [.applyPause, .giveKeyboardBack, .takeKeyboard]
    }

    /// The leading button in recording mode: starts a clip, pauses it, resumes it.
    private mutating func record() -> [Effect] {
        switch open.activity {
        case .recording(.ready):
            open.activity = .recording(.starting(operation: nextOperation()))
            return [.startClip]
        case .recording(.recording), .recording(.paused):
            return togglePause()
        default:
            return []
        }
    }

    private mutating func enterRecording() -> [Effect] {
        guard open.activity == .annotating else {
            return []
        }
        // A comment with text asks first, as Draw does.
        if open.panel == .comment, commentHasText {
            return leaveComment()
        }
        let closes = finishDrawingAndPanel()
        open.question = nil
        open.activity = .recording(.ready)
        return closes + [.enterRecording]
    }

    /// Back to annotating; a clip that is not stopped is lost, so that asks first. A clip being
    /// saved finishes first.
    private mutating func leaveRecording() -> [Effect] {
        guard case .recording(let clip) = open.activity else {
            return []
        }
        switch clip {
        case .recording, .paused:
            open.question = .discardRecording
            return []
        case .finishing:
            return []
        case .ready, .starting:
            return exitRecording()
        }
    }

    private mutating func exitRecording() -> [Effect] {
        let closes = closePanel()
        open.question = nil
        open.activity = .annotating
        return closes + [.exitRecording, .applyPause]
    }

    private mutating func confirm() -> [Effect] {
        guard let asked = open.question else {
            return []
        }
        open.question = nil
        switch asked {
        case .clearAll:
            return closePanel() + [.clearDrafts]
        case .cancelSession:
            return [.cancelSession]
        case .discardComment:
            open.pauses.remove(.user)
            open.panel = nil
            return [.closeComposer, .applyPause]
        case .discardRecording:
            return exitRecording()
        case .restore:
            return [.restoreDrafts]
        }
    }

    /// Send, ⌘↩ and a comment's send: a comment goes to the list first, and a clip in progress
    /// is stopped and saved first; then the report is made.
    private mutating func send() -> [Effect] {
        guard canSend else {
            return []
        }
        if open.panel == .comment {
            // The comment becomes a note, or edits one.
            let saved = handle(.submitComment)
            notes = max(notes, 1)
            return saved + handle(.send)
        }
        if case .recording(let clip) = open.activity, clip == .recording || clip == .paused {
            open.activity = .recording(.finishing(operation: nextOperation(), thenSend: true))
            return [.finishClip]
        }
        guard notes > 0 else {
            return []
        }
        let closes = finishDrawingAndPanel()
        var returnTo = open
        returnTo.question = nil
        mode = .sending(operation: nextOperation(), returnTo: returnTo)
        return closes + [.startSend]
    }

    /// Leaving a comment with text asks first, and pauses, so that the screen can be used
    /// meanwhile; the comment waits. An empty comment just goes.
    private mutating func leaveComment() -> [Effect] {
        guard commentHasText else {
            return handle(.closeComment)
        }
        open.question = .discardComment
        if open.activity == .annotating {
            open.pauses.insert(.user)
        }
        return [.applyPause]
    }

    private mutating func keepWriting() -> [Effect] {
        open.question = nil
        open.pauses.remove(.user)
        return [.applyPause]
    }

    /// Closes the preview, or an empty comment; a comment with text is resolved before.
    private mutating func closePanel() -> [Effect] {
        switch open.panel {
        case .preview:
            open.panel = nil
            return [.closePreview]
        case .comment:
            open.panel = nil
            return [.closeComposer]
        case nil:
            return []
        }
    }

    private mutating func finishDrawingAndPanel() -> [Effect] {
        let closes = closePanel()
        guard open.isDrawing else {
            return closes
        }
        open.isDrawing = false
        return closes + [.keepDrawing]
    }

    private mutating func endHold() -> [Effect] {
        guard open.pauses.contains(.hold) else {
            return []
        }
        open.pauses.remove(.hold)
        return [.plainClicksOff, .applyPause]
    }

    private mutating func pauseForOtherApp() -> [Effect] {
        guard !open.pauses.contains(.otherApp) else {
            return []
        }
        open.pauses.insert(.otherApp)
        return [.applyPause, .showOtherAppNotice]
    }

    private mutating func endOtherAppPause() -> [Effect] {
        guard open.pauses.contains(.otherApp) else {
            return []
        }
        open.pauses.remove(.otherApp)
        return [.applyPause]
    }
}
