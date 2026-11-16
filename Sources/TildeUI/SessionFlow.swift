import Foundation

/// What a session does next: a pure function of its mode, an event and the facts of the
/// session's data. The mode is the one source of truth for what the session on screen does;
/// the controller keeps it, runs the effects, and holds the data that goes with it (the notes,
/// the comment, the preview's note, the recorder). Every user action and every async result
/// goes through `handle(_:_:)`.
/// Tests/Contract/transitions pins this table.
struct SessionFlow: Equatable {
    var mode: Mode = .open(Open())
    /// A click on the source button opens the picker at once, as the user last chose from it,
    /// instead of clicking on screen. The flow changes it; the controller keeps it across
    /// launches.
    var choosesInPicker = false
    /// The last async operation started (a clip start or stop, a send, a confirmation); its
    /// result counts only while the mode still waits for that operation.
    var lastOperation = 0

    /// What the rules read of the data that the controller owns. It gives them with each event.
    struct Facts: Equatable {
        /// The number of notes.
        var notes = 0
        /// The comment being written has text, and is on a drawing.
        var commentHasText = false
        var commentIsOnDrawing = false
        /// The wireframes beta is on: see `WireframeSwitch`.
        var wireframesOn = true
    }

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
        /// The drawing canvas, only while annotating: Draw mode or Wireframe mode.
        var canvas: Canvas?
        var panel: Panel?
        var question: Question?

        /// Draw mode or Wireframe mode: the canvas is open.
        var isDrawing: Bool {
            canvas != nil
        }

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

