import TildeCore
import AppKit
import Combine
import os

/// An annotation the user has added but not yet sent. `annotation.image` fills in when
/// `capture` finishes; sending waits for every capture.
struct Draft: Identifiable {
    var annotation: Annotation
    /// Quartz point where the numbered marker sits.
    let marker: CGPoint
    let chip: String
    let capture: Task<Captures, Never>
    /// Where the annotation is on its web page, for annotations in Tilde's browser.
    var anchor: PageAnchor?
    /// The window it is on, so windows in front of that window cover it.
    var sourceWindow: Int?
    /// What its area looked like when it was made, to hide it when that content goes.
    var fingerprint: Task<NoteFingerprint?, Never>?
    /// The page it was made on.
    var page: Task<PageIdentity?, Never>?
    /// The app of its window.
    var sourcePID: pid_t?

    var id: UUID { annotation.id }
}

/// HUD actions that discard every annotation, so the pill asks before doing them.
enum Confirmation: Equatable {
    case clearAll
    case cancelSession
    /// Replace the notes on screen with a saved session's.
    case restore(SessionRecord)
}

enum PreviewImage {
    case closeUp
    case context
}

/// Screenshots taken when a target is picked, before the user finishes the comment.
struct Captures: Sendable {
    let image: Data?
    let contextImage: Data?
}

/// The comment box that is open: for a new target, or to edit an existing draft.
enum Composer {
    case new(Pending)
    case edit(Draft.ID)
}

struct Pending {
    let target: Target
    let frame: CGRect
    let marker: CGPoint
    let chip: String
    let capture: Task<Captures, Never>
    var anchor: PageAnchor?
    var tracked: TrackedElement?
    var sourceWindow: Int?
    var fingerprint: Task<NoteFingerprint?, Never>?
    var page: Task<PageIdentity?, Never>?
    var sourcePID: pid_t?
}

