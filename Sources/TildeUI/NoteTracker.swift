import AppKit

/// Where each note of the session is on screen now, and whether it shows: a note on an element
/// of another app follows that element; a note hides behind windows in front of its window,
/// with its window, and when its content is gone from its window, such as after a page change.
/// The overlay draws from it.
@MainActor
final class NoteTracker: ObservableObject {
    /// Where followed elements are; a note missing here but in `hidden` scrolled out of view or
    /// lost its element.
    @Published private(set) var frames: [Draft.ID: CGRect] = [:]
    @Published private(set) var hidden: Set<Draft.ID> = []
    /// Notes whose content is gone from their window. They stay in the session, the list and
    /// the report; only their marks hide.
    @Published private(set) var contentGone: Set<Draft.ID> = []
    /// For each window with notes, the frames of the windows in front of it; a window not on
    /// screen (closed, minimised, on another Space) is in `hiddenWindows`, and its notes hide.
    @Published private(set) var windowCovers: [Int: [CGRect]] = [:]
    @Published private(set) var hiddenWindows: Set<Int> = []
    /// How far back each window with notes is: 0 for the front window.
    private(set) var windowDepth: [Int: Int] = [:]
    /// Where the windows are, from the last read of the window stack.
    private(set) var windowFrames: [Int: CGRect] = [:]

    /// The notes of the session, in their order.
    var notes: [Draft] = [] {
        didSet {
            let ids = Set(notes.map(\.id))
            elements = elements.filter { ids.contains($0.key) }
        }
    }
    /// While the comment box is open nothing moves: the user types, and typing must stay instant.
    var isHeld = false {
        didSet {
            if !isHeld {
                refreshCovers()
            }
        }
    }
    /// The window of Tilde's browser while the overlay draws the notes of its page.
    var pageWindow: () -> Int? = { nil }

    private let windows: WindowStack
    private var elements: [Draft.ID: TrackedElement] = [:]
    /// Notes whose element the app no longer reports: only the picture can confirm their content.
    private var goneElements: Set<Draft.ID> = []
    private var elementsToFindAgain: Set<Draft.ID> = []
    private var trackingTimer: Timer?
    private var isTracking = false
    private let trackingQueue = DispatchQueue(label: "tilde.tracking")
    private var visibilities: [Draft.ID: NoteVisibility] = [:]
    private var contentTimer: Timer?
    private var isCheckingContent = false

    init(windows: WindowStack) {
        self.windows = windows
    }

    /// Notes were added: their windows and content are checked from now on.
    func notesAdded() {
        refreshCovers()
        startContentChecks()
    }

    /// The note follows this element of another app.
    func follow(_ id: Draft.ID, element: TrackedElement) {
        elements[id] = element
        startTracking()
    }

