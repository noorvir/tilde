import TildeCore
import AppKit
import Combine
import os

/// The session on screen. It sends every event to `SessionFlow` and runs the effects, keeps
/// the session's notes, and starts, stops and joins the parts that do the work: each part
/// tells the controller what happened, and the controller tells the other parts. Views
/// observe it.
@MainActor
final class AnnotationController: ObservableObject {
    typealias PauseReason = SessionFlow.PauseReason

    // MARK: - The session and its notes

    /// What the session on screen does; every change goes through `dispatch(_:)`.
    @Published private(set) var flow = SessionFlow(mode: .idle) {
        didSet {
            updateOverlayInput()
            tracker.isPaused = !pauses.isEmpty
        }
    }
    var mode: SessionFlow.Mode { flow.mode }
    /// A session is on screen, also while its report is being made.
    var isOpen: Bool { flow.session != nil }
    /// Why annotating is paused; empty while annotating and in the other modes.
    var pauses: Set<PauseReason> {
        guard let open = flow.session, open.activity == .annotating else {
            return []
        }
        return open.pauses
    }
    /// The clip of recording mode, or nil in any other mode.
    var recording: SessionFlow.Clip? { flow.clip }
    var isPickingWindow: Bool { flow.isPicking }
    /// Recording mode, also while choosing its next clip's source.
    var isRecordMode: Bool { flow.isRecordMode }
    /// While choosing, the source picker is open in full in place of its "Use window picker"
    /// button, and clicks on screen choose nothing.
    var isSourcePickerOpen: Bool {
        if case .picking(isPickerOpen: true) = flow.session?.activity {
            return true
        }
        return false
    }
    /// A question in the pill, waiting for the user.
    var confirmation: SessionFlow.Question? { flow.session?.question }
    var isDrawing: Bool { flow.session?.isDrawing ?? false }
    /// Whether the overlay takes the pointer (hover, picks, clicks, the crosshair) and the
    /// keyboard: while annotating, and while choosing a window in any mode.
    var overlayTakesInput: Bool { flow.overlayTakesInput }
    /// The confirmation after Send, such as "Sent to Codex", while it shows.
    var sentConfirmation: String? {
        if case .sent = mode {
            return notices.sentText
        }
        return nil
    }

    @Published private(set) var session: SessionStore.Session?
    @Published private(set) var drafts: [Draft] = [] {
        didSet {
            if let session, drafts.count != oldValue.count {
                store.updateNoteCount(drafts.count, for: session.id)
            }
            browser.anchors = Dictionary(uniqueKeysWithValues: drafts.compactMap { draft in draft.anchor.map { (draft.id, $0) } })
            tracker.notes = drafts
            saver.saveSoon()
        }
    }
    /// The comment box's data while `flow` has it open.
    @Published private(set) var composer: Composer? {
        didSet {
            tracker.isHeld = composer != nil
            saver.isHeld = composer != nil
        }
    }
    /// The comment's text. Apart from the rest of the state: typing must not redraw the HUD
    /// and the overlay.
    let commentDraft = CommentDraft()
    var commentText: String {
        get { commentDraft.text }
        set { commentDraft.text = newValue }
    }
    /// The draft shown in the preview card while `flow` has it open; annotate clicks wait.
    @Published private(set) var previewID: Draft.ID?
    /// The screenshot that fills the preview card's image area, if any.
    @Published var expandedPreviewImage: PreviewImage?
    /// The saved session that the restore question offers.
    private(set) var restoreRecord: SessionRecord?
    /// A saved session whose notes the next session starts with.
    private var pendingRestore: SessionRecord?

    // MARK: - The HUD

    /// Whether the HUD pill is open. HUDPanel animates it, so the pill grows out of its centre
    /// when it appears and collapses into it before the panel hides.
    @Published var isHUDShown = false
    /// The HUD is in the toolbar of Tilde's browser, as the session is limited to it, and the
    /// floating HUD is hidden. It stays there through the Sent confirmation.
    @Published private(set) var isHUDInBrowser = false
    /// The display the floating HUD is on, which its panel keeps up to date as it is placed
    /// and dragged.
    @Published var hudDisplay: CGDirectDisplayID?
    @Published var showsList = false
    /// The icon of the agent app with this display name, for the HUD; nil when unknown.
    var clientIcon: (String) -> NSImage? = { _ in nil }
    /// The status of the remote machine with this name, for the HUD's machine icon.
    var machineDot: (String) -> NodeSetup.Dot = { _ in .grey }
    /// A screen's name as the system gives it; pictures of the HUD give a stand-in, so that
    /// they never show the name of the Mac that drew them.
    var screenName: (CGDirectDisplayID) -> String = SourcePickerModel.name(of:)

    // MARK: - Parts

