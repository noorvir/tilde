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
    let capture: Task<Data?, Never>

    var id: UUID { annotation.id }
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
    let capture: Task<Data?, Never>
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
    @Published private(set) var drafts: [Draft] = []
    @Published private(set) var hover: Picked?
    @Published private(set) var composer: Composer?
    @Published private(set) var isPaused = false
    @Published var showsList = false
    @Published var commentText = ""

    private let store: SessionStore
    private let browser: BrowserController
    private let picker: ElementPicker
    private var overlays: [OverlayWindow] = []
    private lazy var hud = HUDPanel(controller: self)
    private lazy var commentPanel = CommentPanel(controller: self)
    private var subscription: AnyCancellable?

    private var latestHoverPoint: CGPoint?
    private var isHoverRunning = false
    private var isSending = false
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")

    init(store: SessionStore, browser: BrowserController) {
        self.store = store
        self.browser = browser
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
        phase = .annotating
        log.notice("session \(session.id, privacy: .public) started for \(session.client, privacy: .public)")

        if let url = session.url {
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
        commentPanel.close()
        for overlay in overlays {
            overlay.close()
        }
        overlays = []
        hover = nil
        composer = nil
        session = nil
        drafts = []

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
                let image = await draft.capture.value
                let annotation = draft.annotation
                annotations.append(Annotation(id: annotation.id, comment: annotation.comment, target: annotation.target, frame: annotation.frame, image: image))
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
        _ = store.start(client: "You", message: nil, url: nil, isLocal: true)
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

    // MARK: - Picking

    func mouseMoved(to point: CGPoint) {
        guard composer == nil, !isPaused else {
            return
        }
        if isOverPanel(point) {
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
                if composer == nil && !isPaused {
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
            openComposer(target: .element(picked.element), frame: picked.frame, marker: marker, chip: picked.chip, outline: picked.frame)
        }
    }

    func dragEnded(with rect: CGRect) {
        if composer != nil {
            closeComposer()
        }
        let marker = CGPoint(x: rect.maxX, y: rect.minY)
        openComposer(target: .region, frame: rect, marker: marker, chip: "Region", outline: nil)
    }

    private func openComposer(target: Target, frame: CGRect, marker: CGPoint, chip: String, outline: CGRect?) {
        let captureRect: CGRect
        if let outline {
            captureRect = outline.insetBy(dx: -24, dy: -24)
        } else {
            captureRect = frame
        }

        let ownWindows: [NSWindow] = overlays + [hud.window, commentPanel.window]
        // Windows that were never shown have no window number yet.
        let hidden = Set(ownWindows.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
        let browser = self.browser
        let capture = Task {
            if ScreenCapture.isAllowed {
                return await ScreenCapture.png(of: captureRect, outline: outline, hiding: hidden)
            }
            return await browser.snapshot(of: captureRect, outline: outline)
        }

        hover = nil
        composer = .new(Pending(target: target, frame: frame, marker: marker, chip: chip, capture: capture))
        log.notice("comment opened for \(chip, privacy: .public)")
        commentText = ""
        commentPanel.show(chip: chip, isEditing: false, near: marker, below: frame)
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
            let annotation = Annotation(comment: comment, target: pending.target, frame: pending.frame, image: nil)
            drafts.append(Draft(annotation: annotation, marker: pending.marker, chip: pending.chip, capture: pending.capture))
            Task {
                let image = await pending.capture.value
                guard let index = drafts.firstIndex(where: { $0.id == annotation.id }) else {
                    return
                }
                let current = drafts[index].annotation
                drafts[index].annotation = Annotation(id: current.id, comment: current.comment, target: current.target, frame: current.frame, image: image)
            }
        }

        hideComposer()
        if thenSend {
            send()
        }
    }

    func deleteDraft(_ id: Draft.ID) {
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
        guard composer == nil, !isPaused else {
            return
        }
        let pointer = NSEvent.mouseLocation
        let overlay = overlays.first { $0.frame.contains(pointer) } ?? overlays.first
        overlay?.makeKey()
    }

    /// Whether a Quartz point is over Tilde's own HUD or comment box.
    func isOverPanel(_ point: CGPoint) -> Bool {
        let point = point.flipped
        return hud.contains(point) || (commentPanel.window.isVisible && commentPanel.window.frame.contains(point))
    }

    /// Frame and marker of the comment target that is not yet a draft.
    var pendingTarget: Pending? {
        if case .new(let pending) = composer {
            return pending
        }
        return nil
    }
}