    func stop() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        elements = [:]
        frames = [:]
        hidden = []
        goneElements = []
        contentTimer?.invalidate()
        contentTimer = nil
        visibilities = [:]
        contentGone = []
        windowCovers = [:]
        hiddenWindows = []
        windowDepth = [:]
    }

    // MARK: - Where a note is

    /// Where a note's element or region is on screen now, or nil while it does not show.
    func frame(of draft: Draft) -> CGRect? {
        if hidden.contains(draft.id) || contentGone.contains(draft.id) {
            return nil
        }
        // A recording is only in the list.
        if case .recording = draft.annotation.target {
            return nil
        }
        // Nothing can confirm that its element is on screen; it stays in the list of notes.
        if draft.isRestored, draft.anchor == nil {
            return nil
        }
        return frames[draft.id] ?? draft.annotation.frame
    }

    /// Where a note's numbered marker is now, at its element's top-right corner.
    func marker(of draft: Draft) -> CGPoint? {
        guard let frame = frame(of: draft) else {
            return nil
        }
        return elements[draft.id] != nil ? CGPoint(x: frame.maxX, y: frame.minY) : draft.marker
    }

    // MARK: - Windows in front of notes

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

    /// Which windows cover the windows that have notes, from the last read of the window
    /// stack, which reads again when windows can have changed.
    func refreshCovers() {
        guard !isHeld else {
            return
        }
        var withNotes = Set(notes.compactMap(\.sourceWindow))
        if let page = pageWindow() {
            withNotes.insert(page)
        }
        guard !withNotes.isEmpty else {
            return
        }
        let stack = windows.windows.map { StackWindow(number: $0.number, frame: $0.frame) }
        windowFrames = Dictionary(stack.map { ($0.number, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let result = Self.covers(of: withNotes, in: stack)
        windowDepth = Dictionary(uniqueKeysWithValues: stack.enumerated().filter { withNotes.contains($0.element.number) }.map { ($0.element.number, $0.offset) })
        if result.covers != windowCovers {
            windowCovers = result.covers
        }
        if result.missing != hiddenWindows {
            hiddenWindows = result.missing
        }
    }

    // MARK: - Following elements in other apps

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

    var isFollowing: Bool {
        !elements.isEmpty
    }

    /// Reads where each tracked element is, off the main thread, and moves its note there.
    func refreshTracking() {
        guard !isTracking, !elements.isEmpty, !isHeld else {
            return
        }
        isTracking = true
        // A note off its page stays with its page: another page's look-alike is not its element.
        let work = elements.filter { !contentGone.contains($0.key) }.map { id, tracked in
            let original = notes.first { $0.id == id }?.annotation.frame ?? .zero
            let findsAgain = elementsToFindAgain.contains(id)
            return (id, tracked, findsAgain ? original : frames[id] ?? original, findsAgain)
        }
        elementsToFindAgain = []
        trackingQueue.async { [weak self] in
            let results = work.map { id, tracked, last, findsAgain in (id, ElementTracker.locate(tracked, lastFrame: last, findsAgain: findsAgain)) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.applyTracking(results)
                }
            }
        }
    }

    private func applyTracking(_ results: [(Draft.ID, (frame: CGRect?, tracked: TrackedElement, isGone: Bool))]) {
        isTracking = false
        var frames = self.frames
        var hidden = self.hidden
        for (id, result) in results where elements[id] != nil {
            elements[id] = result.tracked
            if result.isGone {
                goneElements.insert(id)
            } else {
                goneElements.remove(id)
            }
            let windowFrame = notes.first { $0.id == id }?.sourceWindow.flatMap { windowFrames[$0] }
            if let frame = result.frame, let visible = ElementTracker.visibleFrame(frame, clips: windowFrame.map { [$0] } ?? []) {
                frames[id] = visible
                hidden.remove(id)
            } else if result.isGone, notes.first(where: { $0.id == id })?.fingerprint != nil {
                // Apps such as the Simulator rebuild elements on every page. The picture of
                // the note's area decides, so the note comes back with its page.
                hidden.remove(id)
            } else {
                hidden.insert(id)
            }
        }
        if frames != self.frames {
            self.frames = frames
        }
        if hidden != self.hidden {
            self.hidden = hidden
        }
    }

    // MARK: - Whether a note's content is on screen

    private struct ContentCheck: Sendable {
        let id: Draft.ID
        let window: Int
        let windowFrame: CGRect?
        let pid: pid_t?
        let frame: CGRect
        let fingerprint: Task<NoteFingerprint?, Never>
        let page: Task<PageIdentity?, Never>?
        let isElementConfirmed: Bool
        let isElementGone: Bool
    }

    /// How much a note's content is on screen: the page's identity decides when it can, and
    /// the picture of the note's area otherwise. Nil when neither can be read.
    nonisolated private static func similarity(of check: ContentCheck, page now: PageIdentity?) async -> Double? {
        let original = await check.page?.value
        if let original, let isSame = now?.isSamePage(as: original),
           let similarity = NoteVisibility.similarity(isSamePage: isSame, isElementConfirmed: check.isElementConfirmed)
        {
            return similarity
        }

        if check.isElementGone, await check.fingerprint.value?.isPlain == true {
            return 0
        }

        guard let fingerprint = await check.fingerprint.value,
              let current = await NoteFingerprint.capture(window: CGWindowID(check.window), area: check.frame, windowFrame: check.windowFrame)
        else {
            return nil
        }
        return current.similarity(to: fingerprint)
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

    private func checkContent() {
        guard !isCheckingContent, !isHeld else {
            return
        }
        let checks = notes.compactMap { draft -> ContentCheck? in
            guard let window = draft.sourceWindow, let fingerprint = draft.fingerprint, !hiddenWindows.contains(window) else {
                return nil
            }
            return ContentCheck(
                id: draft.id, window: window, windowFrame: windowFrames[window], pid: draft.sourcePID,
                frame: draft.pictureArea ?? frames[draft.id] ?? draft.annotation.frame, fingerprint: fingerprint, page: draft.page,
                isElementConfirmed: elements[draft.id] != nil && !goneElements.contains(draft.id),
                isElementGone: goneElements.contains(draft.id)
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
        var gone = contentGone
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
        }
        if gone != contentGone {
            contentGone = gone
        }
    }
}