    /// What the session annotates and records, and the window it is limited to.
    let scope: SessionScope
    /// Where each note is on screen now, and whether it shows.
    let tracker: NoteTracker
    /// The element under the pointer.
    let hoverPicker: HoverPicker
    var hover: Picked? {
        get { hoverPicker.picked }
        set { hoverPicker.picked = newValue }
    }
    /// Draw mode: the canvas, and the notes that shapes become.
    let drawing: DrawingNotes
    /// The clip of recording mode.
    private(set) lazy var clips: ClipRecorder = {
        let clips = ClipRecorder()
        clips.dispatch = { [weak self] event, data in
            self?.dispatch(event, with: data)
        }
        clips.keep = { [weak self] draft in
            self?.drafts.append(draft)
        }
        return clips
    }()
    /// The source picker under the HUD while choosing.
    let sourcePicker = SourcePickerModel()
    /// What the HUD says for a moment: a notice, the note after a pause, the confirmation after Send.
    let notices = Notices()
    /// The bar under the HUD that offers Tilde's browser for a page in another browser.
    let browserOffer = BrowserOffer()
    /// Where sessions are saved while in progress and kept afterwards.
    let archive: SessionArchive
    let saver: SessionSaver
    var sender = ReportSender()
    /// Comments typed into the preview or the browser's notes panel, until typing pauses.
    private let typedComments = TypedComments()
    /// The double tap, the hold key and the answers to a question.
    private let keyMonitors: KeyMonitors
    let picker: ElementPicker
    private lazy var overlays = OverlayStack { [unowned self] frame, level, isWindowSized in
        OverlayWindow(frame: frame, level: level, isWindowSized: isWindowSized, controller: self)
    }
    private lazy var hud = HUDPanel(controller: self)
    private lazy var commentPanel = CommentPanel(controller: self)
    private lazy var previewPanel = PreviewPanel(controller: self)

    private let store: SessionStore
    let browser: BrowserController
    let shortcuts: ShortcutStore
    /// Keeps how the user last chose a window across launches; nil keeps it only in memory.
    private let defaults: UserDefaults?
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")
    private var subscription: AnyCancellable?
    /// Views observe the controller; it sends on the changes of the parts that the HUD shows.
    private var partChanges: [AnyCancellable] = []
    /// The app that was in front when an agent's session opened Tilde's browser. The session
    /// ends with the browser closed and this app in front again, so the user is back in the chat.
    private var returnApp: NSRunningApplication?
    /// The next session that starts from Tilde is limited to the browser window.
    private var scopesNextLocalSessionToBrowser = false