/// Runs annotate mode for the active session: hover, pick, comment, send.
/// Owns the overlay, HUD and comment windows; views read its published state.
@MainActor
final class AnnotationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case annotating
        /// Shown in the HUD for a moment after Send, such as "Sent to Codex".
        case sent(confirmation: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var session: SessionStore.Session?
    @Published private(set) var drafts: [Draft] = [] {
        didSet {
            if let session, drafts.count != oldValue.count {
                store.updateNoteCount(drafts.count, for: session.id)
            }
            browser.anchors = Dictionary(uniqueKeysWithValues: drafts.compactMap { draft in draft.anchor.map { (draft.id, $0) } })
            scheduleSave()
        }
    }
    @Published private(set) var hover: Picked?
    @Published private(set) var composer: Composer?
    @Published private(set) var isPaused = false
    /// Paused because another app is in front of a session limited to one window; ends when
    /// the window's app (or Tilde) comes back to the front.
    @Published private(set) var isAutoPaused = false
    /// Paused while the hold key is down, so the mouse and keyboard work as usual.
    @Published private(set) var isHoldPaused = false
    private var holdMonitor: HoldMonitor?

    /// Why annotating just paused, for the note below the HUD.
    enum PauseNotice: Equatable {
        case escape
        case otherApp
    }

    @Published private(set) var pauseNotice: PauseNotice?
    private var pauseNoticeTimer: Timer?
    /// The HUD is in the toolbar of Tilde's browser, as the session is limited to it, and the
    /// floating HUD is hidden. It stays there through the Sent confirmation.
    @Published private(set) var isHUDInBrowser = false
    private var doubleTap: DoubleTapMonitor?
    /// The draft shown in the preview card; annotate clicks wait while it is open.
    @Published private(set) var previewID: Draft.ID?
    /// A destructive HUD action waiting for the user to confirm it in the pill.
    @Published private(set) var confirmation: Confirmation? {
        didSet { watchConfirmationKeys() }
    }
    /// Takes ↩ and Esc for the question from any of Tilde's windows, also from a text field.
    private var confirmationKeyMonitor: Any?
    /// The window annotations are limited to; nil means anything on screen.
    @Published private(set) var scope: ElementPicker.WindowInfo?
    /// Waiting for a click on the window to limit annotations to.
    @Published private(set) var isPickingWindow = false
    /// A short note in the HUD subtitle, such as that the scoped window closed.
    @Published private(set) var notice: String?
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
    private lazy var hud = HUDPanel(controller: self)
    private lazy var commentPanel = CommentPanel(controller: self)
    private lazy var previewPanel = PreviewPanel(controller: self)
    private var subscription: AnyCancellable?

    private var latestHoverPoint: CGPoint?
    /// Whether the last pointer move was over Tilde's own UI; a pick that finishes after the
    /// pointer moved onto the UI must not highlight what is under it.
    private var isPointerOverPanel = false
    private var isHoverRunning = false
    private var isSending = false
    /// The app that was in front when an agent's session opened Tilde's browser. The session
    /// ends with the browser closed and this app in front again, so the user is back in the chat.
    private var returnApp: NSRunningApplication?
    /// The next session that starts from Tilde is limited to the browser window.
    private var scopesNextLocalSessionToBrowser = false
    /// Ends the scope when the scoped window's app quits.
    private var terminationObserver: NSObjectProtocol?
    /// A slow check of the scoped window, for windows that send no move notifications.
    private var scopeTimer: Timer?
    /// Follows the scoped window as it moves, resizes or closes.
    private var windowObserver: WindowObserver?
    /// Checks the scoped window at display rate for a moment after it moved.
    private var followTimer: Timer?
    private var followsUntil = Date.distantPast
    private var activationObserver: NSObjectProtocol?
    private var pageObserver: NSObjectProtocol?
    private var hoverAfterScroll: Task<Void, Never>?
    /// Logs the first highlight after each resume, to measure how soon hover works.
    private var hasLoggedHover = false
    private var hasLoggedMove = false
    /// The icon of the agent app with this display name, for the HUD; nil when unknown.
    var clientIcon: (String) -> NSImage? = { _ in nil }
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")

    /// Where sessions are saved while in progress and kept afterwards.
    let archive: SessionArchive
    /// When the session on screen started, for its saved record.
    private var sessionStarted = Date()
    private var saveTask: Task<Void, Never>?
    private var checkpointTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    /// A saved session whose notes the next session starts with.
    private var pendingRestore: SessionRecord?

    /// Notes on elements in other apps, and where those elements are now; a note missing from
    /// `trackedFrames` but in `hiddenNotes` scrolled out of view or lost its element.
    private var trackedElements: [Draft.ID: TrackedElement] = [:]
    @Published private(set) var trackedFrames: [Draft.ID: CGRect] = [:]
    @Published private(set) var hiddenNotes: Set<Draft.ID> = []
    private var trackingTimer: Timer?
    private var isTracking = false
    private let trackingQueue = DispatchQueue(label: "tilde.tracking")

    init(store: SessionStore, browser: BrowserController, shortcuts: ShortcutStore? = nil, archive: SessionArchive = SessionArchive()) {
        self.store = store
        self.browser = browser
        self.archive = archive
        self.shortcuts = shortcuts ?? ShortcutStore()
        picker = ElementPicker(browser: browser)

        subscription = store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncWithStore() }
        browser.controller = self
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
    /// session, or resumes a paused one, and does nothing while annotating. The pause key
    /// pauses or resumes. One key may do both.
    nonisolated static func doubleTapAction(
        for key: DoubleTapKey, startKey: DoubleTapKey?, pauseKey: DoubleTapKey?, isAnnotating: Bool, isPaused: Bool, hasSession: Bool
    ) -> DoubleTapAction? {
        if key == startKey {
            if !hasSession {
                return .start
            }
            if isAnnotating, isPaused {
                return .resume
            }
        }
        if key == pauseKey, isAnnotating {
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
            isAnnotating: phase == .annotating, isPaused: isPaused, hasSession: session != nil
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
        } else if phase == .annotating {
            end()
        }
    }

    private func begin(_ session: SessionStore.Session) {
        self.session = session
        drafts = []
        hover = nil
        composer = nil
        isPaused = false
        isSending = false
        showsList = false
        confirmation = nil
        setScope(nil)
        phase = .annotating
        PageIdentity.askAppsToDescribeWebContent()
        log.notice("session \(session.id, privacy: .public) started for \(session.client, privacy: .public)")

        sessionStarted = Date()
        if let record = pendingRestore {
            pendingRestore = nil
            if record.id == session.id {
                sessionStarted = record.created
            }
            drafts = Self.drafts(from: record, archive: archive)
        }
        startCheckpoints()
        startHoldMonitor()
        saveSession()

        if session.url != nil, !session.isLocal, let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
            returnApp = frontmost
        }
        // A session in the browser starts paused, so the user can type an address and browse
        // first; Annotate in the HUD (or the pause shortcut) starts annotating.
        let isInBrowser = session.url != nil || (session.isLocal && scopesNextLocalSessionToBrowser)
        scopesNextLocalSessionToBrowser = false

        rebuildOverlays()
        if isInBrowser {
            togglePause()
            // The HUD shows once the browser's window is on screen, in its toolbar.
            openBrowser(at: session.url)
        } else {
            placeHUD()
        }
    }

    private func end() {
        stopCheckpoints()
        stopHoldMonitor()
        stopOcclusion()
        stopContentChecks()
        pauseNotice = nil
        pauseNoticeTimer?.invalidate()
        stopTracking()
        confirmation = nil
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
        session = nil
        drafts = []
        setScope(nil)

        if let returnApp {
            self.returnApp = nil
            browser.close()
            // The browser's HUD goes with it, so the confirmation shows in the floating one.
            if isHUDInBrowser {
                isHUDInBrowser = false
                if case .sent = phase {
                    hud.show()
                }
            }
            NSApp.yieldActivation(to: returnApp)
            ElementPicker.bringToFront(returnApp)
        }

        if case .sent = phase {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, case .sent = self.phase else {
                    return
                }
                self.phase = .idle
                self.isHUDInBrowser = false
                self.hud.hide()
            }
        } else {
            phase = .idle
            isHUDInBrowser = false
            hud.hide()
        }
    }

    /// Sends all drafts, including the comment that is still open.
    func send() {
        if composer != nil {
            submitComment(thenSend: true)
            return
        }
        guard let session, phase == .annotating, !drafts.isEmpty, !isSending else {
            return
        }

        isSending = true
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

            let feedback = Feedback(annotations: Self.groupedByPage(annotations))
            var folder: URL?
            do {
                folder = try saveToInbox(feedback, sessionID: session.id)
            } catch {
                log.error("could not save feedback to inbox: \(error.localizedDescription, privacy: .public)")
            }

            log.notice("session \(session.id, privacy: .public) sent with \(annotations.count) annotations")
            if session.isLocal {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reportText(for: feedback, folder: folder), forType: .string)
                phase = .sent(confirmation: "Copied to clipboard")
            } else {
                phase = .sent(confirmation: "Sent to \(session.client)")
            }
            saveSession(state: .sent, reportFolder: folder)
            store.finish(session.id, with: .sent(feedback, folder: folder))
            end()
        }
    }

    /// Annotations on the same web page next to each other, pages in the order they were
    /// first annotated; others keep their place. The report numbers follow this order.
    nonisolated static func groupedByPage(_ annotations: [Annotation]) -> [Annotation] {
        var pages: [String] = []
        for annotation in annotations {
            if case .element(.web(let element)) = annotation.target, !pages.contains(element.url) {
                pages.append(element.url)
            }
        }
        return annotations.enumerated().sorted { first, second in
            let page = { (annotation: Annotation) -> Int in
                if case .element(.web(let element)) = annotation.target {
                    return pages.firstIndex(of: element.url) ?? 0
                }
                return Int.max
            }
            let firstPage = page(first.element), secondPage = page(second.element)
            return firstPage == secondPage ? first.offset < second.offset : firstPage < secondPage
        }.map(\.element)
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
        if isInBrowser {
            browser.showsNotes.toggle()
            return
        }
        showsList.toggle()
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
            openBrowser(at: nil)
            return
        }
        scopesNextLocalSessionToBrowser = true
        _ = store.start(client: "You", url: nil, isLocal: true)
    }

    func cancel() {
        guard let session else {
            return
        }
        log.notice("session \(session.id, privacy: .public) cancelled")
        saveSession(state: .cancelled)
        store.finish(session.id, with: .cancelled)
        end()
    }

    var isEffectivelyPaused: Bool {
        isPaused || isAutoPaused || isHoldPaused
    }

    func togglePause() {
        guard phase == .annotating else {
            return
        }
        isPaused.toggle()
        // Annotate pressed on purpose resumes, whatever app was last in front.
        if !isPaused {
            isAutoPaused = false
        }
        applyPause()
        if isPaused {
            // A key overlay would keep the keyboard; give it back to the user's app.
            NSWorkspace.shared.frontmostApplication?.activate()
        }
        makeOverlayKey()
    }

    /// Annotates again after any pause: one the user chose, or one while another app was in
    /// front.
    func resume() {
        if isPaused {
            togglePause()
            return
        }
        guard isAutoPaused else {
            return
        }
        isAutoPaused = false
        applyPause()
    }

    func clearDrafts() {
        drafts = []
        commentPanel.close()
        composer = nil
    }

    /// Asks in the pill before clearing all annotations.
    func requestClearAll() {
        guard !drafts.isEmpty else {
            return
        }
        confirmation = .clearAll
    }

    /// Asks in the pill before cancelling, unless there is nothing to lose.
    func requestCancel() {
        pauseNotice = nil
        guard !drafts.isEmpty else {
            cancel()
            return
        }
        confirmation = .cancelSession
    }

    func confirm() {
        guard let confirmation else {
            return
        }
        self.confirmation = nil
        switch confirmation {
        case .clearAll:
            clearDrafts()
        case .cancelSession:
            cancel()
        case .restore(let record):
            replaceDrafts(with: record)
        }
    }

    func dismissConfirmation() {
        confirmation = nil
    }

    /// Esc while Tilde has the keyboard: closes the comment box or preview, ends choosing a
    /// window, dismisses a question; else pauses, and when paused asks to discard the session.
    func escapePressed() {
        if composer != nil {
            closeComposer()
            return
        }
        if previewID != nil {
            closePreview()
            return
        }
        if isPickingWindow {
            cancelWindowPick()
            return
        }
        if confirmation != nil {
            dismissConfirmation()
            return
        }
        if phase == .annotating, !isPaused {
            pauseKeepingKeyboard()
            return
        }
        requestCancel()
    }

    /// Pauses, but Tilde keeps the keyboard, so the next Esc reaches it; a click in another
    /// app gives that app the keyboard.
    private func pauseKeepingKeyboard() {
        isPaused = true
        applyPause()
        showPauseNotice(.escape)
        if !isHUDInBrowser {
            let pointer = NSEvent.mouseLocation
            (overlays.first { $0.frame.contains(pointer) } ?? overlays.first)?.makeKey()
        }
    }

    /// The start shortcut: starts a session, resumes a paused one, or shows the HUD.
    func startOrResume() {
        guard session != nil else {
            startLocal()
            return
        }
        if isPaused {
            togglePause()
            return
        }
        if isHUDInBrowser {
            browser.show()
        } else {
            hud.show()
        }
    }

    // MARK: - Windows in front of notes

    /// For each window with notes, the frames of the windows in front of it; a window not on
    /// screen (closed, minimised, on another Space) is in `hiddenWindows`, and its notes hide.
    @Published private(set) var windowCovers: [Int: [CGRect]] = [:]
    @Published private(set) var hiddenWindows: Set<Int> = []
    /// How far back each window with notes is: 0 for the front window.
    private(set) var windowDepth: [Int: Int] = [:]
    private var occlusionTimer: Timer?

    struct StackWindow: Equatable {
        let number: Int
        let frame: CGRect
    }

    /// The windows in front of each of `windows` in a front-to-back `stack`, and the ones
    /// missing from it.
    nonisolated static func covers(of windows: Set<Int>, in stack: [StackWindow]) -> (covers: [Int: [CGRect]], missing: Set<Int>) {
        var covers: [Int: [CGRect]] = [:]
        var missing: Set<Int> = []
        for window in windows {
            guard let index = stack.firstIndex(where: { $0.number == window }) else {
                missing.insert(window)
                continue
            }
            let frame = stack[index].frame
            covers[window] = stack[..<index].map(\.frame).filter { $0.intersects(frame) }
        }
        return (covers, missing)
    }

    /// Checks four times a second, and when another app comes to the front, which windows
    /// cover the windows that have notes.
    private func startOcclusion() {
        refreshOcclusion()
        guard occlusionTimer == nil else {
            return
        }
        occlusionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshOcclusion()
            }
        }
    }

    private func stopOcclusion() {
        occlusionTimer?.invalidate()
        occlusionTimer = nil
        windowCovers = [:]
        hiddenWindows = []
        windowDepth = [:]
    }

    func refreshOcclusion() {
        var windows = Set(drafts.compactMap(\.sourceWindow))
        if !pageNotes.isEmpty, let number = browser.windowNumber {
            windows.insert(number)
        }
        guard !windows.isEmpty else {
            return
        }
        guard !isReadingWindows else {
            return
        }
        isReadingWindows = true
        let browserWindow = browser.windowNumber
        let screenFrames = NSScreen.screens.map(\.frame.flipped)
        let overlayLevel = OverlayWindow.overlayLevel.rawValue
        trackingQueue.async { [weak self] in
            let stack = ElementPicker.windowStack(browserWindow: browserWindow, screenFrames: screenFrames, overlayLevel: overlayLevel)
                .map { StackWindow(number: $0.number, frame: $0.frame) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyOcclusion(stack, windows: windows)
                }
            }
        }
    }

    private func applyOcclusion(_ stack: [StackWindow], windows: Set<Int>) {
        isReadingWindows = false
        windowFrames = Dictionary(stack.map { ($0.number, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let result = Self.covers(of: windows, in: stack)
        windowDepth = Dictionary(uniqueKeysWithValues: stack.enumerated().filter { windows.contains($0.element.number) }.map { ($0.element.number, $0.offset) })
        if result.covers != windowCovers {
            windowCovers = result.covers
        }
        if result.missing != hiddenWindows {
            hiddenWindows = result.missing
        }
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
        isHoldPaused = false
    }

    private func holdChanged(_ output: HoldGesture.Output, key: DoubleTapKey) {
        guard phase == .annotating else {
            return
        }
        switch output {
        case .began:
            // Not while typing a comment, where these keys are for the text.
            guard composer == nil, previewID == nil, !isPaused else {
                return
            }
            isHoldPaused = true
            PlainClickTap.start(removing: key.flag)
            applyPause()
            // With the browser in front, its page takes the first click only when it is key.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), browser.window?.isVisible == true {
                browser.window?.makeKey()
            }
        case .ended:
            guard isHoldPaused else {
                return
            }
            isHoldPaused = false
            PlainClickTap.stop()
            applyPause()
        }
    }

    // MARK: - Whether a note's content is on screen

    /// Notes whose content is gone from their window, such as after a page change. They stay
    /// in the session, the list and the report; only their marks hide.
    @Published private(set) var contentGoneNotes: Set<Draft.ID> = []
    private var visibilities: [Draft.ID: NoteVisibility] = [:]
    private var contentTimer: Timer?
    private var isCheckingContent = false
    private var isReadingWindows = false
    /// Where the windows are, from the last time the window list was read.
    private var windowFrames: [Int: CGRect] = [:]

    private struct ContentCheck: Sendable {
        let id: Draft.ID
        let window: Int
        let windowFrame: CGRect?
        let pid: pid_t?
        let frame: CGRect
        let fingerprint: Task<NoteFingerprint?, Never>
        let page: Task<PageIdentity?, Never>?
    }

    /// How much a note's content is on screen: the page's identity decides when it can, and
    /// the picture of the note's area otherwise. Nil when neither can be read.
    nonisolated private static func similarity(of check: ContentCheck, page now: PageIdentity?) async -> Double? {
        if let original = await check.page?.value, let isSame = now?.isSamePage(as: original) {
            return isSame ? 1 : 0
        }
        guard let original = await check.fingerprint.value,
              let now = await NoteFingerprint.capture(window: CGWindowID(check.window), area: check.frame, windowFrame: check.windowFrame)
        else {
            return nil
        }
        return now.similarity(to: original)
    }

    /// Checks twice a second whether each note's content is on screen.
    private func startContentChecks() {
        guard contentTimer == nil else {
            return
        }
        contentTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkContent()
            }
        }
    }

    private func stopContentChecks() {
        contentTimer?.invalidate()
        contentTimer = nil
        visibilities = [:]
        contentGoneNotes = []
    }

    private func checkContent() {
        guard !isCheckingContent, phase == .annotating else {
            return
        }
        let checks = drafts.compactMap { draft -> ContentCheck? in
            guard let window = draft.sourceWindow, let fingerprint = draft.fingerprint, !hiddenWindows.contains(window) else {
                return nil
            }
            return ContentCheck(
                id: draft.id, window: window, windowFrame: windowFrames[window], pid: draft.sourcePID,
                frame: trackedFrames[draft.id] ?? draft.annotation.frame, fingerprint: fingerprint, page: draft.page
            )
        }
        guard !checks.isEmpty else {
            return
        }
        isCheckingContent = true
        Task { [weak self] in
            var similarities: [Draft.ID: Double] = [:]
            // One read per window, however many notes it has.
            var pages: [Int: PageIdentity] = [:]
            for check in checks {
                if pages[check.window] == nil, let pid = check.pid, let frame = check.windowFrame {
                    pages[check.window] = await Task.detached { PageIdentity.read(pid: pid, windowFrame: frame) }.value
                }
                similarities[check.id] = await Self.similarity(of: check, page: pages[check.window])
            }
            self?.applyContentChecks(similarities)
        }
    }

    private func applyContentChecks(_ similarities: [Draft.ID: Double]) {
        isCheckingContent = false
        var gone = contentGoneNotes
        for (id, similarity) in similarities {
            var visibility = visibilities[id] ?? NoteVisibility()
            if visibility.update(similarity: similarity) {
                // Back on its page: its element may be a new one, or in a tab that left.
                if gone.remove(id) != nil {
                    elementsToFindAgain.insert(id)
                }
            } else {
                gone.insert(id)
            }
            visibilities[id] = visibility
            // To tune the thresholds from a real session.
            log.notice("note content similarity \(similarity, format: .fixed(precision: 3)), shows \(visibility.isVisible)")
        }
        if gone != contentGoneNotes {
            contentGoneNotes = gone
        }
    }

    // MARK: - Following elements in other apps

    /// Where a note's element is on screen now, or nil while it is out of view or gone.
    func noteFrame(_ draft: Draft) -> CGRect? {
        if hiddenNotes.contains(draft.id) || contentGoneNotes.contains(draft.id) {
            return nil
        }
        return trackedFrames[draft.id] ?? draft.annotation.frame
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

    /// Where a note's numbered marker is now, at its element's top-right corner.
    func noteMarker(_ draft: Draft) -> CGPoint? {
        guard trackedElements[draft.id] != nil else {
            return draft.marker
        }
        return noteFrame(draft).map { CGPoint(x: $0.maxX, y: $0.minY) }
    }

    /// Reads tracked elements five times a second, besides after scrolls and window moves.
    private func startTracking() {
        guard trackingTimer == nil else {
            return
        }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTracking()
            }
        }
        refreshTracking()
    }

    private var elementsToFindAgain: Set<Draft.ID> = []

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        trackedElements = [:]
        trackedFrames = [:]
        hiddenNotes = []
    }

    /// Reads where each tracked element is, off the main thread, and moves its note there.
    func refreshTracking() {
        let ids = Set(drafts.map(\.id))
        trackedElements = trackedElements.filter { ids.contains($0.key) }
        guard !isTracking, !trackedElements.isEmpty else {
            return
        }
        isTracking = true
        // A note off its page stays with its page: another page's look-alike is not its element.
        let work = trackedElements.filter { !contentGoneNotes.contains($0.key) }.map { id, tracked in
            let original = drafts.first { $0.id == id }?.annotation.frame ?? .zero
            let findsAgain = elementsToFindAgain.contains(id)
            return (id, tracked, findsAgain ? original : trackedFrames[id] ?? original, findsAgain)
        }
        elementsToFindAgain = []
        trackingQueue.async { [weak self] in
            let results = work.map { id, tracked, last, findsAgain in (id, ElementTracker.locate(tracked, lastFrame: last, findsAgain: findsAgain)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyTracking(results)
                }
            }
        }
    }

    private func applyTracking(_ results: [(Draft.ID, (frame: CGRect?, tracked: TrackedElement, isGone: Bool))]) {
        isTracking = false
        var frames = trackedFrames
        var hidden = hiddenNotes
        for (id, result) in results where trackedElements[id] != nil {
            trackedElements[id] = result.tracked
            if let frame = result.frame {
                frames[id] = frame
                hidden.remove(id)
            } else if result.isGone, drafts.first(where: { $0.id == id })?.fingerprint != nil {
                // Apps such as the Simulator rebuild elements on every page. The picture of
                // the note's area decides, so the note comes back with its page.
                hidden.remove(id)
            } else {
                hidden.insert(id)
            }
        }
        if frames != trackedFrames {
            trackedFrames = frames
        }
        if hidden != hiddenNotes {
            hiddenNotes = hidden
        }
    }

    // MARK: - Saving and restoring

    /// Saves the session about a second after a change, so a burst of changes is one write.
    private func scheduleSave() {
        guard session != nil else {
            return
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled {
                self?.saveSession()
            }
        }
    }

    /// Saves every 10 seconds while a session is on screen, and before the Mac sleeps.
    private func startCheckpoints() {
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveSession()
            }
        }
        if sleepObserver == nil {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveSession()
                }
            }
        }
    }

    private func stopCheckpoints() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        saveTask?.cancel()
        saveTask = nil
    }

    /// Saves the session on screen with its notes; images follow once their captures are done.
    private func saveSession(state: SessionRecord.State = .active, reportFolder: URL? = nil) {
        guard let record = currentRecord(state: state, reportFolder: reportFolder) else {
            return
        }
        archive.save(record)
        let drafts = self.drafts
        let archive = self.archive
        Task {
            var images: [String: Data] = [:]
            for draft in drafts {
                let captures = await draft.capture.value
                images[SessionArchive.imageName(draft.id)] = captures.image
                images[SessionArchive.contextImageName(draft.id)] = captures.contextImage
            }
            if !images.isEmpty {
                archive.saveImages(images, of: record.id)
            }
        }
    }

    /// Saves what is on screen at once, without images still being captured, such as when
    /// Tilde quits.
    func saveBeforeQuitting() {
        if let record = currentRecord(state: .active, reportFolder: nil) {
            archive.save(record)
        }
        archive.flush()
    }

    private func currentRecord(state: SessionRecord.State, reportFolder: URL?) -> SessionRecord? {
        guard let session else {
            return nil
        }
        let notes = drafts.map { draft in
            SessionRecord.Note(
                id: draft.id, comment: draft.annotation.comment, target: draft.annotation.target, frame: draft.annotation.frame,
                marker: draft.marker, chip: draft.chip, anchor: draft.anchor
            )
        }
        return SessionRecord(
            id: session.id, created: sessionStarted, updated: Date(), client: session.client, isLocal: session.isLocal, state: state,
            pageURL: isInBrowser ? browser.pageURL : nil, scopeApp: scopeName, notes: notes, reportFolder: reportFolder?.path
        )
    }

    /// Notes of a saved session as drafts, with their saved images.
    static func drafts(from record: SessionRecord, archive: SessionArchive) -> [Draft] {
        record.notes.map { note in
            let images = archive.images(of: note, in: record.id)
            let captures = Captures(image: images.image, contextImage: images.contextImage)
            // The preview and the list show the annotation's own images.
            let annotation = Annotation(
                id: note.id, comment: note.comment, target: note.target, frame: note.frame, image: images.image, contextImage: images.contextImage
            )
            return Draft(annotation: annotation, marker: note.marker, chip: note.chip, capture: Task { captures }, anchor: note.anchor)
        }
    }

    /// Brings back a saved session's notes, also a sent one, to edit and send again: into the
    /// session on screen, or a new session from Tilde (in the browser at its page, for a
    /// browser session). An unfinished or cancelled one is marked restored, so it is not
    /// offered again; a sent one stays sent.
    func restore(_ record: SessionRecord) {

        if session != nil {
            // Notes on screen are replaced only after the HUD asks.
            if drafts.isEmpty {
                replaceDrafts(with: record)
            } else {
                confirmation = .restore(record)
                placeHUD()
            }
            return
        }
        markRestored(record)
        pendingRestore = record
        _ = store.start(client: "You", url: record.pageURL.flatMap(URL.init(string:)), isLocal: true)
    }

    private func markRestored(_ record: SessionRecord) {
        guard record.state != .sent else {
            return
        }
        var old = record
        old.state = .restored
        old.updated = Date()
        archive.save(old)
    }

    /// The session on screen takes a saved session's notes, in their order, and its page in
    /// Tilde's browser.
    private func replaceDrafts(with record: SessionRecord) {
        markRestored(record)
        closeComposer()
        drafts = Self.drafts(from: record, archive: archive)
        if let page = record.pageURL.flatMap(URL.init(string:)), browser.pageURL != record.pageURL {
            openBrowser(at: page)
        }
    }

    /// Starts an agent's unfinished session again under its own id, with its notes, when the
    /// agent waits for it after Tilde restarted. Returns whether it did.
    func reattach(_ id: String) -> Bool {
        guard let record = archive.record(id), record.state == .active, !record.isLocal else {
            return false
        }
        pendingRestore = record
        _ = store.start(id: record.id, client: record.client, url: record.pageURL.flatMap(URL.init(string:)))
        return true
    }

    /// Keeps an unfinished session in the history as cancelled.
    func discard(_ record: SessionRecord) {
        var old = record
        old.state = .cancelled
        old.updated = Date()
        archive.save(old)
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
        guard !browser.showsNotes, let page = browser.pageFrame?.flipped else {
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
        guard session != nil, phase == .annotating else {
            return
        }
        isHUDInBrowser = isInBrowser
        if isHUDInBrowser {
            hud.hide()
        } else if !isHUDShown {
            hud.show()
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

    /// One overlay per screen above everything, or one on the scoped window just above it.
    /// Overlay panels are non-activating: the user's app stays frontmost while annotating.
    private func rebuildOverlays() {
        for overlay in overlays {
            overlay.parent?.removeChildWindow(overlay)
            overlay.close()
        }
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
        if !isEffectivelyPaused {
            pauseNotice = nil
        }
        hasLoggedHover = false
        hasLoggedMove = false
        log.notice("annotating \(self.isEffectivelyPaused ? "paused" : "on", privacy: .public) (paused \(self.isPaused), auto \(self.isAutoPaused), overlays \(self.overlays.count))")
        hover = nil
        for overlay in overlays {
            overlay.ignoresMouseEvents = isEffectivelyPaused
        }
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
        let pauses = Self.autoPauses(frontmost: pid, scopePID: scope?.pid, ownPID: ProcessInfo.processInfo.processIdentifier)
        if pauses != isAutoPaused {
            log.notice("\(pauses ? "auto-paused" : "auto-resumed", privacy: .public) for frontmost pid \(pid ?? 0)")
            isAutoPaused = pauses
            applyPause()
            if pauses {
                showPauseNotice(.otherApp)
            }
        }
        orderAboveScope()
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

    func allows(_ point: CGPoint) -> Bool {
        Self.allows(point, scope: scope?.frame)
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

    /// The HUD's window button: clears the scope, or starts or stops choosing a window.
    func toggleWindowScope() {
        if scope != nil {
            setScope(nil)
            return
        }
        isPickingWindow.toggle()
        hover = nil
        makeOverlayKey()
    }

    func cancelWindowPick() {
        isPickingWindow = false
        hover = nil
    }

    /// Limits annotations to `window`, or lifts the limit with nil.
    func setScope(_ window: ElementPicker.WindowInfo?) {
        if window != scope {
            log.notice("scope \(window.map { "window \($0.number) of \($0.app)" } ?? "none", privacy: .public)")
        }
        let changesWindow = window?.number != scope?.number
        scope = window
        isPickingWindow = false
        isAutoPaused = false
        hover = nil
        scopeTimer?.invalidate()
        scopeTimer = nil
        windowObserver?.invalidate()
        windowObserver = nil
        followTimer?.invalidate()
        followTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
        pageObserver = nil
        if changesWindow, phase == .annotating, !overlays.isEmpty {
            rebuildOverlays()
        }
        placeHUD()
        scheduleSave()
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        guard let window else {
            return
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let self, app?.processIdentifier == window.pid, self.scope?.pid == window.pid {
                    self.endScope()
                }
            }
        }
        windowObserver = WindowObserver(window: window) { [weak self] frame in
            self?.windowMoved(to: frame)
        }
        // The browser's page also moves in its window, such as when the notes panel opens.
        if window.number == browser.windowNumber {
            browser.webView.postsFrameChangedNotifications = true
            pageObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: browser.webView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshScope()
                }
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontmostAppChanged(to: app?.processIdentifier)
            }
        }
        scopeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshScope()
            }
        }
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

    /// The window moved or resized: follow it at once, then at display rate for 300 ms, as
    /// move notifications can come in bursts and end before the last frame.
    private func windowMoved(to frame: CGRect?) {
        refreshScope(frame: frame)
        followsUntil = Date().addingTimeInterval(0.3)
        guard followTimer == nil else {
            return
        }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, Date() < self.followsUntil else {
                    timer.invalidate()
                    self?.followTimer = nil
                    return
                }
                self.refreshScope()
            }
        }
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
            self.scope = current
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
            refreshTracking()
        }
    }

    /// Opens `url` (or just the browser) in Tilde's browser and limits the session to its
    /// window.
    private func openBrowser(at url: URL?) {
        browser.show(url)
        // With no page yet, the address field takes the keyboard instead of a blank page.
        if url == nil, browser.webView.url == nil {
            browser.openLocation(nil)
        }
        scopeToBrowser()
    }

    /// The browser window can take a moment to reach the window list after it opens.
    private func scopeToBrowser() {
        let delays = [0.0, 0.3, 0.8]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.phase == .annotating, self.scope == nil else {
                    return
                }
                if let number = self.browser.windowNumber, let window = self.picker.currentWindow(number: number) {
                    self.setScope(window)
                } else if delay == delays.last {
                    // The window never came on screen: the session covers everything.
                    self.placeHUD()
                }
            }
        }
    }

    /// The scoped window closed: annotations cover everything again.
    private func endScope() {
        setScope(nil)
        show(notice: "Window closed")
    }

    private func show(notice text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.notice == text {
                self?.notice = nil
            }
        }
    }

    // MARK: - Picking

    func mouseMoved(to point: CGPoint) {
        guard composer == nil, previewID == nil, !isEffectivelyPaused else {
            return
        }
        if !hasLoggedMove {
            hasLoggedMove = true
            log.notice("first pointer move on the overlay")
        }
        isPointerOverPanel = isOverPanel(point)
        if isPointerOverPanel || !allows(point) {
            latestHoverPoint = nil
            hover = nil
            return
        }
        if isPickingWindow {
            hover = picker.windowTarget(at: point)
            return
        }

        latestHoverPoint = point
        guard !isHoverRunning else {
            return
        }

        isHoverRunning = true
        Task {
            while let next = latestHoverPoint {
                latestHoverPoint = nil
                let picked = await picker.pick(at: next, in: scope)
                if picked != nil, !hasLoggedHover {
                    hasLoggedHover = true
                    log.notice("first highlight \(picked?.chip ?? "", privacy: .public)")
                }
                if composer == nil && !isEffectivelyPaused && !isPointerOverPanel && !isPickingWindow {
                    hover = picked
                }
            }
            isHoverRunning = false
        }
    }

    /// Picks again under the pointer after the page moved under it, such as on scroll, so the
    /// hover highlight stays on the element.
    func refreshHover() {
        guard hover != nil, phase == .annotating, !isEffectivelyPaused else {
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
            if !trackedElements.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.refreshTracking()
                }
            }
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
            setScope(picker.window(at: point))
            return
        }
        guard allows(point) else {
            return
        }
        if let draft = drafts.last(where: { draft in
            guard draft.anchor == nil, let marker = noteMarker(draft) else {
                return false
            }
            return hypot(marker.x - point.x, marker.y - point.y) <= 13
        }) {
            edit(draft.id)
            return
        }
        if composer != nil {
            closeComposer()
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
            let marker = CGPoint(x: picked.frame.maxX, y: picked.frame.minY)
            openComposer(
                target: .element(picked.element), frame: picked.frame, marker: marker, chip: picked.chip, outline: picked.frame,
                window: picked.window, anchor: picked.anchor, tracked: picked.tracked
            )
        }
    }

    func dragEnded(with rect: CGRect) {
        if previewID != nil {
            closePreview()
            return
        }
        if isPickingWindow {
            cancelWindowPick()
            return
        }
        guard let rect = Self.clamped(rect, scope: scope?.frame) else {
            return
        }
        if composer != nil {
            closeComposer()
        }
        let marker = CGPoint(x: rect.maxX, y: rect.minY)
        let window = scope ?? picker.window(at: CGPoint(x: rect.midX, y: rect.midY))
        let isOverBrowser = window?.number == browser.windowNumber
        Task {
            let anchor = isOverBrowser ? await browser.regionAnchor(for: rect) : nil
            openComposer(target: .region, frame: rect, marker: marker, chip: "Region", outline: nil, window: window, anchor: anchor)
        }
    }

    /// Opens the comment box for a new target and starts its screenshots. `window` is the
    /// window the target belongs to. For an element (`outline` set), both screenshots come
    /// from that window alone, so no other window, Tilde's included, can cover them.
    private func openComposer(
        target: Target, frame: CGRect, marker: CGPoint, chip: String, outline: CGRect?, window: ElementPicker.WindowInfo?, anchor: PageAnchor? = nil,
        tracked: TrackedElement? = nil
    ) {
        let closeUpRect = Self.closeUpRect(frame: frame, outline: outline)
        let keeping = Set(browser.windowNumber.map { [CGWindowID($0)] } ?? [])
        let browser = self.browser
        let capturesContext = session?.capturesContext ?? false
        let isInBrowserPage = window != nil && window?.number == browser.windowNumber
        let pageFrame = browser.pageFrame?.flipped
        let capture = Task {
            // Tilde's browser draws its page itself, with no Screen Recording; the visible part
            // of the page is the context, like a whole window elsewhere.
            if isInBrowserPage || !ScreenCapture.isAllowed {
                let image = await browser.snapshot(of: closeUpRect, outline: outline)
                var contextImage: Data?
                if isInBrowserPage, capturesContext, let pageFrame {
                    contextImage = await browser.snapshot(of: pageFrame, outline: frame, maxSide: 1024)
                }
                return Captures(image: image, contextImage: contextImage)
            }

            async let image = Self.closeUpImage(of: closeUpRect, outline: outline, window: window, keeping: keeping)
            async let contextImage = Self.contextImage(of: frame, isRegion: outline == nil, window: window, keeping: keeping, enabled: capturesContext)
            return await Captures(image: image, contextImage: contextImage)
        }

        hover = nil
        // Pages in Tilde's browser report their elements; other windows are compared by picture.
        var fingerprint: Task<NoteFingerprint?, Never>?
        var page: Task<PageIdentity?, Never>?
        if anchor == nil, let window {
            let windowID = CGWindowID(window.number)
            fingerprint = Task { await NoteFingerprint.capture(window: windowID, area: frame) }
            page = Task.detached { PageIdentity.read(pid: window.pid, windowFrame: window.frame) }
        }
        composer = .new(Pending(
            target: target, frame: frame, marker: marker, chip: chip, capture: capture, anchor: anchor, tracked: tracked,
            sourceWindow: window?.number, fingerprint: fingerprint, page: page, sourcePID: window?.pid
        ))
        log.notice("comment opened for \(chip, privacy: .public)")
        commentText = ""
        commentPanel.show(chip: chip, isEditing: false, near: marker, below: frame)
    }

    /// What the close-up shows: an element (`outline` set) with 4 pt around it so its outline
    /// fits, or a region exactly.
    nonisolated static func closeUpRect(frame: CGRect, outline: CGRect?) -> CGRect {
        outline.map { $0.insetBy(dx: -4, dy: -4) } ?? frame
    }

    /// Whether at least 80% of a region lies inside a window, so the window is its context.
    nonisolated static func isMostlyInside(_ region: CGRect, _ window: CGRect) -> Bool {
        let inside = window.intersection(region)
        return !inside.isNull && inside.width * inside.height >= 0.8 * region.width * region.height
    }

    /// The target alone: an element from its own window, or a region from the screen.
    nonisolated private static func closeUpImage(
        of rect: CGRect, outline: CGRect?, window: ElementPicker.WindowInfo?, keeping: Set<CGWindowID>
    ) async -> Data? {
        if let outline, let window {
            let image = await ScreenCapture.png(ofWindow: CGWindowID(window.number), area: rect, outline: outline, maxSide: 1200)
            if let image {
                return image
            }
        }
        return await ScreenCapture.png(of: rect, outline: outline, keeping: keeping, maxSide: 1200)
    }

    /// The whole window the target belongs to, with the target outlined. For a region: the
    /// window that holds most of it, or else its screen. Nil when `enabled` is false.
    nonisolated private static func contextImage(
        of frame: CGRect, isRegion: Bool, window: ElementPicker.WindowInfo?, keeping: Set<CGWindowID>, enabled: Bool
    ) async -> Data? {
        guard enabled else {
            return nil
        }

        if let window {
            if !isRegion || isMostlyInside(frame, window.frame) {
                return await ScreenCapture.png(ofWindow: CGWindowID(window.number), area: window.frame, outline: frame, maxSide: 1024)
            }
        }

        let center = CGPoint(x: frame.midX, y: frame.midY).flipped
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens.first
        let bounds = screen?.frame.flipped ?? frame
        return await ScreenCapture.png(of: bounds, outline: frame, keeping: keeping, maxSide: 1024)
    }

    // MARK: - Comments

    func edit(_ id: Draft.ID) {
        guard let draft = drafts.first(where: { $0.id == id }) else {
            return
        }
        hover = nil
        composer = .edit(id)
        commentText = draft.annotation.comment
        commentPanel.show(chip: draft.chip, isEditing: true, near: draft.marker, below: draft.annotation.frame)
    }

    func submitComment(thenSend: Bool) {
        guard let composer else {
            return
        }
        let comment = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        log.notice("comment submitted (\(comment.count) characters, send: \(thenSend))")

        switch composer {
        case .edit(let id):
            if let index = drafts.firstIndex(where: { $0.id == id }) {
                drafts[index].annotation.comment = comment
            }

        case .new(let pending):
            let annotation = Annotation(comment: comment, target: pending.target, frame: pending.frame, image: nil, contextImage: nil)
            drafts.append(Draft(
                annotation: annotation, marker: pending.marker, chip: pending.chip, capture: pending.capture, anchor: pending.anchor,
                sourceWindow: pending.sourceWindow, fingerprint: pending.fingerprint, page: pending.page, sourcePID: pending.sourcePID
            ))
            startOcclusion()
            startContentChecks()
            if let tracked = pending.tracked {
                trackedElements[annotation.id] = tracked
                startTracking()
            }
            Task {
                let captures = await pending.capture.value
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
        if thenSend {
            send()
        }
    }

    func deleteDraft(_ id: Draft.ID) {
        if previewID == id {
            showAdjacentPreview(1)
            if previewID == id {
                closePreview()
            }
        }
        drafts.removeAll { $0.id == id }
        if case .edit(id) = composer {
            closeComposer()
        }
    }

    /// Discards the open comment, including a new target's capture.
    func closeComposer() {
        if case .new(let pending) = composer {
            pending.capture.cancel()
        }
        log.notice("comment discarded")
        hideComposer()
    }

    private func hideComposer() {
        composer = nil
        commentPanel.close()
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
            MainActor.assumeIsolated {
                self?.handleConfirmationKey(event.keyCode) == true ? nil : event
            }
        }
    }

    /// Returns whether the key answered the question on screen.
    func handleConfirmationKey(_ keyCode: UInt16) -> Bool {
        guard confirmation != nil else {
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
        guard composer == nil, previewID == nil, !isEffectivelyPaused else {
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
            closeComposer()
        }
        hover = nil
        previewID = id
        expandedPreviewImage = nil
        previewPanel.show()
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
        previewID = nil
        expandedPreviewImage = nil
        previewPanel.close()
        makeOverlayKey()
    }

    func updateComment(_ id: Draft.ID, _ comment: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else {
            return
        }
        drafts[index].annotation.comment = comment
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
        phase: Phase = .annotating,
        hover: Picked? = nil,
        composer: Composer? = nil,
        isPaused: Bool = false,
        previewID: Draft.ID? = nil,
        confirmation: Confirmation? = nil,
        scope: ElementPicker.WindowInfo? = nil,
        isPickingWindow: Bool = false,
        isHUDInBrowser: Bool = false,
        isAutoPaused: Bool = false,
        pauseNotice: PauseNotice? = nil
    ) {
        self.session = session
        self.drafts = drafts
        self.phase = phase
        self.hover = hover
        self.composer = composer
        self.isPaused = isPaused
        self.previewID = previewID
        self.confirmation = confirmation
        self.scope = scope
        self.isPickingWindow = isPickingWindow
        self.isHUDInBrowser = isHUDInBrowser
        self.isAutoPaused = isAutoPaused
        self.pauseNotice = pauseNotice
        isHUDShown = true
    }
}
#endif
