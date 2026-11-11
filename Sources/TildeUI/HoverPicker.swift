import AppKit
import os

@MainActor
final class HoverHighlight: ObservableObject {
    @Published var picked: Picked?
}

/// The element under the pointer while annotating. One pick runs at a time: a point that comes
/// meanwhile is picked next, and the points between are dropped.
@MainActor
final class HoverPicker {
    /// It changes at pointer rate and only the overlay draws it, so it is apart from the state
    /// that the HUD and the panels redraw on.
    let highlight = HoverHighlight()
    var picked: Picked? {
        get { highlight.picked }
        set { highlight.picked = newValue }
    }
    /// The window that the session is limited to.
    var scope: () -> ElementPicker.WindowInfo? = { nil }
    /// Whether a pick that finishes now still shows: the pointer can have moved onto Tilde's
    /// UI meanwhile, or a comment box opened.
    var shows: () -> Bool = { true }
    /// A scroll ended: the page moved under the pointer.
    var onScrollEnded: () -> Void = {}

    private let picker: ElementPicker
    private var latestPoint: CGPoint?
    private var task: Task<Void, Never>?
    private let scrollTime = Countdown()
    /// Logs the first highlight after each resume, to measure how soon hover works.
    private var hasLoggedHighlight = false
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")

    init(picker: ElementPicker) {
        self.picker = picker
    }

    /// Highlights the element at a point, after the pick under way.
    func pick(at point: CGPoint) {
        latestPoint = point
        guard task == nil else {
            return
        }

        task = Task {
            while let next = latestPoint {
                latestPoint = nil
                let picked = await picker.pick(at: next, isMoving: true, in: scope())
                // The overlay stopped taking input meanwhile.
                if Task.isCancelled {
                    return
                }
                if picked != nil, !hasLoggedHighlight {
                    hasLoggedHighlight = true
                    log.notice("first highlight \(picked?.chip ?? "", privacy: .public)")
                }
                if shows() {
                    self.picked = picked
                }
            }
            task = nil
        }
    }

    /// Nothing is highlighted, and no point waits for its pick.
    func clear() {
        latestPoint = nil
        picked = nil
    }

    /// Also drops the pick under way.
    func stop() {
        task?.cancel()
        task = nil
        clear()
    }

    /// A scroll event went to the page under the pointer; 60 ms after the last one, the
    /// scroll has ended.
    func scrolled() {
        scrollTime.start(0.06) { [weak self] in
            self?.onScrollEnded()
        }
    }

    func logNextHighlight() {
        hasLoggedHighlight = false
    }
}