    init(store: SessionStore, browser: BrowserController, shortcuts: ShortcutStore? = nil, archive: SessionArchive = SessionArchive(), defaults: UserDefaults? = .standard) {
        self.store = store
        self.browser = browser
        self.archive = archive
        saver = SessionSaver(archive: archive)
        self.defaults = defaults
        let shortcuts = shortcuts ?? ShortcutStore()
        self.shortcuts = shortcuts
        keyMonitors = KeyMonitors(shortcuts: shortcuts)
        picker = ElementPicker(browser: browser)
        hoverPicker = HoverPicker(picker: picker)
        scope = SessionScope(picker: picker, browser: browser)
        drawing = DrawingNotes(picker: picker)
        tracker = NoteTracker(windows: picker.windows, browser: browser)
        flow.choosesInPicker = defaults?.bool(forKey: "ChoosesInPicker") ?? false

        subscription = store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncWithStore() }
        browser.controller = self
        partChanges = [notices.objectWillChange, scope.objectWillChange, drawing.objectWillChange, browserOffer.objectWillChange].map { changes in
            changes.sink { [weak self] in self?.objectWillChange.send() }
        }
        joinParts()
    }

    /// Gives each part what it asks of the session, and takes what it reports.
    private func joinParts() {
        saver.snapshot = { [weak self] in self?.snapshot }
        notices.onSentShown = { [weak self] operation in self?.dispatch(.sentShown(operation)) }
        typedComments.onPause = { [weak self] in self?.saveTypedComments() }

        scope.onChange = { [weak self] in self?.sourceChanged() }
        scope.onCheck = { [weak self] delta in self?.scopeChecked(movedBy: delta) }
        scope.onGone = { [weak self] in self?.scopeEnded() }
        scope.onFrontApp = { [weak self] pid in self?.frontmostAppChanged(to: pid) }
        scope.canChange = { [weak self] in self?.flow.canPick == true && self?.isPickingWindow == false }
        // The window never came on screen: the session covers everything.
        scope.onBrowserMissing = { [weak self] in self?.placeHUD() }

        // Also when the stack is the same: the browser's page notes can have come or gone.
        picker.windows.onRead = { [weak self] isChanged in
            self?.tracker.refreshCovers()
            self?.scope.windowsRead()
            if isChanged {
                self?.tracker.somethingChanged()
            }
        }
        picker.windows.onInput = { [weak self] in self?.tracker.somethingChanged() }

        hoverPicker.scope = { [weak self] in self?.scope.window }
        hoverPicker.shows = { [weak self] in
            guard let self else {
                return false
            }
            return composer == nil && !isPickingWindow
        }
        hoverPicker.onScrollEnded = { [weak self] in self?.refreshHover() }

        keyMonitors.onDoubleTap = { [weak self] key in self?.doubleTapped(key) }
        keyMonitors.onHold = { [weak self] output in self?.holdChanged(output) }
        keyMonitors.onQuestionKey = { [weak self] keyCode, modifiers, window in
            self?.handleConfirmationKey(keyCode, modifiers: modifiers, in: window) == true
        }

        drawing.scope = { [weak self] in self?.scope.window }
        drawing.isOnLabel = { [weak self] point in self?.tracker.label(at: point) != nil }
        let canvas = drawing.panel
        canvas.onEscape = { [weak self] in self?.escapePressed() }
        canvas.onShape = { [weak self] in self?.dispatch(.shapeFinished) }
        canvas.onEdited = { [weak self] in self?.updateEditedDrawing() }
        canvas.onClickAway = { [weak self] in
            self?.dispatch(.clickAway)
            // The click gave the canvas the keyboard; a question in the comment box needs it.
            if self?.composer != nil {
                self?.commentPanel.focus()
            }
        }
        canvas.onPointer = { [weak self] point in
            guard let self else {
                return
            }
            let isOverLabel = tracker.label(at: point) != nil
            if isOverLabel {
                hover = nil
            }
            drawing.pointerMoved(to: point, isOverLabel: isOverLabel)
        }
        canvas.onKey = { [weak self] in self?.handleKey($0, in: .canvas) ?? false }
        canvas.onPress = { [weak self] point in
            guard let self, let id = tracker.label(at: point) else {
                return false
            }
            preview(id)
            return true
        }
    }

    // MARK: - The flow

    /// What the flow's rules read of the notes and the comment being written, as they are now.
    var facts: SessionFlow.Facts {
        var facts = SessionFlow.Facts(notes: drafts.count)
        facts.commentHasText = !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if case .new(let pending) = composer {
            facts.commentIsOnDrawing = !pending.drawingIDs.isEmpty
        }
        return facts
    }

    /// Whether the event would do anything now; a control that sends it is enabled only then.
    func accepts(_ event: SessionFlow.Event) -> Bool {
        flow.accepts(event, facts)
    }

    /// Send and ⌘↩ have something to send, and nothing is starting or finishing.
    var canSend: Bool {
        flow.canSend(facts)
    }

    /// Notes change only when the flow takes it: not under a question, while choosing or while
    /// the report is made.
    var canEditNotes: Bool {
        accepts(.editNote)
    }

    /// The one way the session's mode changes: the flow decides from the facts as they are
    /// now, then its effects run. `with` gives the data of the effects that need it, as what
    /// to do for them, such as showing the comment box that the caller built; one the flow
    /// does not return is dropped.
    func dispatch(_ event: SessionFlow.Event, with data: [SessionFlow.Effect: () -> Void] = [:]) {
        // A comment typed in the preview is saved first: the event may open a question or a
        // mode in which notes cannot be edited.
        if event != .editNote {
            saveTypedComments()
        }
        var next = flow
        let effects = next.handle(event, facts)
        let questionChanged = next.session?.question != flow.session?.question
        if next.choosesInPicker != flow.choosesInPicker {
            defaults?.set(next.choosesInPicker, forKey: "ChoosesInPicker")
        }
        flow = next
        if questionChanged {
            keyMonitors.watchQuestion(confirmation != nil)
        }
        for effect in effects {
            if let withData = data[effect] {
                withData()
            } else {
                run(effect)
            }
        }
    }

    private func run(_ effect: SessionFlow.Effect) {
        switch effect {
        // Their data comes with the event that returns them.
        case .showComment, .showPreview, .applySource, .finishSend, .adoptClip, .keepClip, .dropClip, .showPushFailure,
             .askRestore, .deleteNote, .editNote:
            assertionFailure("\(effect) came without the data of its event")
        case .applyPause: applyPause()
        case .closeComposer: discardComposer()
        case .saveComment: saveComment()
        case .closePreview: hidePreview()
        case .toggleList: toggleList()
        case .showCanvas: showCanvas()
        case .undoShape: undoLastDrawing()
        case .redoShape: redoLastDrawing()
        case .openShapeComment:
            Task { await addDrawingNote() }
        case .keepDrawing:
            drawing.panel.endEditing()
            drawing.panel.stopDrawing()
            drawing.panel.setSnapFrame(nil)
            hover = nil
            if composer == nil {
                drawing.panel.hide()
            }
            if isHUDInBrowser {
                hud.hide()
            }
            // The canvas has had the keyboard: Esc and ⌘↩ belong to the overlay again.
            makeOverlayKey()
        case .keepKeyboard:
            // The next Esc must reach Tilde; a click in another app gives that app the keyboard.
            if !isHUDInBrowser {
                overlays.makeKey()
            }
        case .giveKeyboardBack:
            // A key overlay would keep the keyboard; give it back to the user's app.
            NSWorkspace.shared.frontmostApplication?.activate()
        case .takeKeyboard: makeOverlayKey()
        case .showEscapeNotice: notices.showPause(.escape)
        case .showOtherAppNotice: notices.showPause(.otherApp)
        case .clearNotice: notices.clearPause()
        case .endSession: end()
        case .cancelSession: cancelSession()
        case .clearDrafts:
            drafts.forEach(ClipRecorder.deleteVideo)
            drafts = []
        case .restoreDrafts:
            if let record = restoreRecord {
                replaceDrafts(with: record)
            }
        case .startLocalSession: startLocal()
        case .showHUD:
            if isHUDInBrowser {
                browser.show()
            } else {
                hud.show()
            }
        case .hideHUD: hideHUD()
        case .plainClicksOn:
            PlainClickTap.start(removing: keyMonitors.holdFlag)
        case .plainClicksOff:
            PlainClickTap.stop()
        case .enterRecording:
            hover = nil
            scope.enterRecording()
        case .exitRecording:
            clips.discard()
            scope.exitRecording()
            frontmostAppChanged(to: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        case .startClip: startClip()
        case .pauseClip: clips.pause()
        case .resumeClip: clips.resume()
        case .finishClip:
            if case .finishing(let operation, _) = recording {
                clips.finish(operation: operation)
            }
        case .showStartFailure: notices.show(.recordingFailed)
        case .showSaveFailure: notices.show(.recordingNotSaved)
        case .showSourceGone: notices.show(.recordingStopped)
        case .startPicking:
            showsList = false
            hover = nil
            pickingChanged()
        case .stopPicking:
            hover = nil
            sourcePicker.stopLoading()
            pickingChanged()
        case .openPicker: openPicker()
        case .openBrowser: openBrowser(at: nil)
        case .closePicker:
            hover = nil
            sourcePicker.stopLoading()
        case .startSend: startSend()
        case .showSendFailure: notices.show(.reportNotSaved)
        }
    }

    /// Esc, and the picker's "‹ Back".
    func escapePressed() {
        // In the picker, Esc first goes from an app's windows back to the apps.
        if isSourcePickerOpen, sourcePicker.openApp != nil {
            sourcePicker.openApp = nil
            return
        }
        dispatch(.escape)
    }

    /// The HUD's leading button: records, pauses or resumes a clip in recording mode; else
    /// resumes after any pause, or pauses.
    func pressStatusButton() {
        if isRecordMode {
            dispatch(.record)
        } else if !pauses.isEmpty {
            dispatch(.resume)
        } else {
            dispatch(.togglePause)
        }
    }

    // MARK: - Session lifecycle

    private func syncWithStore() {
        let active = store.active
        guard active?.id != session?.id else {
            return
        }

        if let active {
            begin(active)
        } else if isOpen {
            dispatch(.ended)
        }
    }

    private func begin(_ session: SessionStore.Session) {
        self.session = session
        browserOffer.reset()
        drafts = []
        hover = nil
        composer = nil
        previewID = nil
        showsList = false
        scope.reset()
        PageIdentity.askAppsToDescribeWebContent()
        drawing.panel.prepare()
        log.notice("session \(session.id, privacy: .public) started for \(session.client, privacy: .public)")

        var created = Date()
        if let record = pendingRestore {
            pendingRestore = nil
            if record.id == session.id {
                created = record.created
            }
            drafts = SessionSaver.drafts(from: record, archive: archive, into: session.id)
        }
        saver.start(created: created)
        keyMonitors.startHold()
        picker.windows.start()
        saver.save()

        if session.url != nil, !session.isLocal, let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
            returnApp = frontmost
        }
        // A session in the browser starts paused, so the user can type an address and browse
        // first; Annotate in the HUD (or the pause shortcut) starts annotating.
        let isInBrowser = session.url != nil || (session.isLocal && scopesNextLocalSessionToBrowser)
        scopesNextLocalSessionToBrowser = false
        dispatch(.begin(inBrowser: isInBrowser))

        layoutOverlays()
        if isInBrowser {
            // The HUD shows once the browser's window is on screen, in its toolbar.
            openBrowser(at: session.url)
        } else {
            placeHUD()
        }
    }

    /// Closes the session on screen. After Send the HUD shows the confirmation for a moment;
    /// otherwise it goes at once.
    private func end() {
        stopAnnotating()
        saver.stop()
        session = nil
        drafts = []
        scope.reset()
        browserOffer.reset()

        if let returnApp {
            self.returnApp = nil
            browser.close()
            // The browser's HUD goes with it, so the confirmation shows in the floating one.
            if isHUDInBrowser {
                isHUDInBrowser = false
                if case .sent = mode {
                    hud.show()
                }
            }
            NSApp.yieldActivation(to: returnApp)
            ElementPicker.bringToFront(returnApp)
        }

        if case .sent(let operation) = mode {
            notices.endSent(operation, after: 1.6)
        } else {
            hideHUD()
        }
    }

    /// Closes everything that annotates: the overlays, the comment, the preview, the hover and
    /// the input monitors. The HUD stays, for the confirmation after Send.
    private func stopAnnotating() {
        clips.discard()
        keyMonitors.stopHold()
        PlainClickTap.stop()
        dispatch(.holdEnded)
        picker.windows.stop()
        tracker.stop()
        notices.clearPause()
        drawing.panel.endSession()
        commentPanel.close()
        previewPanel.close()
        previewID = nil
        overlays.close()
        hover = nil
        composer = nil
    }

    /// Starts a session from Tilde itself. Its feedback goes to the clipboard and the inbox.
    /// While a session is on screen, brings the HUD forward instead.
    func startLocal() {
        if session != nil {
            if isHUDInBrowser {
                browser.show()
            } else {
                hud.show()
            }
            return
        }
        _ = store.start(client: "You", url: nil, isLocal: true)
    }

    /// Opens Tilde's browser and annotates only in it: a new session from Tilde, which starts
    /// paused, or the session on screen.
    func annotateInBrowser() {
        if session != nil {
            dispatch(.openBrowser)
            return
        }
        scopesNextLocalSessionToBrowser = true
        _ = store.start(client: "You", url: nil, isLocal: true)
    }

    private func cancelSession() {
        guard let session else {
            return
        }
        log.notice("session \(session.id, privacy: .public) cancelled")
        // A cancelled session keeps its notes in History, stopped recordings included; only a
        // clip still in progress goes, with the session's end.
        saver.save(state: .cancelled)
        store.finish(session.id, with: .cancelled)
        dispatch(.ended)
    }

    // MARK: - Sending

    /// Makes the report: waits for the captures, then saves it to the inbox. "Sent" or
    /// "Copied" shows only once that is done; a failure leaves the session as it was.
    private func startSend() {
        guard let session, case .sending(let operation, _) = mode else {
            return
        }
        let drafts = self.drafts
        Task {
            let report: ReportSender.Report
            do {
                report = try await sender.save(drafts, of: session)
            } catch {
                log.error("could not save feedback to inbox: \(error.localizedDescription, privacy: .public)")
                dispatch(.sendFailed(operation))
                return
            }
            dispatch(.sendFinished(operation), with: [.finishSend: { [self] in
                finishSend(session, report)
            }])
        }
    }

    private func finishSend(_ session: SessionStore.Session, _ report: ReportSender.Report) {
        log.notice("session \(session.id, privacy: .public) sent with \(report.feedback.annotations.count) annotations")
        if session.isLocal {
            sender.copy(report)
            notices.showSent("Copied", status: .done)
        } else {
            notices.showSent("Sent to \(session.client)", status: .done)
        }
        saver.save(state: .sent, reportFolder: report.folder)
        store.finish(session.id, with: .sent(report.feedback, folder: report.folder))
        end()

        // A copy's images go to the remote machines in the background; a machine they do not
        // reach gets its own short warning.
        guard session.isLocal else {
            return
        }
        Task {
            let failed = await sender.push(report)
            guard !failed.isEmpty else {
                return
            }
            dispatch(.pushFailed, with: [.showPushFailure: { [self] in
                notices.showSent(RemotePush.failure(failed), status: .failed)
                if case .sent(let operation) = mode {
                    hud.show()
                    notices.endSent(operation, after: 4)
                }
            }])
        }
    }

    // MARK: - Saving and restoring

    /// The session on screen as it is now, for its saved record.
    private var snapshot: SessionSaver.Snapshot? {
        guard let session else {
            return nil
        }
        return SessionSaver.Snapshot(session: session, drafts: drafts, pageURL: scope.isBrowser ? browser.pageURL : nil, scopeApp: scope.name)
    }

    /// Brings back a saved session's notes, also a sent one, to edit and send again: into the
    /// session on screen, or a new session from Tilde (in the browser at its page, for a
    /// browser session). An unfinished or cancelled one is marked restored, so it is not
    /// offered again; a sent one stays sent.
    func restore(_ record: SessionRecord) {
        if session != nil {
            // Notes on screen are replaced only after the HUD asks; the saved session is kept
            // only when the flow takes the restore.
            dispatch(.restore, with: [
                .askRestore: { [self] in
                    restoreRecord = record
                    placeHUD()
                },
                .restoreDrafts: { [self] in
                    restoreRecord = record
                    replaceDrafts(with: record)
                    placeHUD()
                },
            ])
            return
        }
        saver.markRestored(record)
        pendingRestore = record
        _ = store.start(client: "You", url: record.pageURL.flatMap(URL.init(string:)), isLocal: true)
    }

    /// The session on screen takes a saved session's notes, in their order, and its page in
    /// Tilde's browser.
    private func replaceDrafts(with record: SessionRecord) {
        saver.markRestored(record)
        if let session {
            drafts = SessionSaver.drafts(from: record, archive: archive, into: session.id)
        }
        if let page = record.pageURL.flatMap(URL.init(string:)), browser.pageURL != record.pageURL {
            openBrowser(at: page)
        }
    }

    /// Starts an agent's unfinished session again under its own id, with its notes, when the
    /// agent waits for it after Tilde restarted. Returns whether it did.
    func reattach(_ id: String, node: String?) -> Bool {
        guard let record = archive.record(id), record.state == .active, !record.isLocal, record.node == node else {
            return false
        }
        pendingRestore = record
        _ = store.start(id: record.id, client: record.client, node: record.node, url: record.pageURL.flatMap(URL.init(string:)))
        return true
    }

    // MARK: - Windows and the keyboard

    /// The HUD goes in the browser's toolbar while the session is limited to the browser, and
    /// floats over the screen otherwise.
    private func placeHUD() {
        guard session != nil, isOpen else {
            return
        }
        // In Tilde's browser the HUD stays in its toolbar, and the floating panel shows only
        // the picker, under the toolbar, while choosing.
        isHUDInBrowser = scope.isBrowser
        if isHUDInBrowser, isPickingWindow, let frame = browser.window?.frame {
            hud.show(top: NSPoint(x: frame.midX, y: frame.maxY - BrowserMetrics.toolbarHeight + 10))
        } else if isHUDInBrowser {
            hud.hide()
        } else if !isHUDShown {
            hud.show()
        }
        if isPickingWindow {
            hud.fitPicker()
        } else {
            hud.endPicking()
        }
    }

    private func hideHUD() {
        isHUDInBrowser = false
        hud.hide()
    }

    func resetHUDPosition() {
        hud.resetPosition()
    }

    private func toggleList() {
        if scope.isBrowser {
            browser.showsNotes.toggle()
        } else {
            showsList.toggle()
        }
    }

    /// Opens the browser's notes panel with a note selected, such as from its card on the page.
    func showNoteInPanel(_ id: Draft.ID) {
        browser.showsNotes = true
        browser.selectedNote = id
    }

    /// Where the overlay of a session limited to one window goes, in AppKit screen
    /// coordinates: on Tilde's browser, its page only, so the toolbar (with the HUD) and the
    /// notes work as usual.
    private func overlayFrame(for window: ElementPicker.WindowInfo) -> CGRect {
        if window.number == browser.windowNumber, let page = browser.pageFrame {
            return page
        }
        return window.frame.flipped
    }

    /// One overlay per screen above everything, or one on the scoped window just above it.
    /// While choosing a source, every screen has one.
    private func layoutOverlays() {
        let window = isPickingWindow ? nil : scope.window
        let isNew = overlays.layout(on: window.map { ($0.number, overlayFrame(for: $0)) })
        updateOverlayInput()
        if isNew {
            applyPause()
        }
    }

    /// Puts the overlays in step with `overlayTakesInput`; without input, nothing is hovered
    /// and a pick in progress is dropped.
    private func updateOverlayInput() {
        let takesInput = overlayTakesInput
        overlays.setTakesInput(takesInput)
        if !takesInput {
            hoverPicker.stop()
        }
    }

    /// Puts the overlays in step with the pause state; every start, resume and scope change
    /// goes through here. Resuming puts the overlay back above its window, which a click in
    /// that window (such as on the browser's Annotate button) raised over it.
    private func applyPause() {
        if pauses.isEmpty {
            notices.clearPause()
        }
        hoverPicker.logNext()
        log.notice("annotating \(self.pauses.isEmpty ? "on" : "paused", privacy: .public) (\(String(describing: self.pauses), privacy: .public), overlays \(self.overlays.count))")
        hover = nil
        overlays.orderAbove(scope.window?.number)
        makeOverlayKey()
    }

    /// The overlays cover every screen while choosing, and the floating HUD shows the picker.
    private func pickingChanged() {
        guard isOpen, !overlays.isEmpty else {
            return
        }
        layoutOverlays()
        placeHUD()
        makeOverlayKey()
    }

    /// A click on the floating HUD gives Tilde the keyboard, so Esc and ↩ reach it next. The
    /// HUD is a non-activating panel: without this, keys stay with the app in front.
    func takeKeyboard() {
        guard session != nil else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        overlays.makeKey()
    }

    /// Gives keyboard focus (Esc, ⌘↩) to the overlay under the pointer, unless the comment box
    /// or the preview has it or annotating is paused.
    func makeOverlayKey() {
        guard overlayTakesInput, composer == nil, previewID == nil else {
            return
        }
        overlays.makeKey()
    }

    /// Whether a Quartz point is over Tilde's own HUD, comment box or preview.
    /// Whether a Quartz point is over the comment box or the preview, which have text fields.
    func isOverTextPanel(_ point: CGPoint) -> Bool {
        let point = point.flipped
        return [commentPanel.window, previewPanel.window].contains { $0.isVisible && $0.frame.contains(point) }
    }

    func isOverPanel(_ point: CGPoint) -> Bool {
        let point = point.flipped
        let panels = [commentPanel.window, previewPanel.window]
        return hud.contains(point) || panels.contains { $0.isVisible && $0.frame.contains(point) }
    }

    // MARK: - Source and scope

    /// The frontmost app changed: pause or resume, and put the overlay back above its window.
    func frontmostAppChanged(to pid: pid_t?) {
        let waits = SessionScope.autoPauses(frontmost: pid, scopePID: scope.window?.pid, ownPID: ProcessInfo.processInfo.processIdentifier)
        if waits != pauses.contains(.otherApp) {
            log.notice("\(waits ? "auto-paused" : "auto-resumed", privacy: .public) for frontmost pid \(pid ?? 0, privacy: .public)")
            dispatch(waits ? .otherAppInFront : .scopeAppInFront)
        }
        overlays.orderAbove(scope.window?.number)
    }

    /// The choice of what the next clip records, in the picker or by a click on screen.
    func choose(_ source: RecordingSource) {
        dispatch(.choose, with: [.applySource: { [self] in
            scope.choose(source)
        }])
    }

    private func openPicker() {
        sourcePicker.tab = .screens
        sourcePicker.openApp = nil
        hover = nil
        sourcePicker.load(browserWindow: browser.windowNumber)
    }

    /// The session has another source: the front app now counts for the new window, and the
    /// overlays and the HUD go where it is.
    private func sourceChanged() {
        dispatch(.scopeAppInFront)
        hover = nil
        if isOpen, !overlays.isEmpty {
            layoutOverlays()
        }
        placeHUD()
        saver.saveSoon()
    }

    /// The scoped window was checked: what is on it goes along when it moved.
    private func scopeChecked(movedBy delta: CGVector?) {
        guard let window = scope.window else {
            return
        }
        if let delta {
            hover = hover?.moved(by: delta)
        }
        overlays.setFrame(overlayFrame(for: window))
        // The window may have come forward over its overlay, such as on a click in it.
        overlays.orderAbove(window.number)
        if delta != nil {
            tracker.windowMoved()
        }
    }

    /// The scoped window closed: annotations cover everything again.
    private func scopeEnded() {
        // A clip of the window ends with it, at its last frame.
        dispatch(.captureStopped)
        scope.set(nil)
        notices.show(.windowClosed)
    }

    /// Opens `url` (or just the browser) in Tilde's browser and limits the session to its
    /// window.
    private func openBrowser(at url: URL?) {
        browser.show(url)
        // With no page yet, the address field takes the keyboard instead of a blank page.
        if url == nil, !browser.hasPage {
            browser.openLocation(nil)
        }
        scope.limitToBrowser()
    }

    /// The browser accessory bar shows only while annotating outside Tilde's browser, and comes
    /// back there.
    var showsBrowserAccessory: Bool {
        browserOffer.url != nil && !isRecordMode && !isPickingWindow && !isHUDInBrowser
    }

    /// The browser accessory bar's open button: Tilde's browser opens the page and limits the
    /// session to it, as for an agent's start_annotation with a url. The notes stay.
    func openBrowserFromAccessory() {
        guard let url = browserOffer.take() else {
            return
        }
        dispatch(.openBrowser, with: [.openBrowser: { [self] in
            openBrowser(at: url)
        }])
    }

    // MARK: - Recording

    /// What Record records: the chosen source, or the screen with the HUD when there is none.
    var clipSource: RecordingSource {
        scope.source ?? .screen(hudDisplay ?? CGMainDisplayID())
    }

    /// The name of what Record records, such as "Studio Display", for the HUD.
    var clipSourceName: String {
        switch clipSource {
        case .screen(let display): screenName(display)
        case .window(let window): scope.name ?? window.app
        case .phone(let phone): phone.name
        }
    }

    private func startClip() {
        guard case .starting(let operation) = recording, let session else {
            return
        }
        // The clip belongs to the session: it is in its folder, and goes with it.
        clips.start(
            clipSource, windowName: scope.name, into: archive.newClip(in: session.id), browserWindow: browser.windowNumber, operation: operation
        )
    }

    // MARK: - Drawing

    private func showCanvas() {
        hover = nil
        // Over Tilde's browser, the canvas would cover tools on its toolbar.
        if isHUDInBrowser {
            hud.show()
        }
        drawing.start()
    }

    func setDrawingTool(_ tool: String) {
        drawing.setTool(tool)
        if composer != nil {
            commentPanel.focus()
        }
    }

    func setDrawingColor(_ color: String) {
        drawing.setColor(color)
        if composer != nil {
            commentPanel.focus()
        }
    }

    /// Makes a note of what was just drawn. Nothing drawn: nothing happens.
    private func addDrawingNote() async {
        guard let note = await drawing.takeNote() else {
            drawing.panel.endEditing()
            if isDrawing {
                drawing.panel.resumeDrawing()
            }
            return
        }
        openComposer(note)
        drawing.panel.editShapes(note.drawingIDs)
    }

    /// The shape of the open comment changed: its link and the comment box go with it.
    private func updateEditedDrawing() {
        guard case .new(let open) = composer, !open.drawingIDs.isEmpty else {
            return
        }
        let ids = open.drawingIDs
        hover = nil
        Task {
            guard let edit = await drawing.edit(of: ids), case .new(var pending) = composer, pending.drawingIDs == ids, pending.take(edit) else {
                return
            }
            composer = .new(pending)
            commentPanel.follow(near: pending.marker, below: pending.frame)
        }
    }

    /// A note of a drawing can be undone in draw mode, and come back.
    private func undoLastDrawing() {
        let isDrawingNote: (Draft) -> Bool = { draft in
            if case .drawing = draft.annotation.target {
                return true
            }
            return false
        }
        if let index = drafts.lastIndex(where: isDrawingNote) {
            drawing.keepUndone(drafts.remove(at: index))
        }
    }

    private func redoLastDrawing() {
        if let draft = drawing.takeUndone() {
            drafts.append(draft)
        }
    }

    // MARK: - Comments

    /// Opens the comment box for a new target and starts its screenshots.
    func openComposer(_ note: NewNote) {
        // The session may have moved on while the target was picked: then nothing opens.
        var isShown = false
        dispatch(.openComment, with: [.showComment: { [self] in
            isShown = true
            showComposer(note)
        }])
        if !isShown {
            drawing.panel.remove(note.drawingIDs)
        }
    }

    private func showComposer(_ note: NewNote) {
        let pending = Pending(note, browser: browser, withContext: session?.capturesContext ?? false)
        hover = nil
        if let window = note.window, let page = pending.page {
            browserOffer.consider(window, page: page)
        }
        composer = .new(pending)
        log.notice("comment opened for \(note.chip, privacy: .public)")
        commentText = ""
        commentPanel.show(chip: note.chip, isEditing: false, near: note.marker, below: note.frame)
    }

    func edit(_ id: Draft.ID) {
        guard let draft = drafts.first(where: { $0.id == id }) else {
            return
        }
        // The comment being written stays, also when another note is opened.
        if composer != nil {
            dispatch(.clickAway)
            if composer != nil {
                return
            }
        }
        dispatch(.openComment, with: [.showComment: { [self] in
            hover = nil
            composer = .edit(id)
            commentText = draft.annotation.comment
            commentPanel.show(chip: draft.chip, isEditing: true, near: draft.marker, below: draft.annotation.frame)
        }])
    }

    /// Puts the open comment in the list: a new note, or the edited one.
    private func saveComment() {
        guard let composer else {
            return
        }
        let comment = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        log.notice("comment submitted (\(comment.count) characters)")

        switch composer {
        case .edit(let id):
            if let index = drafts.firstIndex(where: { $0.id == id }) {
                drafts[index].annotation.comment = comment
            }

        case .new(let pending):
            let capture = drawing.finish(pending, windowFrame: pending.sourceWindow.flatMap { tracker.windowFrames[$0] })
            let draft = Draft(pending, comment: comment, capture: capture)
            drafts.append(draft)
            tracker.notesAdded()
            if let tracked = pending.tracked {
                tracker.follow(draft.id, element: tracked)
            }
            Task {
                let captures = await capture.value
                guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else {
                    return
                }
                let current = drafts[index].annotation
                drafts[index].annotation = Annotation(
                    id: current.id, comment: current.comment, target: current.target, frame: current.frame,
                    image: captures.image, contextImage: captures.contextImage
                )
            }
        }

        hideComposer()
    }

    func deleteDraft(_ id: Draft.ID) {
        dispatch(.deleteNote, with: [.deleteNote: { [self] in
            if previewID == id {
                showAdjacentPreview(1)
                if previewID == id {
                    dispatch(.closePreview)
                }
            }
            drafts.filter { $0.id == id }.forEach(ClipRecorder.deleteVideo)
            drafts.removeAll { $0.id == id }
            if case .edit(id) = composer {
                dispatch(.closeComment)
            }
        }])
    }

    /// Discards the open comment's data, including a new target's capture.
    private func discardComposer() {
        if case .new(let pending) = composer {
            pending.capture.cancel()
            drawing.panel.remove(pending.drawingIDs)
        }
        log.notice("comment discarded")
        hideComposer()
    }

    private func hideComposer() {
        composer = nil
        commentPanel.close()
        drawing.panel.endEditing()
        if isDrawing {
            drawing.panel.resumeDrawing()
            return
        }
        drawing.panel.hide()
        makeOverlayKey()
    }

    /// Frame and marker of the comment target that is not yet a draft.
    var pendingTarget: Pending? {
        if case .new(let pending) = composer {
            return pending
        }
        return nil
    }

    /// A key in a note's comment field: the note takes the text when typing pauses.
    func updateCommentSoon(_ id: Draft.ID, _ comment: String) {
        guard canEditNotes else {
            return
        }
        typedComments.typed(id, comment)
    }

    private func saveTypedComments() {
        for (id, comment) in typedComments.take() {
            updateComment(id, comment)
        }
    }

    func updateComment(_ id: Draft.ID, _ comment: String) {
        dispatch(.editNote, with: [.editNote: { [self] in
            if let index = drafts.firstIndex(where: { $0.id == id }) {
                drafts[index].annotation.comment = comment
            }
        }])
    }

    // MARK: - Preview

    /// Opens the preview card on a draft. Closes an open comment box first.
    func preview(_ id: Draft.ID) {
        guard drafts.contains(where: { $0.id == id }) else {
            return
        }
        if composer != nil {
            dispatch(.clickAway)
            if composer != nil {
                return
            }
        }
        dispatch(.openPreview, with: [.showPreview: { [self] in
            hover = nil
            previewID = id
            expandedPreviewImage = nil
            previewPanel.show()
        }])
    }

    /// Moves the preview by `step` drafts, wrapping around at either end. An enlarged
    /// screenshot stays enlarged, so ← and → compare the same kind of image.
    func showAdjacentPreview(_ step: Int) {
        guard let id = previewID, let index = drafts.firstIndex(where: { $0.id == id }) else {
            return
        }
        let next = (index + step + drafts.count) % drafts.count
        previewID = drafts[next].id
    }

    private func hidePreview() {
        previewID = nil
        expandedPreviewImage = nil
        previewPanel.close()
        makeOverlayKey()
    }
}