        /// Whether the session's source can change now: not while a clip keeps its source.
        var canPick: Bool {
            switch activity {
            case .annotating, .recording(.ready), .picking: true
            case .recording: false
            }
        }
    }

    enum Activity: Equatable {
        case annotating
        case recording(Clip)
        /// Choosing what to record, in recording mode with no clip in progress; the session
        /// goes back there after the choice. The picker is open, or a click on screen chooses
        /// and the source dropdown under the source button offers the picker.
        case picking(isPickerOpen: Bool)
    }

    /// What the drawing canvas is open for.
    enum Canvas: String, Codable {
        /// Draw mode: each shape gets a comment and becomes a note.
        case draw
        /// Wireframe mode: components, which Done sends together as one note.
        case wireframe
    }

    /// The mode a new session starts in: the one that was on last. Recording mode needs a
    /// source, so it counts as no mode.
    enum StartMode: String {
        case annotating, draw, wireframe
        case noMode = "none"

        /// The mode to start in: the saved one, and annotation mode until one is saved. A
        /// session in Tilde's browser starts with no mode, so the user can type an address
        /// and browse first.
        init(saved: String?, inBrowser: Bool) {
            let last = saved.flatMap(StartMode.init(rawValue:)) ?? .annotating
            self = inBrowser ? .noMode : last
        }

        /// The event that turns the mode on in a session that began, which has no mode.
        var event: Event? {
            switch self {
            case .annotating: .toggleAnnotating
            case .draw: .startDrawing
            case .wireframe: .startWireframe
            case .noMode: nil
            }
        }
    }

    /// The clip of recording mode.
    enum Clip: Equatable {
        case ready
        case starting(operation: Int)
        case recording
        case paused
        /// Stop was pressed; the clip is being saved, then goes to the list, and the session
        /// does `then`.
        case finishing(operation: Int, then: AfterClip)
    }

    /// What the session does once a stopped clip is saved.
    enum AfterClip: Equatable {
        /// Stays in recording mode, ready for the next clip.
        case stay
        case send
        /// Leaves recording mode for the mode whose button was pressed while the clip recorded.
        case switchTo(OtherMode)
    }

    /// A mode that recording mode leaves for from the HUD's buttons and their keys.
    enum OtherMode: String {
        case annotating, draw, wireframe
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
        case begin
        /// The session ended elsewhere, such as the agent cancelling it.
        case ended
        case escape, togglePause, resume, startShortcut, requestClearAll, requestCancel, confirm, dismissConfirmation
        /// The Annotate button and its key: annotation mode on, from any other mode, or off.
        case toggleAnnotating
        /// History's or the menu's Restore, and the menu's Open Browser, while a session is on screen.
        case restore, openBrowser
        /// A note deleted, or its comment changed, from the list, the preview or the browser.
        case deleteNote, editNote
        case holdBegan, holdEnded, otherAppInFront, scopeAppInFront
        case openComment, clickAway, submitComment, openPreview, closePreview, toggleList
        /// `finishDrawing` is Done, in Draw mode and in Wireframe mode.
        case startDrawing, finishDrawing, undoDrawing, redoDrawing, shapeFinished
        /// Wireframe mode on, also from Draw mode; and Done has taken its components for their note.
        case startWireframe, wireframeTaken
        case toggleRecordingMode, record, stop
        case clipStarted(Int), clipStartFailed(Int), clipFinished(Int), clipFailed(Int)
        /// The recorded window, screen or phone stopped sending frames.
        case captureStopped
        /// The window that the session is limited to closed.
        case windowClosed
        /// A click on the recording bar's source button, and the menu's Record a Specific Window:
        /// choosing what to record starts, or ends with no change. Then "Use window picker" in
        /// the source dropdown.
        case pickSource, openPicker
        /// A window, a screen or a phone was chosen to record.
        case choose
        case send, sendFinished(Int), sendFailed(Int), sentShown(Int), pushFailed
    }

    enum Effect: String, Codable {
        case applyPause, closeComposer, saveComment, showComment, showPreview, closePreview, toggleList
        case showCanvas, keepDrawing, undoShape, redoShape, openShapeComment
        /// Wireframe mode on the canvas, and off it; Done's note of its components. No tool
        /// draws, in Draw mode and in Wireframe mode.
        case showWireframe, endWireframe, takeWireframe, putToolDown
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

    /// Annotation mode: annotating, with no pause and no canvas; also while its report is made.
    var isAnnotating: Bool {
        guard let open = session else {
            return false
        }
        return open.activity == .annotating && open.pauses.isEmpty && !open.isDrawing
    }

    var isWireframe: Bool {
        session?.canvas == .wireframe
    }

    /// The mode on screen, which the next session starts in; nil while there is none to keep:
    /// no session, a report being made, choosing a source, or a pause by the hold key or
    /// another app.
    var startMode: StartMode? {
        guard case .open(let open) = mode else {
            return nil
        }
        switch open.canvas {
        case .wireframe: return .wireframe
        case .draw: return .draw
        case nil: break
        }
        switch open.activity {
        case .recording:
            return .noMode
        case .picking:
            return nil
        case .annotating:
            if open.pauses.isEmpty {
                return .annotating
            }
            return open.pauses.contains(.user) ? .noMode : nil
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
        case .recording, .picking: true
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

    /// Whether the session's source can change now: Tilde's browser can limit the session, a
    /// restore can open its page and recording mode can choose. The source of a clip in
    /// progress stays until Stop.
    var canPick: Bool {
        guard case .open(let open) = mode else {
            return false
        }
        return open.canPick
    }

    /// Whether the event would do anything now: change the mode or have an effect. A control
    /// that sends it is enabled only then.
    func accepts(_ event: Event, _ facts: Facts) -> Bool {
        var next = self
        let effects = next.handle(event, facts)
        return !effects.isEmpty || next != self
    }

    /// The events that a single key's action sends, under the rules that enable its button:
    /// none under a question, while a clip starts or is saved, or while sending; while drawing,
    /// none for a mode's key, so that it never leaves drawing. A drawing tool or colour changes
    /// no mode.
    func events(forKey action: ShortcutStore.Action) -> [Event] {
        guard case .open(let open) = mode, open.question == nil else {
            return []
        }
        // Draw paused resumes by its own key or Space; no other mode's key leaves it.
        if open.isDrawing, action.group == .modes {
            let resumes = !open.pauses.isEmpty && (action == .drawingMode || action == .pauseOrResume)
            return resumes ? [.resume] : []
        }
        let isBusy = switch open.activity {
        case .recording(.starting), .recording(.finishing): true
        default: false
        }
        switch action {
        case .annotationMode:
            return isBusy ? [] : [.toggleAnnotating]
        case .recordingMode:
            return isBusy ? [] : [.toggleRecordingMode]
        case .drawingMode:
            return isBusy ? [] : [.startDrawing]
        case .pauseOrResume:
            guard !isBusy, !isPicking else {
                return []
            }
            if isRecordMode {
                return [.record]
            }
            return open.pauses.isEmpty ? [.togglePause] : [.resume]
        default:
            return []
        }
    }

    /// Send and ⌘↩ have something to send, and nothing is starting or finishing.
    func canSend(_ facts: Facts) -> Bool {
        guard case .open(let open) = mode, !isPicking, open.question == nil else {
            return false
        }
        switch open.activity {
        case .recording(.starting), .recording(.finishing): return false
        default: return facts.notes > 0 || holdsClip || open.panel == .comment
        }
    }

    // MARK: - Rules

    /// Set by a rule that leaves the session on screen, for sending or for its end; `handle`
    /// takes it as the new mode.
    private var leaving: Mode?
    /// The facts of the event that `handle` works on, as the event changes them: a saved clip
    /// is a note. They are no part of the state: `handle` takes them away again.
    private var facts = Facts()

    init(mode: Mode = .open(Open()), lastOperation: Int = 0) {
        self.mode = mode
        self.lastOperation = lastOperation
    }

    private mutating func nextOperation() -> Int {
        lastOperation += 1
        return lastOperation
    }

    mutating func handle(_ event: Event, _ facts: Facts) -> [Effect] {
        self.facts = facts
        defer {
            self.facts = Facts()
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
        case .sending(let operation, var returnTo):
            let effects = handleSending(event, operation: operation, returnTo: &returnTo)
            if case .sending = mode {
                mode = .sending(operation: operation, returnTo: returnTo)
            }
            return effects
        case .open(var open):
            let effects: [Effect]
            if case .picking(let isPickerOpen) = open.activity {
                effects = handlePicking(event, isPickerOpen: isPickerOpen, &open)
            } else if open.question != nil, !Self.isAnswer(event) {
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
        case .begin:
            // Annotation mode never turns on by itself: a session starts with no mode, the
            // HUD on screen and the apps below taking clicks, until the user turns it on.
            mode = .open(Open(pauses: [.user]))
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
    private static func isAnswer(_ event: Event) -> Bool {
        switch event {
        case .confirm, .dismissConfirmation, .escape, .ended, .holdEnded, .otherAppInFront, .scopeAppInFront,
             .clipStarted, .clipStartFailed, .clipFinished, .clipFailed, .captureStopped, .windowClosed:
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
        case .clearAll: facts.notes > 0
        case .cancelSession: facts.notes > 0 || open.holdsClip
        case .restore, nil: true
        }
        if !isAboutSomething {
            open.question = nil
        }
    }

    /// While choosing, only the source button, Esc (or the picker's Back), the picker, a
    /// choice and the buttons of the modes act, and the front app and hold key keep the pause
    /// the session goes back to; nothing else does anything.
    private mutating func handlePicking(_ event: Event, isPickerOpen: Bool, _ open: inout Open) -> [Effect] {
        let back = Activity.recording(.ready)
        switch event {
        case .escape:
            // One level back at a time, as in the preview: the open picker, then choosing.
            if isPickerOpen {
                open.activity = .picking(isPickerOpen: false)
                choosesInPicker = false
                return [.closePicker]
            }
            open.activity = back
            return [.stopPicking]
        case .pickSource:
            open.activity = back
            return [.stopPicking]
        case .openPicker:
            open.activity = .picking(isPickerOpen: true)
            choosesInPicker = true
            return [.openPicker]
        case .toggleRecordingMode:
            // Choosing ends with no change, and the toggle goes back to annotating.
            open.activity = back
            return [.stopPicking] + handleOpen(.toggleRecordingMode, &open)
        case .toggleAnnotating, .startDrawing, .startWireframe:
            // Choosing ends with no change, and recording mode leaves for that mode.
            var ready = open
            ready.activity = back
            let switched = handleOpen(event, &ready)
            guard !switched.isEmpty else {
                return []
            }
            open = ready
            return [.stopPicking] + switched
        case .choose:
            open.activity = back
            return [.applySource, .stopPicking]
        case .holdEnded:
            return endHold(&open)
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

        case .toggleAnnotating:
            return toggleAnnotating(&open)

        case .resume:
            guard open.activity == .annotating else {
                return []
            }
            return open.pauses.contains(.user) ? togglePause(&open) : endOtherAppPause(&open)

        case .startShortcut:
            return open.activity == .annotating && open.pauses.contains(.user) ? togglePause(&open) : [.showHUD]

        case .requestClearAll:
            guard facts.notes > 0 else {
                return []
            }
            // A question never opens over a comment: one with text asks about it first.
            if open.panel == .comment, facts.commentHasText {
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
            if open.panel == .comment, facts.commentHasText {
                return leaveComment(&open)
            }
            let closes = finishDrawingAndPanel(&open)
            guard facts.notes > 0 else {
                return closes + [.restoreDrafts]
            }
            open.question = .restore
            return closes + [.askRestore]

        case .openBrowser:
            // The browser limits the session to its window, as choosing it does.
            guard open.canPick else {
                return []
            }
            if open.panel == .comment, facts.commentHasText {
                return leaveComment(&open)
            }
            return finishDrawingAndPanel(&open) + [.openBrowser]

        case .deleteNote:
            return facts.notes > 0 ? [.deleteNote] : []

        case .editNote:
            return facts.notes > 0 ? [.editNote] : []

        case .confirm:
            return confirm(&open)

        case .dismissConfirmation:
            return dismiss(&open)

        case .holdBegan:
            // Not while typing a comment, where these keys are for the text, nor in wireframe
            // mode, where ⌥ and a drag copies a component.
            guard open.activity == .annotating, open.panel == nil, open.pauses.isEmpty, open.canvas != .wireframe else {
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
            if facts.commentIsOnDrawing, !facts.commentHasText {
                return submitComment(&open)
            }
            return leaveComment(&open)

        case .submitComment:
            return submitComment(&open)

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
            if case .recording = open.activity {
                return leaveRecording(for: .draw, &open)
            }
            guard open.activity == .annotating, !open.isDrawing else {
                return []
            }
            return openCanvas(.draw, &open)

        case .startWireframe:
            guard facts.wireframesOn else {
                return []
            }
            if case .recording = open.activity {
                return leaveRecording(for: .wireframe, &open)
            }
            guard open.activity == .annotating, open.canvas != .wireframe else {
                return []
            }
            // Draw's canvas goes to wireframe mode as it is.
            if open.canvas == .draw {
                open.canvas = .wireframe
                return [.showWireframe]
            }
            return openWireframe(&open)

        case .shapeFinished:
            // A wireframe's components get no comment each.
            return open.canvas == .draw && open.panel != .comment ? [.openShapeComment] : []

        case .undoDrawing:
            return open.isDrawing ? [.undoShape] : []

        case .redoDrawing:
            return open.isDrawing ? [.redoShape] : []

        case .finishDrawing:
            // A wireframe becomes a note first; `wireframeTaken` then ends the mode.
            return open.canvas == .wireframe ? [.takeWireframe] : leaveDrawing(&open)

        case .wireframeTaken:
            return open.canvas == .wireframe ? leaveDrawing(&open) : []

        case .toggleRecordingMode:
            if case .recording = open.activity {
                return leaveRecording(&open)
            }
            // Recording mode starts by choosing what to record, the way the user last chose.
            let entered = enterRecording(&open)
            guard open.activity == .recording(.ready) else {
                return entered
            }
            return entered + startPicking(&open)

        case .record:
            return record(&open)

        case .stop:
            guard open.clipInProgress else {
                return []
            }
            open.activity = .recording(.finishing(operation: nextOperation(), then: .stay))
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
            return endClipOfLostSource(&open)

        case .windowClosed:
            // A clip of the window ends with it; annotating covers everything again, with no
            // mode on.
            let ended = endClipOfLostSource(&open)
            guard open.activity == .annotating, open.pauses.isEmpty, open.question == nil else {
                return ended
            }
            return ended + togglePause(&open)

        case .clipFinished(let operation):
            guard case .recording(.finishing(operation, let then)) = open.activity else {
                return [.dropClip]
            }
            open.activity = .recording(.ready)
            facts.notes += 1
            return [.keepClip] + afterClip(then, &open)

        case .clipFailed(let operation):
            guard case .recording(.finishing(operation, _)) = open.activity else {
                return []
            }
            open.activity = .recording(.ready)
            return [.showSaveFailure]

        case .pickSource:
            // Only recording mode chooses a source, before Record: notes keep their own window.
            guard open.activity == .recording(.ready) else {
                return []
            }
            if open.panel == .comment, facts.commentHasText {
                return leaveComment(&open)
            }
            return finishDrawingAndPanel(&open) + startPicking(&open)

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
        // Esc never ends Draw or Wireframe: it puts the tool down, so that nothing draws. Only
        // the pause command pauses them.
        if open.isDrawing {
            return open.pauses.isEmpty ? [.putToolDown] : []
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
        if open.panel == .comment, facts.commentHasText {
            return leaveComment(&open)
        }
        let closes = open.panel == .comment ? closePanel(&open) : []
        guard facts.notes > 0 || open.holdsClip else {
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
        // A pause keeps Draw, with the drawing on screen; the canvas lets the mouse through.
        if open.pauses.contains(.user) {
            // Annotate pressed on purpose resumes, whatever app was last in front.
            open.pauses.remove(.user)
            open.pauses.remove(.otherApp)
            return [.applyPause, .takeKeyboard]
        }
        open.pauses.insert(.user)
        return [.applyPause, .giveKeyboardBack, .takeKeyboard]
    }

    /// Annotation mode on: from Draw, recording mode, a pause or no mode. Off: no mode.
    private mutating func toggleAnnotating(_ open: inout Open) -> [Effect] {
        if case .recording = open.activity {
            return leaveRecording(for: .annotating, &open)
        }
        guard open.activity == .annotating else {
            return []
        }
        if open.isDrawing {
            return finishDrawing(&open) + startAnnotating(&open)
        }
        // A pause for another app ends too, as for the pause by the user.
        if open.pauses.contains(.otherApp) {
            return startAnnotating(&open)
        }
        return togglePause(&open)
    }

    private func startAnnotating(_ open: inout Open) -> [Effect] {
        open.pauses.remove(.user)
        open.pauses.remove(.otherApp)
        return [.applyPause, .takeKeyboard]
    }

    /// Draw and Wireframe are modes of their own: the canvas opens from annotation mode and
    /// from no mode.
    private func openCanvas(_ canvas: Canvas, _ open: inout Open) -> [Effect] {
        // A comment with text asks first, like leaving it any other way.
        if open.panel == .comment, facts.commentHasText {
            return leaveComment(&open)
        }
        let closes = closePanel(&open)
        open.canvas = canvas
        guard open.pauses.contains(.user) else {
            return closes + [.showCanvas]
        }
        open.pauses.remove(.user)
        return closes + [.applyPause, .showCanvas]
    }

    private func openWireframe(_ open: inout Open) -> [Effect] {
        let opened = openCanvas(.wireframe, &open)
        return open.canvas == .wireframe ? opened + [.showWireframe] : opened
    }

    /// Another mode's button or key in recording mode: a clip in progress is stopped and kept,
    /// as Stop keeps it, and the mode comes once it is saved. Nothing while a clip starts or
    /// is saved.
    private mutating func leaveRecording(for other: OtherMode, _ open: inout Open) -> [Effect] {
        switch open.activity {
        case .recording(.ready), .recording(.recording), .recording(.paused):
            break
        default:
            return []
        }
        // A comment with text asks first, as leaving it any other way does.
        if open.panel == .comment, facts.commentHasText {
            return leaveComment(&open)
        }
        guard open.clipInProgress else {
            return exitRecording(&open) + enter(other, &open)
        }
        open.activity = .recording(.finishing(operation: nextOperation(), then: .switchTo(other)))
        return [.finishClip]
    }

    private func enter(_ other: OtherMode, _ open: inout Open) -> [Effect] {
        switch other {
        case .annotating: startAnnotating(&open)
        case .draw: openCanvas(.draw, &open)
        case .wireframe: openWireframe(&open)
        }
    }

    /// After a clip is saved: send, or leave for another mode. A question or a comment with
    /// text keeps the session in recording mode, ready.
    private mutating func afterClip(_ then: AfterClip, _ open: inout Open) -> [Effect] {
        switch then {
        case .stay:
            return []
        case .send:
            return send(&open)
        case .switchTo(let other):
            guard open.question == nil, !(open.panel == .comment && facts.commentHasText) else {
                return []
            }
            return exitRecording(&open) + enter(other, &open)
        }
    }

    /// The source went away: the clip ends at its last frame and goes to the list.
    private mutating func endClipOfLostSource(_ open: inout Open) -> [Effect] {
        guard open.clipInProgress else {
            return []
        }
        open.activity = .recording(.finishing(operation: nextOperation(), then: .stay))
        return [.finishClip, .showSourceGone]
    }

    /// Done in Draw or Wireframe: no mode, not annotation mode; Tilde keeps the keyboard for its keys.
    private func leaveDrawing(_ open: inout Open) -> [Effect] {
        let finished = finishDrawing(&open)
        guard !finished.isEmpty else {
            return []
        }
        open.pauses.insert(.user)
        return finished + [.applyPause, .keepKeyboard]
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
        if open.panel == .comment, facts.commentHasText {
            return leaveComment(&open)
        }
        let closes = finishDrawingAndPanel(&open)
        open.activity = .recording(.ready)
        return closes + [.enterRecording]
    }

    private func startPicking(_ open: inout Open) -> [Effect] {
        open.activity = .picking(isPickerOpen: choosesInPicker)
        return [.startPicking] + (choosesInPicker ? [.openPicker] : [])
    }

    /// Esc and the record toggle: back to no mode; a clip that is not stopped is lost, so
    /// that asks first. A clip being saved finishes first.
    private func leaveRecording(_ open: inout Open) -> [Effect] {
        switch open.activity {
        case .recording(.recording), .recording(.paused):
            // A question never opens over a comment: one with text asks about it first.
            if open.panel == .comment, facts.commentHasText {
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
        open.pauses.insert(.user)
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
            // The comment becomes a note.
            effects = submitComment(&open)
            facts.notes = max(facts.notes, 1)
        }
        if open.clipInProgress {
            open.activity = .recording(.finishing(operation: nextOperation(), then: .send))
            return effects + [.finishClip]
        }
        guard facts.notes > 0 else {
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
        guard facts.commentHasText else {
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
        guard let canvas = open.canvas else {
            return []
        }
        open.canvas = nil
        // A wireframe's components that Done did not take go with the mode.
        return canvas == .wireframe ? [.endWireframe, .keepDrawing] : [.keepDrawing]
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
