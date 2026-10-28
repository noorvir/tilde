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

    var id: UUID { annotation.id }
}

/// HUD actions that discard every annotation, so the pill asks before doing them.
enum Confirmation {
    case clearAll
    case cancelSession
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
        }
    }
    @Published private(set) var hover: Picked?
    @Published private(set) var composer: Composer?
    @Published private(set) var isPaused = false
    /// The draft shown in the preview card; annotate clicks wait while it is open.
    @Published private(set) var previewID: Draft.ID?
    /// A destructive HUD action waiting for the user to confirm it in the pill.
    @Published private(set) var confirmation: Confirmation?
    /// Whether the HUD pill is open. HUDPanel animates it, so the pill grows out of its centre
    /// when it appears and collapses into it before the panel hides.
    @Published var isHUDShown = false
    /// The screenshot that fills the preview card's image area, if any.
    @Published var expandedPreviewImage: PreviewImage?
    @Published var showsList = false
    @Published var commentText = ""

    private let store: SessionStore
    private let browser: BrowserController
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
    /// The icon of the agent app with this display name, for the HUD; nil when unknown.
    var clientIcon: (String) -> NSImage? = { _ in nil }
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")

    init(store: SessionStore, browser: BrowserController, shortcuts: ShortcutStore? = nil) {
        self.store = store
        self.browser = browser
        self.shortcuts = shortcuts ?? ShortcutStore()
        picker = ElementPicker(browser: browser)

        subscription = store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncWithStore() }
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
        phase = .annotating
        log.notice("session \(session.id, privacy: .public) started for \(session.client, privacy: .public)")

        if let url = session.url {
            if !session.isLocal, let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
                returnApp = frontmost
            }
            browser.show(url)
        }

        // Overlay panels are non-activating: the user's app stays frontmost while annotating.
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0, controller: self) }
        for overlay in overlays {
            overlay.orderFrontRegardless()
        }
        makeOverlayKey()
        hud.show()
    }

    private func end() {
        confirmation = nil
        commentPanel.close()
        previewPanel.close()
        previewID = nil
        for overlay in overlays {
            overlay.close()
        }
        overlays = []
        hover = nil
        composer = nil
        session = nil
        drafts = []

        if let returnApp {
            self.returnApp = nil
            browser.close()
            NSApp.yieldActivation(to: returnApp)
            returnApp.activate()
        }

        if case .sent = phase {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, case .sent = self.phase else {
                    return
                }
                self.phase = .idle
                self.hud.hide()
            }
        } else {
            phase = .idle
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

            let feedback = Feedback(annotations: annotations)
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
            store.finish(session.id, with: .sent(feedback, folder: folder))
            end()
        }
    }

    /// Starts a session from Tilde itself. Its feedback goes to the clipboard and the inbox.
    /// While a session is on screen, brings the HUD forward instead.
    func startLocal() {
        if session != nil {
            hud.show()
            return
        }
        _ = store.start(client: "You", url: nil, isLocal: true)
    }

    func cancel() {
        guard let session else {
            return
        }
        log.notice("session \(session.id, privacy: .public) cancelled")
        store.finish(session.id, with: .cancelled)
        end()
    }

    func togglePause() {
        guard phase == .annotating else {
            return
        }
        isPaused.toggle()
        hover = nil
        for overlay in overlays {
            overlay.ignoresMouseEvents = isPaused
        }
        if isPaused {
            // A key overlay would keep the keyboard; give it back to the user's app.
            NSWorkspace.shared.frontmostApplication?.activate()
        }
        makeOverlayKey()
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
        }
    }

    func dismissConfirmation() {
        confirmation = nil
    }

    // MARK: - Picking

    func mouseMoved(to point: CGPoint) {
        guard composer == nil, previewID == nil, !isPaused else {
            return
        }
        isPointerOverPanel = isOverPanel(point)
        if isPointerOverPanel {
            latestHoverPoint = nil
            hover = nil
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
                let picked = await picker.pick(at: next)
                if composer == nil && !isPaused && !isPointerOverPanel {
                    hover = picked
                }
            }
            isHoverRunning = false
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
        if let draft = drafts.last(where: { hypot($0.marker.x - point.x, $0.marker.y - point.y) <= 13 }) {
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
                picked = await picker.pick(at: point)
            }
            guard let picked else {
                return
            }
            let marker = CGPoint(x: picked.frame.maxX, y: picked.frame.minY)
            openComposer(target: .element(picked.element), frame: picked.frame, marker: marker, chip: picked.chip, outline: picked.frame, window: picked.window)
        }
    }

    func dragEnded(with rect: CGRect) {
        if previewID != nil {
            closePreview()
            return
        }
        if composer != nil {
            closeComposer()
        }
        let marker = CGPoint(x: rect.maxX, y: rect.minY)
        openComposer(target: .region, frame: rect, marker: marker, chip: "Region", outline: nil, window: picker.window(at: CGPoint(x: rect.midX, y: rect.midY)))
    }

    /// Opens the comment box for a new target and starts its screenshots. `window` is the
    /// window the target belongs to. For an element (`outline` set), both screenshots come
    /// from that window alone, so no other window, Tilde's included, can cover them.
    private func openComposer(target: Target, frame: CGRect, marker: CGPoint, chip: String, outline: CGRect?, window: ElementPicker.WindowInfo?) {
        let closeUpRect = Self.closeUpRect(frame: frame, outline: outline)
        let keeping = Set(browser.windowNumber.map { [CGWindowID($0)] } ?? [])
        let browser = self.browser
        let capturesContext = session?.capturesContext ?? false
        let capture = Task {
            guard ScreenCapture.isAllowed else {
                let image = await browser.snapshot(of: closeUpRect, outline: outline)
                return Captures(image: image, contextImage: nil)
            }

            async let image = Self.closeUpImage(of: closeUpRect, outline: outline, window: window, keeping: keeping)
            async let contextImage = Self.contextImage(of: frame, isRegion: outline == nil, window: window, keeping: keeping, enabled: capturesContext)
            return await Captures(image: image, contextImage: contextImage)
        }

        hover = nil
        composer = .new(Pending(target: target, frame: frame, marker: marker, chip: chip, capture: capture))
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
            drafts.append(Draft(annotation: annotation, marker: pending.marker, chip: pending.chip, capture: pending.capture))
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
    func makeOverlayKey() {
        guard composer == nil, previewID == nil, !isPaused else {
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
        confirmation: Confirmation? = nil
    ) {
        self.session = session
        self.drafts = drafts
        self.phase = phase
        self.hover = hover
        self.composer = composer
        self.isPaused = isPaused
        self.previewID = previewID
        self.confirmation = confirmation
        isHUDShown = true
    }
}
#endif
