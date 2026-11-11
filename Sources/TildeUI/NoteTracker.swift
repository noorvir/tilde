import AppKit

/// Where each note of the session is on screen now, and whether it shows: a note on an element
/// of another app follows that element; a note hides behind windows in front of its window,
/// with its window, and when its content is gone from its window, such as after a page change.
/// A note on a page in Tilde's browser is where the browser finds its element. The overlay
/// draws from it.
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
    /// Annotating is paused: the user works in their apps.
    var isPaused = false

    private let windows: WindowStack
    private let browser: BrowserController
    private var elements: [Draft.ID: TrackedElement] = [:]
    /// Notes whose element the app no longer reports: only the picture can confirm their content.
    private var goneElements: Set<Draft.ID> = []
    private var elementsToFindAgain: Set<Draft.ID> = []
    /// When each lost element is searched for next, and how long the last wait was.
    private var searches: [Draft.ID: (next: Date, delay: TimeInterval)] = [:]
    private var trackingTimer: Timer?
    private var isTracking = false
    private let trackingQueue = DispatchQueue(label: "tilde.tracking")
    private var visibilities: [Draft.ID: NoteVisibility] = [:]
    private var contentTimer: Timer?
    private var isCheckingContent = false
    /// Something that can change a note's content happened since the last round of checks.
    private var isChanged = true
    private var lastRound = Date.distantPast

    init(windows: WindowStack, browser: BrowserController) {
        self.windows = windows
        self.browser = browser
    }

    /// Notes were added: their windows and content are checked from now on.
    func notesAdded() {
        isChanged = true
        refreshCovers()
        startContentChecks()
    }

    /// Something happened that can change what the notes' windows show: input, a window that
    /// moved, came or went, another app in front.
    func somethingChanged() {
        isChanged = true
    }

    /// A page scrolled under the pointer: the notes on it moved, and a lost element may be in
    /// view again.
    func scrolled() {
        isChanged = true
        searches = [:]
        guard isFollowing else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.refreshTracking()
        }
    }

    /// The window that the session is limited to moved.
    func windowMoved() {
        isChanged = true
        searches = [:]
        refreshTracking()
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
        searches = [:]
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

    // MARK: - Notes on a page in Tilde's browser

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
        return notes.enumerated().compactMap { index, draft in
            // No height: scrolled out of its panel.
            guard let rect = browser.anchorRects[draft.id], rect.height > 0 else {
                return nil
            }
            return PageNote(number: index + 1, draft: draft, frame: rect.offsetBy(dx: page.minX, dy: page.minY))
        }
    }

    // MARK: - Labels

    /// The note whose numbered label is at this point.
    func label(at point: CGPoint) -> Draft.ID? {
        let labels = notes.filter { $0.anchor == nil }.compactMap { draft in marker(of: draft).map { (draft.id, $0) } }
            + anchoredNotes.map { ($0.draft.id, $0.marker) }
        return labels.last { Self.isOnLabel(distance: hypot($0.1.x - point.x, $0.1.y - point.y)) }?.0
    }

    /// A label's circle has a radius of 10 points; 8 more around it make it easy to hit.
    nonisolated static func isOnLabel(distance: CGFloat) -> Bool {
        distance <= 18
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
        // The window of Tilde's browser, while the overlay draws the notes of its page.
        if !pageNotes.isEmpty, let page = browser.windowNumber {
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

    private var isFollowing: Bool {
        !elements.isEmpty
    }

    /// Reads where each tracked element is, off the main thread, and moves its note there.
    func refreshTracking() {
        guard !isTracking, !elements.isEmpty, !isHeld else {
            return
        }
        isTracking = true
        // A note off its page stays with its page: another page's look-alike is not its element.
        let now = Date()
        let work = elements.filter { !contentGone.contains($0.key) }.map { id, tracked in
            let original = notes.first { $0.id == id }?.annotation.frame ?? .zero
            let findsAgain = elementsToFindAgain.contains(id)
            let searches = findsAgain || (self.searches[id]?.next ?? .distantPast) <= now
            return (id, tracked, findsAgain ? original : frames[id] ?? original, findsAgain, searches)
        }
        elementsToFindAgain = []
        trackingQueue.async { [weak self] in
            let results = work.map { id, tracked, last, findsAgain, searches in
                (id, ElementTracker.locate(tracked, lastFrame: last, findsAgain: findsAgain, searches: searches), searches)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.applyTracking(results)
                }
            }
        }
    }

    /// How long to wait before the next search for an element that a search did not find:
    /// twice the last wait, from 0.2 s up to 5 s. A search walks the app's elements.
    nonisolated static func searchDelay(after last: TimeInterval?) -> TimeInterval {
        min(5, (last ?? 0.1) * 2)
    }

    private func applyTracking(_ results: [(Draft.ID, (frame: CGRect?, tracked: TrackedElement, isGone: Bool), Bool)]) {
        isTracking = false
        var frames = self.frames
        var hidden = self.hidden
        let gone = goneElements
        for (id, result, searched) in results where elements[id] != nil {
            elements[id] = result.tracked
            if result.isGone {
                goneElements.insert(id)
                if searched {
                    let delay = Self.searchDelay(after: searches[id]?.delay)
                    searches[id] = (Date().addingTimeInterval(delay), delay)
                }
            } else {
                goneElements.remove(id)
                searches[id] = nil
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
        if frames != self.frames || hidden != self.hidden || gone != goneElements {
            isChanged = true
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

    /// What the page's identity says about a note's content, or that its element is gone from
    /// a plain area: nil when only the picture can tell.
    nonisolated private static func pageSimilarity(of check: ContentCheck, page now: PageIdentity?) async -> Double? {
        let original = await check.page?.value
        if let original, let isSame = now?.isSamePage(as: original),
           let similarity = NoteVisibility.similarity(isSamePage: isSame, isElementConfirmed: check.isElementConfirmed)
        {
            return similarity
        }
        if check.isElementGone, await check.fingerprint.value?.isPlain == true {
            return 0
        }
        return nil
    }

    /// How often content is checked at most, and at least while nothing changes.
    nonisolated static let checkInterval: TimeInterval = 0.5
    nonisolated static let quietInterval: TimeInterval = 1

    /// Whether a round of checks runs now. It runs after a change and while a note's showing is
    /// about to change; with no change, once a second, and not at all while annotating is paused
    /// with no note on screen, as only something the user does can change what shows then.
    nonisolated static func runsRound(isChanged: Bool, isSettling: Bool, sinceLastRound: TimeInterval, isPaused: Bool, isAnyNoteShown: Bool) -> Bool {
        if isChanged || isSettling {
            return true
        }
        if isPaused, !isAnyNoteShown {
            return false
        }
        return sinceLastRound >= quietInterval - 0.05
    }

    private func startContentChecks() {
        guard contentTimer == nil else {
            return
        }
        contentTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
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
        let isSettling = checks.contains { visibilities[$0.id]?.isSettled == false }
        let isAnyNoteShown = notes.contains { note in
            frame(of: note) != nil && !(note.sourceWindow.map(hiddenWindows.contains) ?? false)
        }
        let runs = Self.runsRound(
            isChanged: isChanged, isSettling: isSettling, sinceLastRound: Date().timeIntervalSince(lastRound), isPaused: isPaused, isAnyNoteShown: isAnyNoteShown
        )
        guard !checks.isEmpty, runs else {
            return
        }
        isChanged = false
        lastRound = Date()
        isCheckingContent = true
        Task { [weak self] in
            let similarities = await Self.similarities(of: checks)
            self?.applyContentChecks(similarities)
        }
    }

    /// One round: for each window, one read of its page and one screenshot of the notes that
    /// the page cannot decide.
    nonisolated private static func similarities(of checks: [ContentCheck]) async -> [Draft.ID: Double] {
        var similarities: [Draft.ID: Double] = [:]
        for (window, checks) in Dictionary(grouping: checks, by: \.window) {
            var page: PageIdentity?
            if let pid = checks[0].pid, let frame = checks[0].windowFrame {
                page = await Task.detached { PageIdentity.read(pid: pid, windowFrame: frame) }.value
            }
            var byPicture: [(check: ContentCheck, fingerprint: NoteFingerprint)] = []
            for check in checks {
                if let similarity = await pageSimilarity(of: check, page: page) {
                    similarities[check.id] = similarity
                } else if let fingerprint = await check.fingerprint.value {
                    byPicture.append((check, fingerprint))
                }
            }
            guard !byPicture.isEmpty else {
                continue
            }
            let current = await NoteFingerprint.capture(window: CGWindowID(window), areas: byPicture.map(\.check.frame), windowFrame: checks[0].windowFrame)
            for ((check, fingerprint), now) in zip(byPicture, current) {
                similarities[check.id] = now.map { $0.similarity(to: fingerprint) }
            }
        }
        return similarities
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
