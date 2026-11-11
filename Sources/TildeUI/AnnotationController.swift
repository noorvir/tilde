import TildeCore
import AppKit
import Combine
import os

/// The short notes in the HUD's subtitle, for a moment. Each fits the pill in full, which the
/// subtitle test checks for the whole list.
enum Notice: String, CaseIterable {
    case windowClosed = "Window closed"
    case recordingFailed = "Recording failed"
    case recordingNotSaved = "Recording not saved"
    case recordingStopped = "Recording stopped"
    case reportNotSaved = "Report not saved"
}

@MainActor
final class HoverHighlight: ObservableObject {
    @Published var picked: Picked?
}

/// Runs annotate mode for the active session: hover, pick, comment, send.
/// Owns the overlay, HUD and comment windows; views read its published state.
@MainActor
final class AnnotationController: ObservableObject {
    typealias PauseReason = SessionFlow.PauseReason

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
        if case .picking(_, true) = flow.session?.activity {
            return true
        }
        return false
    }
    /// A question in the pill, waiting for the user.
    var confirmation: SessionFlow.Question? { flow.session?.question }
    var isDrawing: Bool { flow.session?.isDrawing ?? false }
    /// The confirmation after Send, such as "Sent to Codex", while it shows.
    var sentConfirmation: String? {
        if case .sent = mode {
            return sentText
        }
        return nil
    }
    private var sentText = ""
    @Published private(set) var session: SessionStore.Session?
    @Published private(set) var drafts: [Draft] = [] {
        didSet {
            // Send and the questions read the count; it changes with the notes, not later.
            flow.notes = drafts.count
            if let session, drafts.count != oldValue.count {
                store.updateNoteCount(drafts.count, for: session.id)
            }
            browser.anchors = Dictionary(uniqueKeysWithValues: drafts.compactMap { draft in draft.anchor.map { (draft.id, $0) } })
            tracker.notes = drafts
            saver.saveSoon()
        }
    }
    /// The element under the pointer. It changes at pointer rate and only the overlay draws
    /// it, so it is apart from the state that the HUD and the panels redraw on.
    let hoverHighlight = HoverHighlight()
    var hover: Picked? {
        get { hoverHighlight.picked }
        set { hoverHighlight.picked = newValue }
    }
    /// How the confirmation after Send reads: done, or a copy's images that did not reach a
    /// remote machine.
    enum SentStatus {
        case done, failed
    }
    @Published var sentStatus = SentStatus.done
    /// The comment box's data while `flow` has it open.
    @Published private(set) var composer: Composer? {
        didSet {
            tracker.isHeld = composer != nil
            saver.isHeld = composer != nil
        }
    }
    private var holdMonitor: HoldMonitor?

    /// Why annotating just paused, for the note below the HUD.
    enum PauseNotice: Equatable {
        case escape
        case otherApp
    }

    @Published private(set) var pauseNotice: PauseNotice?
    /// The page in another browser that the browser accessory bar under the HUD offers to
    /// open in Tilde's browser, until it is dismissed or opened; nil for no bar.
    @Published private(set) var browserAccessoryURL: URL?
    /// The browser accessory bar shows at most once a session.
    private var hasOfferedBrowser = false
    /// The page the next `.openBrowser` effect opens, from the browser accessory bar.
    private var browserURLToOpen: URL?
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
    ]
    private var pauseNoticeTimer: Timer?
    /// The HUD is in the toolbar of Tilde's browser, as the session is limited to it, and the
    /// floating HUD is hidden. It stays there through the Sent confirmation.
    @Published private(set) var isHUDInBrowser = false
    private var doubleTap: DoubleTapMonitor?
    /// The draft shown in the preview card while `flow` has it open; annotate clicks wait.
    @Published private(set) var previewID: Draft.ID?
    /// The saved session that the restore question offers.
    private(set) var restoreRecord: SessionRecord?
    /// Takes ↩ and Esc for the question from any of Tilde's windows, also from a text field.
    private var confirmationKeyMonitor: Any?
    /// What the session annotates and records: a window (which limits the session to it), a
    /// screen or a phone; nil until the user chooses, which means everything on screen.
    @Published private(set) var source: RecordingSource?
    /// The window annotations are limited to; nil means anything on screen.
    var scope: ElementPicker.WindowInfo? {
        if case .window(let window) = source {
            return window
        }
        return nil
    }
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
    /// A short note in the HUD subtitle, such as that the scoped window closed.
    @Published private(set) var notice: Notice?
    /// Whether the HUD pill is open. HUDPanel animates it, so the pill grows out of its centre
    /// when it appears and collapses into it before the panel hides.
    @Published var isHUDShown = false
    /// The screenshot that fills the preview card's image area, if any.
    @Published var expandedPreviewImage: PreviewImage?
    @Published var showsList = false
    /// Apart from the rest of the state: typing must not redraw the HUD and the overlay.
    let commentDraft = CommentDraft()
    var commentText: String {
        get { commentDraft.text }
        set { commentDraft.text = newValue }
    }

    private let store: SessionStore
    let browser: BrowserController
    let shortcuts: ShortcutStore
    private let picker: ElementPicker
    private var overlays: [OverlayWindow] = []
    /// The window the overlays are on; nil for one per screen.
    private var overlaysWindow: Int?
    private lazy var hud = HUDPanel(controller: self)
    private lazy var commentPanel = CommentPanel(controller: self)
    private lazy var previewPanel = PreviewPanel(controller: self)
    private var subscription: AnyCancellable?

    private var latestHoverPoint: CGPoint?
    /// Whether the last pointer move was over Tilde's own UI; a pick that finishes after the
    /// pointer moved onto the UI must not highlight what is under it.
    private var isPointerOverPanel = false
    /// Picks the element under the latest pointer position, one at a time.
    private var hoverTask: Task<Void, Never>?
    /// The app that was in front when an agent's session opened Tilde's browser. The session
    /// ends with the browser closed and this app in front again, so the user is back in the chat.
    private var returnApp: NSRunningApplication?
    /// The next session that starts from Tilde is limited to the browser window.
    private var scopesNextLocalSessionToBrowser = false
    /// Follows the window that the session is limited to.
    private let scopeFollower = ScopeFollower()
    private var hoverAfterScroll: Task<Void, Never>?
    /// Logs the first highlight after each resume, to measure how soon hover works.
    private var hasLoggedHover = false
    private var hasLoggedMove = false
    /// The icon of the agent app with this display name, for the HUD; nil when unknown.
    var clientIcon: (String) -> NSImage? = { _ in nil }
    /// The status of the remote machine with this name, for the HUD's machine icon.
    var machineDot: (String) -> NodeSetup.Dot = { _ in .grey }
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")

    /// Where sessions are saved while in progress and kept afterwards.
    let archive: SessionArchive
    let saver: SessionSaver
    /// Where sent reports go, and where a report without an agent is copied; tests give their own.
    var inbox = inboxRoot
    var pasteboard = NSPasteboard.general
    /// Keeps how the user last chose a window across launches; nil keeps it only in memory.
    private let defaults: UserDefaults?
    /// A saved session whose notes the next session starts with.
    private var pendingRestore: SessionRecord?

    /// Where each note is on screen now, and whether it shows.
    let tracker: NoteTracker

    init(store: SessionStore, browser: BrowserController, shortcuts: ShortcutStore? = nil, archive: SessionArchive = SessionArchive(), defaults: UserDefaults? = .standard) {
        self.store = store
        self.browser = browser
        self.archive = archive
        saver = SessionSaver(archive: archive)
        self.defaults = defaults
        self.shortcuts = shortcuts ?? ShortcutStore()
        picker = ElementPicker(browser: browser)
        tracker = NoteTracker(windows: picker.windows)
        flow.choosesInPicker = defaults?.bool(forKey: "ChoosesInPicker") ?? false

        subscription = store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncWithStore() }
        browser.controller = self
        saver.snapshot = { [weak self] in self?.snapshot }
        doubleTap = DoubleTapMonitor { [weak self] in
            guard let self else {
                return []
            }
            return self.shortcuts.doubleTapKeys
        } onDoubleTap: { [weak self] key in
            self?.doubleTapped(key)
        }
    }

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

    private func doubleTapped(_ key: DoubleTapKey) {
        guard !shortcuts.isRecording else {
            return
        }
        let action = Self.doubleTapAction(
            for: key, startKey: shortcuts.shortcut(for: .startAnnotation)?.doubleTapKey, pauseKey: shortcuts.shortcut(for: .togglePause)?.doubleTapKey,
            isPaused: pauses.contains(.user), hasSession: session != nil
        )
        switch action {
        case .togglePause, .resume:
            togglePause()
        case .start:
            startLocal()
        case nil:
            break
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
        hasOfferedBrowser = false
        browserAccessoryURL = nil
        drafts = []
        hover = nil
        composer = nil
        previewID = nil
        showsList = false
        setSource(nil)
        PageIdentity.askAppsToDescribeWebContent()
        drawingPanel.prepare()
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
        startHoldMonitor()
        tracker.pageWindow = { [weak self] in
            guard let self, !pageNotes.isEmpty else {
                return nil
            }
            return browser.windowNumber
        }
        // Also when the stack is the same: the browser's page notes can have come or gone.
        picker.windows.onRead = { [weak self] isChanged in
            self?.tracker.refreshCovers()
            // Also for windows that send no move notifications, and for a window that came
            // forward over its overlay.
            self?.refreshScope()
            if isChanged {
                self?.tracker.somethingChanged()
            }
        }
        picker.windows.onInput = { [weak self] in self?.tracker.somethingChanged() }
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
        setSource(nil)
        browserAccessoryURL = nil

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
            hideConfirmation(operation, after: 1.6)
        } else {
            hideHUD()
        }
    }

    /// Hides the HUD after Send's confirmation, unless another one shows by then.
    private func hideConfirmation(_ operation: Int, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.dispatch(.sentShown(operation))
        }
    }

    private func hideHUD() {
        isHUDInBrowser = false
        hud.hide()
    }

    /// Closes everything that annotates: the overlays, the comment, the preview, the hover and
    /// the input monitors. The HUD stays, for the confirmation after Send.
    private func stopAnnotating() {
        clips.discard()
        stopHoldMonitor()
        picker.windows.stop()
        tracker.stop()
        pauseNotice = nil
        pauseNoticeTimer?.invalidate()
        drawingPanel.endSession()
        commentPanel.close()
        previewPanel.close()
        previewID = nil
        for overlay in overlays {
            overlay.parent?.removeChildWindow(overlay)
            overlay.close()
        }
        overlays = []
        hover = nil
        composer = nil
    }

    /// Sends all drafts, including the comment that is still open and a clip in progress.
    func send() {
        dispatch(.send)
    }

    /// Makes the report: waits for the captures, then saves it to the inbox. "Sent" or
    /// "Copied" shows only once that is done; a failure leaves the session as it was.
    private func startSend() {
        guard let session, case .sending(let operation, _) = mode else {
            return
        }
        let drafts = self.drafts
        Task {
            var annotations: [Annotation] = []
            for draft in drafts {
                let captures = await draft.capture.value
                let annotation = draft.annotation
                annotations.append(Annotation(
                    id: annotation.id, comment: annotation.comment, target: annotation.target, frame: annotation.frame,
                    image: captures.image, contextImage: captures.contextImage
                ))
            }

            let feedback = Feedback(annotations: annotations)
            let folder: URL
            do {
                let inbox = self.inbox
                folder = try await Task.detached { try saveToInbox(feedback, sessionID: session.id, node: session.node, root: inbox) }.value
            } catch {
                log.error("could not save feedback to inbox: \(error.localizedDescription, privacy: .public)")
                dispatch(.sendFailed(operation))
                return
            }
            dispatch(.sendFinished(operation), with: [.finishSend: { [self] in
                finishSend(session, feedback: feedback, folder: folder)
            }])
        }
    }

    private func finishSend(_ session: SessionStore.Session, feedback: Feedback, folder: URL) {
        log.notice("session \(session.id, privacy: .public) sent with \(feedback.annotations.count) annotations")
        sentStatus = .done
        if session.isLocal {
            copyReport(feedback, folder: folder)
            sentText = "Copied"
        } else {
            sentText = "Sent to \(session.client)"
        }
        saver.save(state: .sent, reportFolder: folder)
        store.finish(session.id, with: .sent(feedback, folder: folder))
        end()

        // A copy's images go to the remote machines in the background, so that one paste
        // works on any of them; a machine they do not reach gets its own short warning.
        let machines = session.isLocal ? NodeStore().load().map(\.host) : []
        guard !machines.isEmpty else {
            return
        }
        Task {
            let failed = await Self.push(folder, to: machines, log: log)
            guard !failed.isEmpty else {
                return
            }
            dispatch(.pushFailed, with: [.showPushFailure: { [self] in
                sentStatus = .failed
                sentText = RemotePush.failure(failed)
                if case .sent(let operation) = mode {
                    hud.show()
                    hideConfirmation(operation, after: 4)
                }
            }])
        }
    }

    /// Whether the session is limited to Tilde's browser, which then shows the notes panel.
    var isInBrowser: Bool {
        scope != nil && scope?.number == browser.windowNumber
    }

    /// Opens the browser's notes panel with a note selected, such as from its card on the page.
    func showNoteInPanel(_ id: Draft.ID) {
        browser.showsNotes = true
        browser.selectedNote = id
    }

    /// The HUD's list button: the notes panel in the browser, the list elsewhere.
    func showNotes() {
        dispatch(.toggleList)
    }

    private func toggleList() {
        if isInBrowser {
            browser.showsNotes.toggle()
        } else {
            showsList.toggle()
        }
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

    /// Whether the overlay takes the pointer (hover, picks, clicks, the crosshair) and the
    /// keyboard: while annotating, and while choosing a window in any mode.
    var overlayTakesInput: Bool {
        flow.overlayTakesInput
    }

    /// Puts the overlays in step with `overlayTakesInput`; without input, nothing is hovered
    /// and a pick in progress is dropped.
    private func updateOverlayInput() {
        let takesInput = overlayTakesInput
        for overlay in overlays {
            overlay.takesInput = takesInput
        }
        if !takesInput {
            hoverTask?.cancel()
            hoverTask = nil
            latestHoverPoint = nil
            hover = nil
        }
    }

    func togglePause() {
        dispatch(.togglePause)
    }

    /// The HUD's leading button: records, pauses or resumes a clip in recording mode; else
    /// resumes after any pause, or pauses.
    func pressStatusButton() {
        if isRecordMode {
            toggleRecord()
        } else if !pauses.isEmpty {
            resume()
        } else {
            togglePause()
        }
    }

    /// A key for one of the HUD's buttons while Tilde has the keyboard, under the rule that
    /// enables that button. True when the key is one of them, whether it did anything or not.
    func performShortcut(_ event: NSEvent) -> Bool {
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

    /// Annotates again after any pause: one the user chose, or one while another app was in
    /// front.
    func resume() {
        dispatch(.resume)
    }

    /// Asks in the pill before clearing all annotations.
    func requestClearAll() {
        dispatch(.requestClearAll)
    }

    /// Asks in the pill before cancelling, unless there is nothing to lose.
    func requestCancel() {
        dispatch(.requestCancel)
    }

    func confirm() {
        dispatch(.confirm)
    }

    func dismissConfirmation() {
        dispatch(.dismissConfirmation)
    }

    func startDrawing() {
        dispatch(.startDrawing)
    }

    private func showCanvas() {
        hover = nil
        drawingPanel.onEscape = { [weak self] in self?.escapePressed() }
        drawingPanel.onShape = { [weak self] in self?.dispatch(.shapeFinished) }
        drawingPanel.onEdited = { [weak self] in self?.updateEditedDrawing() }
        drawingPanel.onClickAway = { [weak self] in
            self?.dispatch(.clickAway)
            // The click gave the canvas the keyboard; a question in the comment box needs it.
            if self?.composer != nil {
                self?.commentPanel.focus()
            }
        }
        drawingPanel.onPointer = { [weak self] in self?.findSnapFrame(at: $0) }
        drawingPanel.onKey = { [weak self] in self?.performShortcut($0) ?? false }
        drawingPanel.onPress = { [weak self] point in
            guard let self, let id = self.noteLabel(at: point) else {
                return false
            }
            self.preview(id)
            return true
        }
        // Over Tilde's browser, the canvas would cover tools on its toolbar.
        if isHUDInBrowser {
            hud.show()
        }
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
            drawingPanel.startDrawing(on: screen, tool: drawingTool)
        }
    }

    func finishDrawing() {
        dispatch(.finishDrawing)
    }

    func setDrawingTool(_ tool: String) {
        drawingTool = tool
        drawingPanel.setTool(tool)
        if composer != nil {
            commentPanel.focus()
        }
    }

    /// Makes a note of what was just drawn, with the window and the whole screen as they are
    /// with the drawing on them. Nothing drawn: nothing happens.
    private func addDrawingNote() async {
        guard let drawing = await drawingPanel.takeNewShapes(), !drawing.ids.isEmpty else {
            drawingPanel.endEditing()
            if isDrawing {
                drawingPanel.resumeDrawing()
            }
            return
        }
        undoneDrawings = []
        let point = DrawingShapes.linkPoint(of: drawing.shapes)
        let link = await noteLink(at: point, fallback: drawing.bounds)
        let center = CGPoint(x: drawing.bounds.midX, y: drawing.bounds.midY)
        let screen = NSScreen.screens.first { $0.frame.flipped.contains(center) }?.frame.flipped
        let origin = (link.window?.frame ?? screen ?? drawing.bounds).origin
        let captures = await drawingCaptures(of: drawing.bounds, in: link.window?.frame)
        openComposer(NewNote(
            target: .drawing(shapes: DrawingShapes.encode(drawing.shapes, origin: origin, element: link.element)), frame: link.frame,
            marker: link.marker, chip: "Drawing", window: link.window, anchor: link.anchor, tracked: link.tracked,
            pictureArea: link.pictureArea, captures: captures, drawingIDs: drawing.ids
        ))
        drawingPanel.editShapes(drawing.ids)
    }

    /// What a drawing's label is attached to.
    private struct NoteLink {
        let frame: CGRect
        let marker: CGPoint
        let element: Element?
        let window: ElementPicker.WindowInfo?
        let anchor: PageAnchor?
        let tracked: TrackedElement?
        let pictureArea: CGRect?
    }

    /// The smallest element at a point. A window that shows no elements gets a label at the
    /// point, as a click does; `fallback` is then the frame of the note.
    private func noteLink(at point: CGPoint, fallback: CGRect) async -> NoteLink {
        guard let picked = await picker.pick(at: point, in: scope) else {
            let window = scope ?? picker.window(at: point)
            return NoteLink(frame: fallback, marker: point, element: nil, window: window, anchor: nil, tracked: nil, pictureArea: Self.pictureArea(around: point))
        }

        guard Self.isWholeWindow(picked) else {
            let marker = CGPoint(x: picked.frame.maxX, y: picked.frame.minY)
            return NoteLink(frame: picked.frame, marker: marker, element: picked.element, window: picked.window, anchor: picked.anchor, tracked: picked.tracked, pictureArea: nil)
        }

        return NoteLink(frame: fallback, marker: point, element: nil, window: picked.window, anchor: nil, tracked: nil, pictureArea: Self.pictureArea(around: point))
    }

    /// A window that shows no elements, such as the iOS Simulator: a note stays where it was
    /// made, and only what is around that point tells whether it is still on screen. Such an
    /// app may also answer with one large group, as the phone in Device Hub.
    private static func isWholeWindow(_ picked: Picked) -> Bool {
        let isLargeGroup = picked.chip == "Group" && picked.frame.width >= 150 && picked.frame.height >= 150
        // A browser that has not described its page yet answers with the page itself.
        let isAboutTheWindow = picked.window.map { window in
            picked.frame.width * picked.frame.height >= 0.7 * window.frame.width * window.frame.height
        } ?? false
        return picked.chip == "window" || isLargeGroup || isAboutTheWindow
    }

    private static func pictureArea(around point: CGPoint) -> CGRect {
        CGRect(x: point.x - 80, y: point.y - 50, width: 160, height: 100)
    }

    /// The window (or else the screen) and the whole screen, with the drawings on them.
    private func drawingCaptures(of bounds: CGRect, in windowFrame: CGRect?) async -> Captures {
        let keeping = Set(drawingPanel.windowNumbers.map { CGWindowID($0) })
        return await NoteCaptures.ofDrawing(bounds: bounds, in: windowFrame, keeping: keeping)
    }

    /// The shape of the open comment changed: its link and the comment box go with it. Its
    /// picture waits for the end of the edit, without the handles.
    private func updatePendingDrawing(_ ids: [String]) async {
        let shapes = await drawingPanel.shapes(ids)
        hover = nil
        let bounds = DrawingShapes.bounds(of: shapes)
        let link = await noteLink(at: DrawingShapes.linkPoint(of: shapes), fallback: bounds)
        guard !shapes.isEmpty, case .new(var pending) = composer, pending.drawingIDs == ids, case .drawing(let old) = pending.target else {
            return
        }
        pending.target = .drawing(shapes: DrawingShapes.encode(shapes, origin: DrawingShapes.origin(of: old), element: link.element))
        pending.drawingBounds = bounds
        pending.frame = link.frame
        pending.marker = link.marker
        pending.anchor = link.anchor
        pending.tracked = link.tracked
        pending.pictureArea = link.pictureArea
        pending.isDrawingEdited = true
        if let window = pending.sourceWindow {
            let area = link.pictureArea ?? link.frame
            pending.fingerprint = Task { await NoteFingerprint.capture(window: CGWindowID(window), area: area) }
        }
        composer = .new(pending)
        commentPanel.follow(near: pending.marker, below: link.frame)
    }

    func undoDrawing() {
        dispatch(.undoDrawing)
    }

    func redoDrawing() {
        dispatch(.redoDrawing)
    }

    func setDrawingColor(_ color: String) {
        drawingColor = color
        drawingPanel.setColor(color)
        if composer != nil {
            commentPanel.focus()
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
        guard let index = drafts.lastIndex(where: isDrawingNote) else {
            return
        }
        undoneDrawings.append(drafts.remove(at: index))
    }

    private func redoLastDrawing() {
        if let draft = undoneDrawings.popLast() {
            drafts.append(draft)
        }
    }

    private func updateEditedDrawing() {
        if case .new(let pending) = composer, !pending.drawingIDs.isEmpty {
            Task { await updatePendingDrawing(pending.drawingIDs) }
        }
    }

    /// The element under the pointer while drawing. It reuses the hover lookup, which leaves
    /// out apps too slow to ask.
    private func findSnapFrame(at point: CGPoint) {
        let isOverLabel = noteLabel(at: point) != nil
        drawingPanel.setOverLabel(isOverLabel)
        if isOverLabel {
            hover = nil
            drawingPanel.setSnapFrame(nil)
            return
        }

        guard !isFindingSnapFrame, UserDefaults.standard.object(forKey: "drawingSnaps") as? Bool ?? true else {
            return
        }
        isFindingSnapFrame = true
        Task {
            let picked = await picker.pick(at: point, isMoving: true, in: scope)
            isFindingSnapFrame = false
            guard noteLabel(at: point) == nil else {
                return
            }

            // Only the snap ring shows the element: no outline or label, as on hover.
            drawingPanel.setSnapFrame(picked?.chip == "window" ? nil : picked?.frame)
        }
    }

    func escapePressed() {
        // In the picker, Esc first goes from an app's windows back to the apps, as "‹ Back".
        if isSourcePickerOpen, sourcePicker.openApp != nil {
            sourcePicker.openApp = nil
            return
        }
        dispatch(.escape)
    }

    /// The picker's "‹ Back": one level back, as Esc.
    func stepBackInSourcePicker() {
        escapePressed()
    }

    /// The one way the session's mode changes: the flow decides, with the facts it reads kept
    /// current, then its effects run. `with` gives the data of the effects that need it, as
    /// what to do for them, such as showing the comment box that the caller built; one the
    /// flow does not return is dropped.
    func dispatch(_ event: SessionFlow.Event, holdFlag: NSEvent.ModifierFlags = [], with data: [SessionFlow.Effect: () -> Void] = [:]) {
        // A comment typed in the preview is saved first: the event may open a question or a
        // mode in which notes cannot be edited.
        if event != .editNote {
            saveTypedComments()
        }
        var next = flow
        next.notes = drafts.count
        next.commentHasText = !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if case .new(let pending) = composer {
            next.commentIsOnDrawing = !pending.drawingIDs.isEmpty
        } else {
            next.commentIsOnDrawing = false
        }
        let effects = next.handle(event)
        let questionChanged = next.session?.question != flow.session?.question
        if next.choosesInPicker != flow.choosesInPicker {
            defaults?.set(next.choosesInPicker, forKey: "ChoosesInPicker")
        }
        flow = next
        if questionChanged {
            watchConfirmationKeys()
        }
        for effect in effects {
            if let withData = data[effect] {
                withData()
            } else {
                run(effect, holdFlag: holdFlag)
            }
        }
    }

    private func run(_ effect: SessionFlow.Effect, holdFlag: NSEvent.ModifierFlags) {
        switch effect {
        // Their data comes with the event that returns them, if at all.
        case .showComment, .showPreview, .applySource, .finishSend, .adoptClip, .keepClip, .dropClip, .showPushFailure,
             .askRestore, .deleteNote, .editNote:
            break
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
            drawingPanel.endEditing()
            drawingPanel.stopDrawing()
            drawingPanel.setSnapFrame(nil)
            hover = nil
            if composer == nil {
                drawingPanel.hide()
            }
            if isHUDInBrowser {
                hud.hide()
            }
            // The canvas has had the keyboard: Esc and ⌘↩ belong to the overlay again.
            makeOverlayKey()
        case .keepKeyboard:
            // The next Esc must reach Tilde; a click in another app gives that app the keyboard.
            if !isHUDInBrowser {
                let pointer = NSEvent.mouseLocation
                (overlays.first { $0.frame.contains(pointer) } ?? overlays.first)?.makeKey()
            }
        case .giveKeyboardBack:
            // A key overlay would keep the keyboard; give it back to the user's app.
            NSWorkspace.shared.frontmostApplication?.activate()
        case .takeKeyboard: makeOverlayKey()
        case .showEscapeNotice: showPauseNotice(.escape)
        case .showOtherAppNotice: showPauseNotice(.otherApp)
        case .clearNotice: pauseNotice = nil
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
            PlainClickTap.start(removing: holdFlag)
        case .plainClicksOff:
            PlainClickTap.stop()
        case .enterRecording:
            hover = nil
            annotationSource = source
        case .exitRecording:
            clips.discard()
            // What a clip recorded does not limit the notes: back to what annotating had.
            if source != annotationSource {
                setSource(annotationSource)
            }
            frontmostAppChanged(to: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        case .startClip: startClip()
        case .pauseClip: clips.pause()
        case .resumeClip: clips.resume()
        case .finishClip:
            if case .finishing(let operation, _) = recording {
                clips.finish(operation: operation)
            }
        case .showStartFailure: show(notice: .recordingFailed)
        case .showSaveFailure: show(notice: .recordingNotSaved)
        case .showSourceGone: show(notice: .recordingStopped)
        case .startPicking:
            showsList = false
            hover = nil
            pickingChanged()
        case .stopPicking:
            hover = nil
            sourcePicker.stopLoading()
            pickingChanged()
        case .openPicker: openPicker()
        case .openBrowser: openBrowser(at: browserURLToOpen)
        case .closePicker:
            hover = nil
            sourcePicker.stopLoading()
        case .startSend: startSend()
        case .showSendFailure: show(notice: .reportNotSaved)
        }
    }

    /// Copies the report of a session without an agent.
    private func copyReport(_ feedback: Feedback, folder: URL) {
        let text = reportText(for: feedback, folder: folder, linkFolder: homeRelativePath(folder))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Sends a report's folder to each machine; the machines it did not reach.
    private nonisolated static func push(_ folder: URL, to machines: [String], log: Logger) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for machine in machines {
                group.addTask {
                    do {
                        try await RemotePush.push(folder, to: machine)
                        return nil
                    } catch {
                        log.error("could not send feedback to \(machine, privacy: .public): \(String(describing: error), privacy: .public)")
                        return machine
                    }
                }
            }
            return await group.reduce(into: [String]()) { failed, machine in
                if let machine {
                    failed.append(machine)
                }
            }
        }
    }

    /// The start shortcut: starts a session, resumes a paused one, or shows the HUD.
    func startOrResume() {
        dispatch(.startShortcut)
    }

    // MARK: - Holding a key to use the mouse

    private func startHoldMonitor() {
        holdMonitor?.invalidate()
        holdMonitor = nil
        guard let key = shortcuts.holdKey else {
            return
        }
        holdMonitor = HoldMonitor(key: key) { [weak self] output in
            self?.holdChanged(output, key: key)
        }
    }

    private func stopHoldMonitor() {
        holdMonitor?.invalidate()
        holdMonitor = nil
        PlainClickTap.stop()
        dispatch(.holdEnded)
    }

    private func holdChanged(_ output: HoldGesture.Output, key: DoubleTapKey) {
        switch output {
        case .began:
            dispatch(.holdBegan, holdFlag: key.flag)
            // With the browser in front, its page takes the first click only when it is key.
            if pauses.contains(.hold), NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), browser.window?.isVisible == true {
                browser.window?.makeKey()
            }
        case .ended:
            dispatch(.holdEnded)
        }
    }

    // MARK: - Whether a note's content is on screen

    let drawingPanel = DrawingPanel()
    @Published private(set) var drawingTool = "arrow"
    @Published private(set) var drawingColor = "#2F76FF"
    private var undoneDrawings: [Draft] = []
    private var isFindingSnapFrame = false
    private var typedComments: [Draft.ID: String] = [:]
    private var typedCommentsTask: Task<Void, Never>?

    // MARK: - Labels of notes

    /// The note whose numbered label is at this point.
    func noteLabel(at point: CGPoint) -> Draft.ID? {
        let labels = drafts.filter { $0.anchor == nil }.compactMap { draft in tracker.marker(of: draft).map { (draft.id, $0) } }
            + anchoredNotes.map { ($0.draft.id, $0.marker) }
        return labels.last { Self.isOnLabel(distance: hypot($0.1.x - point.x, $0.1.y - point.y)) }?.0
    }

    /// A label's circle has a radius of 10 points; 8 more around it make it easy to hit.
    nonisolated static func isOnLabel(distance: CGFloat) -> Bool {
        distance <= 18
    }

    /// ⌘[ or ⌘] while the overlay has the keyboard: in Tilde's browser, or else in the app in
    /// front, as if the overlay were not there.
    func navigateHistory(_ event: NSEvent) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let front, front != getpid() {
            event.cgEvent?.postToPid(front)
        } else if event.keyCode == 33 {
            browser.goBack(nil)
        } else {
            browser.goForward(nil)
        }
    }

    // MARK: - Saving and restoring

    /// The session on screen as it is now, for its saved record.
    private var snapshot: SessionSaver.Snapshot? {
        guard let session else {
            return nil
        }
        return SessionSaver.Snapshot(session: session, drafts: drafts, pageURL: isInBrowser ? browser.pageURL : nil, scopeApp: scopeName)
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

    // MARK: - Overlays and pause

    /// A note on the open page of Tilde's browser, where it is on screen now.
    struct PageNote {
        let number: Int
        let draft: Draft
        /// Quartz screen frame of its element or region.
        let frame: CGRect

        var marker: CGPoint {
            CGPoint(x: frame.maxX, y: frame.minY)
        }
    }

    /// Notes on the browser's open page, for the overlay to draw like other notes while the
    /// notes panel is hidden; with the panel open, the browser draws them with their cards.
    var pageNotes: [PageNote] {
        browser.showsNotes ? [] : anchoredNotes
    }

    /// Notes attached to the page in Tilde's browser, where they are now.
    private var anchoredNotes: [PageNote] {
        guard let page = browser.pageFrame?.flipped else {
            return []
        }
        return drafts.enumerated().compactMap { index, draft in
            // No height: scrolled out of its panel.
            guard let rect = browser.anchorRects[draft.id], rect.height > 0 else {
                return nil
            }
            return PageNote(number: index + 1, draft: draft, frame: rect.offsetBy(dx: page.minX, dy: page.minY))
        }
    }

    /// The HUD goes in the browser's toolbar while the session is limited to the browser, and
    /// floats over the screen otherwise.
    private func placeHUD() {
        guard session != nil, isOpen else {
            return
        }
        // In Tilde's browser the HUD stays in its toolbar, and the floating panel shows only
        // the picker, under the toolbar, while choosing.
        isHUDInBrowser = isInBrowser
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

    /// Where the overlay of a session limited to one window goes, in AppKit screen
    /// coordinates: on Tilde's browser, its page only, so the toolbar (with the HUD) and the
    /// notes work as usual.
    private func overlayFrame(for scope: ElementPicker.WindowInfo) -> CGRect {
        if scope.number == browser.windowNumber, let page = browser.pageFrame {
            return page
        }
        return scope.frame.flipped
    }

    /// One overlay per screen above everything, or one on the scoped window just above it,
    /// unless the overlays are already that. While choosing a source, every screen has one.
    /// Overlay panels are non-activating: the user's app stays frontmost while annotating.
    private func layoutOverlays() {
        let scope = isPickingWindow ? nil : scope
        if !overlays.isEmpty, overlaysWindow == scope?.number {
            updateOverlayInput()
            return
        }
        for overlay in overlays {
            overlay.parent?.removeChildWindow(overlay)
            overlay.close()
        }
        overlaysWindow = scope?.number
        if let scope {
            // The same level as the window, such as a floating one of Tilde's, so ordering above
            // it works; other apps' windows are normal ones.
            let level = NSApp.window(withWindowNumber: scope.number)?.level ?? .normal
            overlays = [OverlayWindow(frame: overlayFrame(for: scope), level: level, isWindowSized: true, controller: self)]
            orderAboveScope()
        } else {
            overlays = NSScreen.screens.map { OverlayWindow(screen: $0, controller: self) }
            for overlay in overlays {
                overlay.orderFrontRegardless()
            }
        }
        updateOverlayInput()
        applyPause()
    }

    /// Keeps the scoped window's overlay directly above it, so other windows in front of it
    /// also cover the overlay.
    /// Tilde's own windows take it as a child window, which AppKit moves with them and keeps
    /// above them.
    private func orderAboveScope() {
        guard let scope, let overlay = overlays.first, overlay.isWindowSized else {
            return
        }
        if let own = NSApp.window(withWindowNumber: scope.number) {
            if overlay.parent !== own {
                own.addChildWindow(overlay, ordered: .above)
            }
            return
        }
        overlay.order(.above, relativeTo: scope.number)
    }

    /// Puts the overlays in step with the pause state; every start, resume and scope change
    /// goes through here. Resuming puts the overlay back above its window, which a click in
    /// that window (such as on the browser's Annotate button) raised over it.
    /// Shows one pause note at a time, for 10 seconds, when turned on with the hidden
    /// setting `hudPauseToast` (the HUD's yellow pause button shows the pause instead).
    private func showPauseNotice(_ notice: PauseNotice) {
        guard UserDefaults.standard.bool(forKey: "hudPauseToast") else {
            return
        }
        pauseNotice = notice
        restartPauseNoticeTimer()
    }

    /// The pointer on the note keeps it; leaving it gives it 10 seconds again.
    func holdPauseNotice(_ isHeld: Bool) {
        pauseNoticeTimer?.invalidate()
        if !isHeld, pauseNotice != nil {
            restartPauseNoticeTimer()
        }
    }

    private func restartPauseNoticeTimer() {
        pauseNoticeTimer?.invalidate()
        pauseNoticeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pauseNotice = nil
            }
        }
    }

    private func applyPause() {
        if pauses.isEmpty {
            pauseNotice = nil
        }
        hasLoggedHover = false
        hasLoggedMove = false
        log.notice("annotating \(self.pauses.isEmpty ? "on" : "paused", privacy: .public) (\(String(describing: self.pauses), privacy: .public), overlays \(self.overlays.count))")
        hover = nil
        orderAboveScope()
        makeOverlayKey()
    }

    /// Whether a session limited to one window waits while another app is in front.
    nonisolated static func autoPauses(frontmost: pid_t?, scopePID: pid_t?, ownPID: pid_t) -> Bool {
        guard let scopePID, let frontmost else {
            return false
        }
        return frontmost != scopePID && frontmost != ownPID
    }

    /// The frontmost app changed: pause or resume, and put the overlay back above its window.
    func frontmostAppChanged(to pid: pid_t?) {
        let waits = Self.autoPauses(frontmost: pid, scopePID: scope?.pid, ownPID: ProcessInfo.processInfo.processIdentifier)
        if waits != pauses.contains(.otherApp) {
            log.notice("\(waits ? "auto-paused" : "auto-resumed", privacy: .public) for frontmost pid \(pid ?? 0, privacy: .public)")
            dispatch(waits ? .otherAppInFront : .scopeAppInFront)
        }
        orderAboveScope()
    }

    // MARK: - Recording

    /// The HUD's record toggle: into recording mode, or back to annotating, which asks first
    /// when a clip is not stopped (Stop adds it to the list).
    func toggleRecordingMode() {
        dispatch(.toggleRecordingMode)
    }

    /// The leading button in recording mode: starts a clip, pauses it, resumes it.
    func toggleRecord() {
        dispatch(.record)
    }

    /// Ends the clip in progress and adds it to the list.
    func stopRecording() {
        dispatch(.stop)
    }

    /// What Record records: the chosen source, or the screen with the HUD when there is none.
    var clipSource: RecordingSource {
        source ?? .screen(hudDisplay ?? CGMainDisplayID())
    }

    /// The name of what Record records, such as "Studio Display", for the HUD.
    var clipSourceName: String {
        switch clipSource {
        case .screen(let display): screenName(display)
        case .window(let window): scopeName ?? window.app
        case .phone(let phone): phone.name
        }
    }

    /// A screen's name as the system gives it; pictures of the HUD give a stand-in, so that
    /// they never show the name of the Mac that drew them.
    var screenName: (CGDirectDisplayID) -> String = SourcePickerModel.name(of:)

    /// The display the floating HUD is on, which its panel keeps up to date as it is placed
    /// and dragged.
    @Published var hudDisplay: CGDirectDisplayID?

    private func startClip() {
        guard case .starting(let operation) = recording, let session else {
            return
        }
        let recordingSource = clipSource
        let name: String
        let frame: CGRect
        switch recordingSource {
        case .window(let window):
            name = "\(scopeName ?? window.app) window"
            frame = window.frame
        case .screen(let display):
            name = SourcePickerModel.name(of: display)
            frame = NSScreen.screens.first { Self.displayID(of: $0) == display }?.frame.flipped ?? .zero
        case .phone(let phone):
            name = phone.name
            frame = .zero
        }

        // The clip belongs to the session: it is in its folder, and goes with it.
        clips.start(
            recordingSource, name: name, frame: frame, into: archive.newClip(in: session.id), browserWindow: browser.windowNumber, operation: operation
        )
    }

    // MARK: - Window scope

    /// Whether annotate mode takes a Quartz point: anywhere, or only inside the scoped window.
    nonisolated static func allows(_ point: CGPoint, scope: CGRect?) -> Bool {
        scope?.contains(point) ?? true
    }

    /// The part of a dragged region inside the scoped window, or nil when none is left.
    nonisolated static func clamped(_ rect: CGRect, scope: CGRect?) -> CGRect? {
        guard let scope else {
            return rect
        }
        let inside = rect.intersection(scope)
        return inside.isNull || inside.width < 8 || inside.height < 8 ? nil : inside
    }

    /// While choosing a source, a session limited to a window also takes the other windows.
    func allows(_ point: CGPoint) -> Bool {
        Self.allows(point, scope: isPickingWindow ? nil : scope?.frame)
    }

    /// The name the HUD shows for the scoped window: its app's name.
    var scopeName: String? {
        guard let scope else {
            return nil
        }
        if scope.pid == ProcessInfo.processInfo.processIdentifier {
            return "Tilde Browser"
        }
        return NSRunningApplication(processIdentifier: scope.pid)?.localizedName ?? scope.app
    }

    /// The scoped window's app icon, for the HUD.
    var scopeIcon: NSImage? {
        guard let scope else {
            return nil
        }
        if scope.pid == ProcessInfo.processInfo.processIdentifier {
            return NSApp.applicationIconImage
        }
        return NSRunningApplication(processIdentifier: scope.pid)?.icon
    }

    /// The HUD's window button: starts choosing a source on screen, or stops choosing with no
    /// change.
    func toggleWindowPick() {
        dispatch(.windowButton)
    }

    /// Esc while choosing: closes the open picker, then stops choosing.
    func cancelWindowPick() {
        dispatch(.escape)
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

    /// Opens the source picker in full while choosing, on its screens.
    func openSourcePicker() {
        dispatch(.openPicker)
    }

    private func openPicker() {
        sourcePicker.tab = .screens
        sourcePicker.openApp = nil
        hover = nil
        sourcePicker.load(browserWindow: browser.windowNumber)
    }

    /// The choice: a window limits the session to it, as clicking it on screen does; a screen
    /// or phone lifts the limit. A phone only records.
    func choose(_ source: RecordingSource) {
        dispatch(.choose(drawable: source.isDrawable), with: [.applySource: { [self] in
            browserScopeRequest += 1
            if case .window(let window) = source {
                setSource(.window(picker.currentWindow(number: window.number) ?? window))
            } else {
                setSource(source)
            }
        }])
    }

    static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Limits annotations to `window`, or lifts the limit with nil.
    func setScope(_ window: ElementPicker.WindowInfo?) {
        setSource(window.map(RecordingSource.window))
    }

    /// Annotates and records `source` from now on: a window limits the session to it, a screen
    /// or a phone lifts the limit; nil is everything on screen.
    private func setSource(_ source: RecordingSource?) {
        let window: ElementPicker.WindowInfo?
        if case .window(let chosen) = source {
            window = chosen
        } else {
            window = nil
        }
        if window != scope {
            log.notice("scope \(window.map { "window \($0.number) of \($0.app)" } ?? "none", privacy: .public)")
        }
        self.source = source
        // The front app now counts for the new window.
        dispatch(.scopeAppInFront)
        hover = nil
        scopeFollower.stop()
        if isOpen, !overlays.isEmpty {
            layoutOverlays()
        }
        placeHUD()
        saver.saveSoon()
        guard let window else {
            return
        }
        scopeFollower.onCheck = { [weak self] frame in self?.refreshScope(frame: frame) }
        scopeFollower.onAppQuit = { [weak self] in
            if self?.scope?.pid == window.pid {
                self?.endScope()
            }
        }
        scopeFollower.onFrontApp = { [weak self] pid in self?.frontmostAppChanged(to: pid) }
        scopeFollower.start(window, page: window.number == browser.windowNumber ? browser.webView : nil)
        frontmostAppChanged(to: Self.frontmostPID)
    }

    /// The frontmost app. Right after Tilde activates, NSWorkspace can still name the app
    /// before it, so Tilde's own state wins.
    private static var frontmostPID: pid_t? {
        if NSApp.isActive {
            return ProcessInfo.processInfo.processIdentifier
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Takes the window's new frame, or ends the scope with a note when the window is gone,
    /// hidden or minimised.
    /// `frame`: the window's frame as the window itself reported it, which can be ahead of the
    /// window list.
    func refreshScope(frame: CGRect? = nil) {
        guard let scope else {
            return
        }
        guard var current = picker.currentWindow(number: scope.number) else {
            endScope()
            return
        }
        if let frame {
            current = ElementPicker.WindowInfo(number: current.number, pid: current.pid, app: current.app, title: current.title, frame: frame)
        }
        if current.frame != scope.frame {
            source = .window(current)
            // The highlighted element moved with its window.
            let delta = CGVector(dx: current.frame.minX - scope.frame.minX, dy: current.frame.minY - scope.frame.minY)
            hover = hover?.moved(by: delta)
        }
        let frame = overlayFrame(for: current)
        if let overlay = overlays.first, overlay.isWindowSized, overlay.frame != frame {
            overlay.setFrame(frame, display: true)
        }
        // The window may have come forward over its overlay, such as on a click in it.
        orderAboveScope()
        if current.frame != scope.frame {
            tracker.windowMoved()
        }
    }

    /// Opens `url` (or just the browser) in Tilde's browser and limits the session to its
    /// window.
    private func openBrowser(at url: URL?) {
        browser.show(url)
        // With no page yet, the address field takes the keyboard instead of a blank page.
        if url == nil, !browser.hasPage {
            browser.openLocation(nil)
        }
        scopeToBrowser()
    }

    /// The first click on an element in another browser in a session offers to open its page
    /// in Tilde's browser, when the address the note reads for its page is a web address.
    private func offerBrowser(window: ElementPicker.WindowInfo, page: Task<PageIdentity?, Never>) {
        guard !hasOfferedBrowser,
              let bundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier,
              Self.browserBundleIDs.contains(bundleID)
        else {
            return
        }
        let sessionID = session?.id
        Task {
            guard let url = await page.value?.url.flatMap(URL.init(string:)), url.scheme == "http" || url.scheme == "https",
                  session?.id == sessionID, !hasOfferedBrowser
            else {
                return
            }
            hasOfferedBrowser = true
            browserAccessoryURL = url
        }
    }

    /// The browser accessory bar shows only while annotating outside Tilde's browser, and comes
    /// back there.
    var showsBrowserAccessory: Bool {
        browserAccessoryURL != nil && !isRecordMode && !isPickingWindow && !isHUDInBrowser
    }

    /// The browser accessory bar's ×.
    func dismissBrowserAccessory() {
        browserAccessoryURL = nil
    }

    /// The browser accessory bar's open button: Tilde's browser opens the page and limits the session to it, as for
    /// an agent's start_annotation with a url. The notes stay.
    func openBrowserFromAccessory() {
        guard let url = browserAccessoryURL else {
            return
        }
        browserAccessoryURL = nil
        browserURLToOpen = url
        dispatch(.openBrowser)
        browserURLToOpen = nil
    }

    /// The browser window can take a moment to reach the window list after it opens. The
    /// scope is applied to the session that asked, only while its source can change (no clip
    /// in progress, not choosing) and no other source was chosen meanwhile.
    private func scopeToBrowser() {
        guard let sessionID = session?.id else {
            return
        }
        browserScopeRequest += 1
        let request = browserScopeRequest
        let delays = [0.0, 0.3, 0.8]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.browserScopeRequest == request, self.session?.id == sessionID, self.flow.canPick, !self.isPickingWindow else {
                    return
                }
                if let number = self.browser.windowNumber, let window = self.picker.currentWindow(number: number) {
                    self.browserScopeRequest += 1
                    if self.scope?.number != number {
                        self.setScope(window)
                    }
                } else if delay == delays.last {
                    // The window never came on screen: the session covers everything.
                    self.placeHUD()
                }
            }
        }
    }

    /// What annotating was limited to (nothing, or Tilde's browser) before recording mode,
    /// which it gets back after.
    private var annotationSource: RecordingSource?

    /// Counts requests to limit the session to the browser; a choice of another source or a
    /// newer request makes an older one stale.
    private var browserScopeRequest = 0

    /// The scoped window closed: annotations cover everything again.
    private func endScope() {
        // A clip of the window ends with it, at its last frame.
        dispatch(.captureStopped)
        setScope(nil)
        show(notice: .windowClosed)
    }

    private func show(notice: Notice) {
        self.notice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.notice == notice {
                self?.notice = nil
            }
        }
    }

    // MARK: - Picking

    func mouseMoved(to point: CGPoint) {
        guard composer == nil, previewID == nil else {
            return
        }
        if !hasLoggedMove {
            hasLoggedMove = true
            log.notice("first pointer move on the overlay")
        }
        isPointerOverPanel = isOverPanel(point)
        if isPointerOverPanel || !allows(point) || noteLabel(at: point) != nil {
            latestHoverPoint = nil
            hover = nil
            return
        }
        if isPickingWindow {
            hover = isSourcePickerOpen ? nil : picker.windowTarget(at: point)
            return
        }

        latestHoverPoint = point
        guard hoverTask == nil else {
            return
        }

        hoverTask = Task {
            while let next = latestHoverPoint {
                latestHoverPoint = nil
                let picked = await picker.pick(at: next, isMoving: true, in: scope)
                // The overlay stopped taking input meanwhile.
                if Task.isCancelled {
                    return
                }
                if picked != nil, !hasLoggedHover {
                    hasLoggedHover = true
                    log.notice("first highlight \(picked?.chip ?? "", privacy: .public)")
                }
                if composer == nil && !isPointerOverPanel && !isPickingWindow {
                    hover = picked
                }
            }
            hoverTask = nil
        }
    }

    /// Picks again under the pointer after the page moved under it, such as on scroll, so the
    /// hover highlight stays on the element.
    func refreshHover() {
        guard hover != nil else {
            return
        }
        mouseMoved(to: NSEvent.mouseLocation.flipped)
    }

    /// Scrolling always goes to the window under the pointer, as if Tilde were not there; the
    /// hover highlight then follows the page. Tilde's browser reports its own scrolling.
    func scroll(_ event: NSEvent, at point: CGPoint) {
        guard let window = picker.window(at: point) else {
            return
        }
        ScrollForwarder.forward(event, at: point, to: window)
        if window.number != browser.windowNumber {
            tracker.scrolled()
            hoverAfterScroll?.cancel()
            hoverAfterScroll = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                if !Task.isCancelled {
                    self?.refreshHover()
                }
            }
        }
    }

    func mouseExited() {
        latestHoverPoint = nil
        hover = nil
    }

    func click(at point: CGPoint) {
        if previewID != nil {
            closePreview()
            return
        }
        if isPickingWindow {
            guard !isSourcePickerOpen else {
                return
            }
            // A window, or outside windows the screen.
            if let window = picker.window(at: point) {
                choose(.window(window))
            } else if let display = Self.displayID(of: NSScreen.screens.first { $0.frame.contains(point.flipped) }) {
                choose(.screen(display))
            }
            return
        }
        guard allows(point) else {
            return
        }
        if composer != nil {
            dispatch(.clickAway)
            return
        }

        Task {
            var picked = hover
            if picked?.frame.contains(point) != true {
                picked = await picker.pick(at: point, in: scope)
            }
            guard let picked else {
                return
            }
            let isWholeWindow = Self.isWholeWindow(picked)
            let marker = isWholeWindow ? point : CGPoint(x: picked.frame.maxX, y: picked.frame.minY)
            openComposer(NewNote(
                target: .element(picked.element), frame: picked.frame, marker: marker, chip: picked.chip, outline: picked.frame,
                window: picked.window, anchor: picked.anchor, tracked: isWholeWindow ? nil : picked.tracked,
                pictureArea: isWholeWindow ? Self.pictureArea(around: point) : nil
            ))
        }
    }

    func dragEnded(with rect: CGRect) {
        if previewID != nil {
            closePreview()
            return
        }
        // While choosing, only a click chooses.
        if isPickingWindow {
            return
        }
        guard let rect = Self.clamped(rect, scope: scope?.frame) else {
            return
        }
        if composer != nil {
            dispatch(.clickAway)
            return
        }
        let marker = CGPoint(x: rect.maxX, y: rect.minY)
        let window = scope ?? picker.window(at: CGPoint(x: rect.midX, y: rect.midY))
        let isOverBrowser = window?.number == browser.windowNumber
        Task {
            let anchor = isOverBrowser ? await browser.regionAnchor(for: rect) : nil
            openComposer(NewNote(target: .region, frame: rect, marker: marker, chip: "Region", window: window, anchor: anchor))
        }
    }

    /// Opens the comment box for a new target and starts its screenshots.
    private func openComposer(_ note: NewNote) {
        // The session may have moved on while the target was picked: then nothing opens.
        var isShown = false
        dispatch(.openComment, with: [.showComment: { [self] in
            isShown = true
            showComposer(note)
        }])
        if !isShown {
            drawingPanel.remove(note.drawingIDs)
        }
    }

    private func showComposer(_ note: NewNote) {
        let pending = Pending(note, browser: browser, withContext: session?.capturesContext ?? false)
        hover = nil
        if let window = note.window, let page = pending.page {
            offerBrowser(window: window, page: page)
        }
        composer = .new(pending)
        log.notice("comment opened for \(note.chip, privacy: .public)")
        commentText = ""
        commentPanel.show(chip: note.chip, isEditing: false, near: note.marker, below: note.frame)
    }

    // MARK: - Comments

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

    /// The comment box's Return, and ⌘↩ there, which sends the whole report.
    func submitComment(thenSend: Bool) {
        if thenSend {
            send()
        } else {
            dispatch(.submitComment)
        }
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
            let annotation = Annotation(comment: comment, target: pending.target, frame: pending.frame, image: nil, contextImage: nil)
            var capture = pending.capture
            if pending.isDrawingEdited {
                let windowFrame = pending.sourceWindow.flatMap { tracker.windowFrames[$0] }
                let bounds = pending.drawingBounds ?? pending.frame
                capture = Task {
                    // The canvas has to paint without the handles first.
                    try? await Task.sleep(for: .milliseconds(100))
                    let captures = await drawingCaptures(of: bounds, in: windowFrame)
                    drawingPanel.remove(pending.drawingIDs)
                    return captures
                }
            } else {
                drawingPanel.remove(pending.drawingIDs)
            }
            drafts.append(Draft(
                annotation: annotation, marker: pending.marker, chip: pending.chip, capture: capture, anchor: pending.anchor,
                sourceWindow: pending.sourceWindow, fingerprint: pending.fingerprint, page: pending.page, sourcePID: pending.sourcePID, pictureArea: pending.pictureArea
            ))
            tracker.notesAdded()
            if let tracked = pending.tracked {
                tracker.follow(annotation.id, element: tracked)
            }
            Task {
                let captures = await capture.value
                guard let index = drafts.firstIndex(where: { $0.id == annotation.id }) else {
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

    /// Notes change only when the flow takes it: not under a question, while choosing or while
    /// the report is made.
    var canEditNotes: Bool {
        flow.accepts(.editNote)
    }

    func deleteDraft(_ id: Draft.ID) {
        dispatch(.deleteNote, with: [.deleteNote: { [self] in
            if previewID == id {
                showAdjacentPreview(1)
                if previewID == id {
                    closePreview()
                }
            }
            drafts.filter { $0.id == id }.forEach(ClipRecorder.deleteVideo)
            drafts.removeAll { $0.id == id }
            if case .edit(id) = composer {
                closeComposer()
            }
        }])
    }

    /// Discards the open comment.
    func closeComposer() {
        dispatch(.closeComment)
    }

    /// Discards the open comment's data, including a new target's capture.
    private func discardComposer() {
        if case .new(let pending) = composer {
            pending.capture.cancel()
            drawingPanel.remove(pending.drawingIDs)
        }
        log.notice("comment discarded")
        hideComposer()
    }

    private func hideComposer() {
        composer = nil
        commentPanel.close()
        drawingPanel.endEditing()
        if isDrawing {
            drawingPanel.resumeDrawing()
            return
        }
        drawingPanel.hide()
        makeOverlayKey()
    }

    /// Gives keyboard focus (Esc, ⌘↩) to the overlay under the pointer, unless the comment box
    /// has it or annotating is paused.
    /// ↩ confirms and Esc dismisses the question in the HUD, whichever of Tilde's windows has
    /// the keyboard: the overlay, the floating HUD, or the browser with a text field focused.
    /// Keys typed in other apps never reach it.
    private func watchConfirmationKeys() {
        if confirmation == nil {
            if let confirmationKeyMonitor {
                NSEvent.removeMonitor(confirmationKeyMonitor)
            }
            confirmationKeyMonitor = nil
            return
        }
        guard confirmationKeyMonitor == nil else {
            return
        }
        confirmationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isAnswer = MainActor.assumeIsolated {
                self?.handleConfirmationKey(keyCode, modifiers: modifiers, in: event.window) == true
            }
            return isAnswer ? nil : event
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
        switch keyCode {
        case 53:
            dismissConfirmation()
            return true
        case 36, 76:
            confirm()
            return true
        default:
            return false
        }
    }

    /// A click on the floating HUD gives Tilde the keyboard, so Esc and ↩ reach it next. The
    /// HUD is a non-activating panel: without this, keys stay with the app in front.
    func takeKeyboard() {
        guard session != nil else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(pointer) } ?? overlays.first)?.makeKey()
    }

    func makeOverlayKey() {
        guard overlayTakesInput, composer == nil, previewID == nil else {
            return
        }
        let pointer = NSEvent.mouseLocation
        let overlay = overlays.first { $0.frame.contains(pointer) } ?? overlays.first
        overlay?.makeKey()
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

    func resetHUDPosition() {
        hud.resetPosition()
    }

    func closePreview() {
        dispatch(.closePreview)
    }

    private func hidePreview() {
        previewID = nil
        expandedPreviewImage = nil
        previewPanel.close()
        makeOverlayKey()
    }

    /// Keeps what was typed and saves it after a short pause: every change to the drafts redraws
    /// the HUD and the overlay, which must not happen on each key.
    func updateCommentSoon(_ id: Draft.ID, _ comment: String) {
        guard canEditNotes else {
            return
        }
        typedComments[id] = comment
        typedCommentsTask?.cancel()
        typedCommentsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled {
                self?.saveTypedComments()
            }
        }
    }

    private func saveTypedComments() {
        typedCommentsTask?.cancel()
        let typed = typedComments
        typedComments = [:]
        for (id, comment) in typed {
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

    /// Frame and marker of the comment target that is not yet a draft.
    var pendingTarget: Pending? {
        if case .new(let pending) = composer {
            return pending
        }
        return nil
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
        flow = SessionFlow(mode: mode, notes: drafts.count)
        flow.choosesInPicker = choosesInPicker
        self.hover = hover
        self.composer = composer
        self.previewID = previewID
        self.source = source
        self.isHUDInBrowser = isHUDInBrowser
        self.pauseNotice = pauseNotice
        self.browserAccessoryURL = browserAccessoryURL
        self.restoreRecord = restoreRecord
        self.sentText = sentText
        self.notice = notice
        clips.clock = clipClock
        isHUDShown = true
    }
}
#endif
