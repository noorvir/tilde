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
    /// The window button opens the picker at once, as the user last chose from it, instead of
    /// clicking on screen. The flow changes it; the controller keeps it across launches.
    var choosesInPicker = false
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

        /// A clip that a cancel would lose: recording, paused or being saved.
        var holdsClip: Bool {
            switch activity {
            case .recording(.recording), .recording(.paused), .recording(.finishing): true
            default: false
            }
        }

        /// A clip not stopped yet, which leaving recording mode would throw away.
        var clipInProgress: Bool {
            activity == .recording(.recording) || activity == .recording(.paused)
        }

        /// Whether a source can be chosen now: not while a clip keeps its source.
        var canPick: Bool {
            switch activity {
            case .annotating, .recording(.ready), .picking: true
            case .recording: false
            }
        }
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
        case escape, togglePause, resume, startShortcut, requestClearAll, requestCancel, confirm, dismissConfirmation
        /// History's or the menu's Restore, and the menu's Open Browser, while a session is on screen.
        case restore, openBrowser
        /// A note deleted, or its comment changed, from the list, the preview or the browser.
        case deleteNote, editNote
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
        /// Keep the saved session that the restore question asks about.
        case askRestore
        case deleteNote, editNote
        case plainClicksOn, plainClicksOff
        /// Into recording mode, and out of it, throwing away a clip in progress.
        case enterRecording, exitRecording
        case startClip, pauseClip, resumeClip, finishClip
        /// A started clip records on, and a stopped one goes to the list; a result nobody waits
        /// for any more throws its recorder or file away.
        case adoptClip, keepClip, dropClip
        case showStartFailure, showSaveFailure, showSourceGone
        case startPicking, stopPicking, openPicker, closePicker, applySource, openBrowser
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
        session?.holdsClip ?? false
    }

    /// The window button works: annotating, recording mode with no clip in progress, or
    /// choosing. The source of a clip in progress stays until Stop.
    var canPick: Bool {
        guard case .open(let open) = mode else {
            return false
        }
        return open.canPick
    }

    /// Whether the event would do anything now: change the mode or have an effect. A control
    /// that sends it is enabled only then.
    func accepts(_ event: Event) -> Bool {
        var next = self
        let effects = next.handle(event)
        return !effects.isEmpty || next != self
    }

    /// Send and ⌘↩ have something to send, and nothing is starting or finishing.
    var canSend: Bool {
        guard case .open(let open) = mode, !isPicking, open.question == nil else {
            return false
        }
        switch open.activity {
        case .recording(.starting), .recording(.finishing): return false
        default: return notes > 0 || holdsClip || open.panel == .comment
        }
    }

    // MARK: - Rules

    /// Set by a rule that leaves the session on screen, for sending or for its end; `handle`
    /// takes it as the new mode.
    private var leaving: Mode?

    init(mode: Mode = .open(Open()), notes: Int = 0, lastOperation: Int = 0) {
        self.mode = mode
        self.notes = notes
        self.lastOperation = lastOperation
    }

    private mutating func nextOperation() -> Int {
        lastOperation += 1
        return lastOperation
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch mode {
        case .idle:
            return handleWithoutSession(event)
        case .sent(let operation):
            if event == .sentShown(operation) {
                mode = .idle
                return [.hideHUD]
            }
            return handleWithoutSession(event)
        case .sending(let operation, var returnTo):
            let effects = handleSending(event, operation: operation, returnTo: &returnTo)
            if case .sending = mode {
                mode = .sending(operation: operation, returnTo: returnTo)
            }
            return effects
        case .open(var open):
            let effects: [Effect]
            if case .picking(let isRecordMode, let isPickerOpen) = open.activity {
                effects = handlePicking(event, isRecordMode: isRecordMode, isPickerOpen: isPickerOpen, &open)
            } else if let question = open.question, !Self.isAnswer(event, to: question) {
                // A question waits for its answer; nothing else acts under it.
                effects = []
            } else {
                effects = handleOpen(event, &open)
            }
            dropStaleQuestion(&open)
            mode = leaving ?? .open(open)
            leaving = nil
            return effects
        }
    }

    /// A session starts only when none is on screen.
    private mutating func handleWithoutSession(_ event: Event) -> [Effect] {
        switch event {
        case .begin(let inBrowser):
            // A session in the browser starts paused, so the user can type an address and browse.
            mode = .open(Open(pauses: inBrowser ? [.user] : []))
            return []
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

    /// While the report is made, only its own results act, and the hold key and the session's
    /// end still count; notes do not change.
    private mutating func handleSending(_ event: Event, operation: Int, returnTo: inout Open) -> [Effect] {
        switch event {
        case .sendFinished(operation):
            mode = .sent(operation: nextOperation())
            return [.finishSend]
        case .sendFailed(operation):
            mode = .open(returnTo)
            return [.showSendFailure]
        case .holdEnded:
            return endHold(&returnTo)
        case .ended:
            mode = .idle
            return [.endSession]
        case .clipStarted, .clipFinished:
            return [.dropClip]
        default:
            return []
        }
    }

    /// The events a question takes: its answers, Esc, the session's end, and results and
    /// changes from outside that no one asked for, such as the hold key or a clip saved.
    private static func isAnswer(_ event: Event, to question: Question) -> Bool {
        switch event {
        case .confirm, .dismissConfirmation, .escape, .ended, .holdEnded, .otherAppInFront, .scopeAppInFront,
             .clipStarted, .clipStartFailed, .clipFinished, .clipFailed, .captureStopped:
            return true
        default:
            return false
        }
    }

    /// A question about something that is gone, such as a clip saved meanwhile, goes too.
    private func dropStaleQuestion(_ open: inout Open) {
        let isAboutSomething = switch open.question {
        case .discardRecording: open.clipInProgress
        case .discardComment: open.panel == .comment
        case .clearAll: notes > 0
        case .cancelSession: notes > 0 || open.holdsClip
        case .restore, nil: true
        }
        if !isAboutSomething {
            open.question = nil
        }
    }

    /// While choosing, only the window button, Esc (or the picker's Back), the picker, a
    /// choice, the record toggle and Draw act, and the front app and hold key keep the pause
    /// the session goes back to; nothing else does anything.
    private mutating func handlePicking(_ event: Event, isRecordMode: Bool, isPickerOpen: Bool, _ open: inout Open) -> [Effect] {
        let back: Activity = isRecordMode ? .recording(.ready) : .annotating
        switch event {
        case .escape:
            // One level back at a time, as in the preview: the open picker, then choosing.
            if isPickerOpen {
                open.activity = .picking(isRecordMode: isRecordMode, isPickerOpen: false)
                choosesInPicker = false
                return [.closePicker]
            }
            open.activity = back
            return [.stopPicking]
        case .windowButton:
            open.activity = back
            return [.stopPicking]
        case .openPicker:
            open.activity = .picking(isRecordMode: isRecordMode, isPickerOpen: true)
            choosesInPicker = true
            return [.openPicker]
        case .toggleRecordingMode:
            // Choosing goes on, for the other mode: a phone is offered only for recording.
            open.activity = .picking(isRecordMode: !isRecordMode, isPickerOpen: isPickerOpen)
            return isRecordMode ? [.exitRecording] : [.enterRecording]
        case .startDrawing:
            // The canvas takes the clicks: choosing ends with no change, and drawing starts.
            guard !isRecordMode else {
                return []
            }
            open.activity = .annotating
            return [.stopPicking] + handleOpen(.startDrawing, &open)
        case .choose(let drawable):
            // A phone only records; annotating takes only what it can draw on.
            guard drawable || isRecordMode else {
                return []
            }
            open.activity = back
            return [.applySource, .stopPicking]
        case .holdEnded:
            return endHold(&open)
        case .otherAppInFront:
            return isRecordMode ? [] : pauseForOtherApp(&open)
        case .scopeAppInFront:
            return endOtherAppPause(&open)
        case .ended:
            leaving = .idle
            return [.endSession]
        case .clipStarted, .clipFinished:
            return [.dropClip]
        default:
            return []
        }
    }

    private mutating func handleOpen(_ event: Event, _ open: inout Open) -> [Effect] {
        switch event {
        case .begin:
            return []
        case .ended:
            leaving = .idle
            return [.endSession]

        case .escape:
            return escape(&open)

        case .togglePause:
            return togglePause(&open)

        case .resume:
            guard open.activity == .annotating else {
                return []
            }
            return open.pauses.contains(.user) ? togglePause(&open) : endOtherAppPause(&open)

        case .startShortcut:
            return open.activity == .annotating && open.pauses.contains(.user) ? togglePause(&open) : [.showHUD]

        case .requestClearAll:
            guard notes > 0 else {
                return []
            }
            // A question never opens over a comment: one with text asks about it first.
            if open.panel == .comment, commentHasText {
                return leaveComment(&open)
            }
            let closes = open.panel == .comment ? closePanel(&open) : []
            open.question = .clearAll
            return closes

        case .requestCancel:
            return requestCancel(&open)

        case .restore:
            // Into the session on screen, as for choosing a source; notes on screen ask first.
            guard open.canPick else {
                return []
            }
            if open.panel == .comment, commentHasText {
                return leaveComment(&open)
            }
            let closes = finishDrawingAndPanel(&open)
            guard notes > 0 else {
                return closes + [.restoreDrafts]
            }
            open.question = .restore
            return closes + [.askRestore]

        case .openBrowser:
            // The browser limits the session to its window, as choosing it does.
            guard open.canPick else {
                return []
            }
            if open.panel == .comment, commentHasText {
                return leaveComment(&open)
            }
            return finishDrawingAndPanel(&open) + [.openBrowser]

        case .deleteNote:
            guard notes > 0 else {
                return []
            }
            notes -= 1
            return [.deleteNote]

        case .editNote:
            return notes > 0 ? [.editNote] : []

        case .confirm:
            return confirm(&open)

        case .dismissConfirmation:
            return dismiss(&open)

        case .holdBegan:
            // Not while typing a comment, where these keys are for the text.
            guard open.activity == .annotating, open.panel == nil, open.pauses.isEmpty else {
                return []
            }
            open.pauses.insert(.hold)
            return [.plainClicksOn, .applyPause]

        case .holdEnded:
            return endHold(&open)

        case .otherAppInFront:
            // Recording mode records whatever app is in front.
            guard open.activity == .annotating else {
                return []
            }
            return pauseForOtherApp(&open)

        case .scopeAppInFront:
            return endOtherAppPause(&open)

        case .openComment:
            guard open.panel != .comment else {
                return []
            }
            let closes: [Effect] = open.panel == .preview ? [.closePreview] : []
            open.panel = .comment
            return closes + [.showComment]

        case .clickAway:
            guard open.panel == .comment else {
                return []
            }
            // A shape is worth keeping without words; words are not thrown away unasked.
            if commentIsOnDrawing, !commentHasText {
                return submitComment(&open)
            }
            return leaveComment(&open)

        case .submitComment:
            return submitComment(&open)

        case .closeComment:
            guard open.panel == .comment else {
                return []
            }
            open.panel = nil
            return [.closeComposer]

        case .openPreview:
            guard open.panel != .comment else {
                return []
            }
            open.panel = .preview
            return [.showPreview]

        case .closePreview:
            return closePreview(&open)

        case .toggleList:
            return [.toggleList]

        case .startDrawing:
            guard open.activity == .annotating, !open.isDrawing else {
                return []
            }
            // A comment with text asks first, like leaving it any other way.
            if open.panel == .comment, commentHasText {
                return leaveComment(&open)
            }
            let closes = closePanel(&open)
            open.isDrawing = true
            return closes + [.showCanvas]

        case .shapeFinished:
            return open.isDrawing && open.panel != .comment ? [.openShapeComment] : []

        case .undoDrawing:
            return open.isDrawing ? [.undoShape] : []

        case .redoDrawing:
            return open.isDrawing ? [.redoShape] : []

        case .finishDrawing:
            return finishDrawing(&open)

        case .toggleRecordingMode:
            if case .recording = open.activity {
                return leaveRecording(&open)
            }
            return enterRecording(&open)

        case .record:
            return record(&open)

        case .stop:
            guard open.clipInProgress else {
                return []
            }
            open.activity = .recording(.finishing(operation: nextOperation(), thenSend: false))
            return [.finishClip]

        case .clipStarted(let operation):
            guard open.activity == .recording(.starting(operation: operation)) else {
                return [.dropClip]
            }
            open.activity = .recording(.recording)
            return [.adoptClip]

        case .clipStartFailed(let operation):
            guard open.activity == .recording(.starting(operation: operation)) else {
                return []
            }
            open.activity = .recording(.ready)
            return [.showStartFailure]

        case .captureStopped:
            // The source went away: the clip ends at its last frame and goes to the list.
            guard open.clipInProgress else {
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
            return [.keepClip] + (thenSend ? send(&open) : [])

        case .clipFailed(let operation):
            guard case .recording(.finishing(operation, _)) = open.activity else {
                return []
            }
            open.activity = .recording(.ready)
            return [.showSaveFailure]

        case .windowButton:
            guard open.canPick else {
                return []
            }
            if open.panel == .comment, commentHasText {
                return leaveComment(&open)
            }
            let closes = finishDrawingAndPanel(&open)
            open.activity = .picking(isRecordMode: open.activity != .annotating, isPickerOpen: choosesInPicker)
            return closes + [.startPicking] + (choosesInPicker ? [.openPicker] : [])

        case .openPicker, .choose:
            return []

        case .send:
            return send(&open)

        case .sendFinished, .sendFailed, .sentShown, .pushFailed:
            return []
        }
    }

    private mutating func escape(_ open: inout Open) -> [Effect] {
        if open.panel == .comment {
            return open.question == .discardComment ? keepWriting(&open) : leaveComment(&open)
        }
        if open.question != nil {
            return dismiss(&open)
        }
        if open.panel == .preview {
            return closePreview(&open)
        }
        if open.isDrawing {
            return finishDrawing(&open)
        }
        if case .recording = open.activity {
            return leaveRecording(&open)
        }
        if open.pauses.isEmpty {
            open.pauses.insert(.user)
            return [.applyPause, .showEscapeNotice, .keepKeyboard]
        }
        return requestCancel(&open)
    }

    private func requestCancel(_ open: inout Open) -> [Effect] {
        // A question never opens over a comment: one with text asks about it first.
        if open.panel == .comment, commentHasText {
            return leaveComment(&open)
        }
        let closes = open.panel == .comment ? closePanel(&open) : []
        guard notes > 0 || open.holdsClip else {
            return closes + [.clearNotice, .cancelSession]
        }
        open.question = .cancelSession
        return closes + [.clearNotice]
    }

    private func dismiss(_ open: inout Open) -> [Effect] {
        if open.question == .discardComment {
            return keepWriting(&open)
        }
        open.question = nil
        return []
    }

    /// The pause command, the same from the HUD, the menu and the shortcut: annotating pauses
    /// and resumes; recording mode pauses and resumes the clip.
    private func togglePause(_ open: inout Open) -> [Effect] {
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
        // The canvas would keep the mouse from the screen that a pause gives back.
        let finished = finishDrawing(&open)
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
    private mutating func record(_ open: inout Open) -> [Effect] {
        switch open.activity {
        case .recording(.ready):
            open.activity = .recording(.starting(operation: nextOperation()))
            return [.startClip]
        case .recording(.recording), .recording(.paused):
            return togglePause(&open)
        default:
            return []
        }
    }

    private func enterRecording(_ open: inout Open) -> [Effect] {
        guard open.activity == .annotating else {
            return []
        }
        // A comment with text asks first, as Draw does.
        if open.panel == .comment, commentHasText {
            return leaveComment(&open)
        }
        let closes = finishDrawingAndPanel(&open)
        open.activity = .recording(.ready)
        return closes + [.enterRecording]
    }

    /// Back to annotating; a clip that is not stopped is lost, so that asks first. A clip being
    /// saved finishes first.
    private func leaveRecording(_ open: inout Open) -> [Effect] {
        switch open.activity {
        case .recording(.recording), .recording(.paused):
            // A question never opens over a comment: one with text asks about it first.
            if open.panel == .comment, commentHasText {
                return leaveComment(&open)
            }
            let closes = open.panel == .comment ? closePanel(&open) : []
            open.question = .discardRecording
            return closes
        case .recording(.ready), .recording(.starting):
            return exitRecording(&open)
        default:
            return []
        }
    }

    private func exitRecording(_ open: inout Open) -> [Effect] {
        let closes = closePanel(&open)
        open.activity = .annotating
        return closes + [.exitRecording, .applyPause]
    }

    private func confirm(_ open: inout Open) -> [Effect] {
        guard let asked = open.question else {
            return []
        }
        open.question = nil
        switch asked {
        case .clearAll:
            return closePanel(&open) + [.clearDrafts]
        case .cancelSession:
            return [.cancelSession]
        case .discardComment:
            open.pauses.remove(.user)
            open.panel = nil
            return [.closeComposer, .applyPause]
        case .discardRecording:
            return exitRecording(&open)
        case .restore:
            return closePanel(&open) + [.restoreDrafts]
        }
    }

    /// Send, ⌘↩ and a comment's send: a comment goes to the list first, and a clip in progress
    /// is stopped and saved first; then the report is made.
    private mutating func send(_ open: inout Open) -> [Effect] {
        guard case .open = mode, !open.activity.isPicking, open.question == nil else {
            return []
        }
        switch open.activity {
        case .recording(.starting), .recording(.finishing):
            return []
        default:
            break
        }
        var effects: [Effect] = []
        if open.panel == .comment {
            // The comment becomes a note, or edits one.
            effects = submitComment(&open)
            notes = max(notes, 1)
        }
        if open.clipInProgress {
            open.activity = .recording(.finishing(operation: nextOperation(), thenSend: true))
            return effects + [.finishClip]
        }
        guard notes > 0 else {
            return effects
        }
        effects += finishDrawingAndPanel(&open)
        leaving = .sending(operation: nextOperation(), returnTo: open)
        return effects + [.startSend]
    }

    private func submitComment(_ open: inout Open) -> [Effect] {
        guard open.panel == .comment else {
            return []
        }
        open.panel = nil
        open.question = nil
        return [.saveComment]
    }

    /// Leaving a comment with text asks first, and pauses, so that the screen can be used
    /// meanwhile; the comment waits. An empty comment just goes.
    private func leaveComment(_ open: inout Open) -> [Effect] {
        guard commentHasText else {
            open.panel = nil
            return [.closeComposer]
        }
        open.question = .discardComment
        if open.activity == .annotating {
            open.pauses.insert(.user)
        }
        return [.applyPause]
    }

    private func keepWriting(_ open: inout Open) -> [Effect] {
        open.question = nil
        open.pauses.remove(.user)
        return [.applyPause]
    }

    private func closePreview(_ open: inout Open) -> [Effect] {
        guard open.panel == .preview else {
            return []
        }
        open.panel = nil
        return [.closePreview]
    }

    private func finishDrawing(_ open: inout Open) -> [Effect] {
        guard open.isDrawing else {
            return []
        }
        open.isDrawing = false
        return [.keepDrawing]
    }

    /// Closes the preview, or an empty comment; a comment with text is resolved before.
    private func closePanel(_ open: inout Open) -> [Effect] {
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

    private func finishDrawingAndPanel(_ open: inout Open) -> [Effect] {
        closePanel(&open) + finishDrawing(&open)
    }

    private func endHold(_ open: inout Open) -> [Effect] {
        guard open.pauses.contains(.hold) else {
            return []
        }
        open.pauses.remove(.hold)
        return [.plainClicksOff, .applyPause]
    }

    private func pauseForOtherApp(_ open: inout Open) -> [Effect] {
        guard !open.pauses.contains(.otherApp) else {
            return []
        }
        open.pauses.insert(.otherApp)
        return [.applyPause, .showOtherAppNotice]
    }

    private func endOtherAppPause(_ open: inout Open) -> [Effect] {
        guard open.pauses.contains(.otherApp) else {
            return []
        }
        open.pauses.remove(.otherApp)
        return [.applyPause]
    }
}

extension SessionFlow.Activity {
    var isPicking: Bool {
        if case .picking = self {
            return true
        }
        return false
    }
}