#if DEBUG
extension AnnotationController {
    /// Puts the controller in a given state without opening any window, for snapshot and
    /// behaviour tests. Debug builds only.
    func setStateForTesting(
        session: SessionStore.Session?,
        drafts: [Draft] = [],
        mode: SessionFlow.Mode = .open(SessionFlow.Open()),
        hover: Picked? = nil,
        composer: Composer? = nil,
        previewID: Draft.ID? = nil,
        source: RecordingSource? = nil,
        isHUDInBrowser: Bool = false,
        pauseNotice: PauseNotice? = nil,
        browserAccessoryURL: URL? = nil,
        restoreRecord: SessionRecord? = nil,
        sentText: String = "",
        notice: Notice? = nil,
        clipClock: (since: Date, before: TimeInterval) = (Date(), 0)
    ) {
        self.session = session
        self.drafts = drafts
        // How the user chooses a window is theirs, not the session's.
        let choosesInPicker = flow.choosesInPicker
        flow = SessionFlow(mode: mode)
        flow.choosesInPicker = choosesInPicker
        self.hover = hover
        self.composer = composer
        self.previewID = previewID
        scope.setStateForTesting(source: source)
        self.isHUDInBrowser = isHUDInBrowser
        browserOffer.setStateForTesting(url: browserAccessoryURL)
        self.restoreRecord = restoreRecord
        notices.setStateForTesting(notice: notice, pause: pauseNotice, sentText: sentText)
        clips.clock = clipClock
        isHUDShown = true
    }
}
#endif
