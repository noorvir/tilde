import AppKit

/// The comment box of the session: what it is open on, its text, and its panel next to the
/// target. The session's flow says when it opens and closes.
@MainActor
final class CommentBox: ObservableObject {
    /// The new target that the box is open on, which is not yet a note; nil while it is closed.
    @Published private(set) var pending: Pending? {
        didSet {
            let isOpen = pending != nil
            if isOpen != (oldValue != nil) {
                onChange(isOpen)
            }
        }
    }
    /// The comment's text. Apart from the rest of the state: typing must not redraw the HUD
    /// and the overlay.
    let draft = CommentDraft()
    /// The box opened or closed.
    var onChange: (_ isOpen: Bool) -> Void = { _ in }

    private let makePanel: () -> CommentPanel
    private lazy var panel = makePanel()

    init(makePanel: @escaping () -> CommentPanel) {
        self.makePanel = makePanel
    }

    var text: String {
        get { draft.text }
        set { draft.text = newValue }
    }

    var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Opens the box, empty, on a new target.
    func open(_ pending: Pending) {
        self.pending = pending
        text = ""
        panel.show(chip: pending.chip, near: pending.marker, below: pending.frame)
    }

    /// The new target is somewhere else, as when its shape changed: the box goes along.
    func follow(_ pending: Pending) {
        self.pending = pending
        panel.follow(near: pending.marker, below: pending.frame)
    }

    func focus() {
        panel.focus()
    }

    func close() {
        guard pending != nil else {
            return
        }
        pending = nil
        panel.close()
    }

    /// Whether an AppKit screen point is over the box.
    func contains(_ point: NSPoint) -> Bool {
        pending != nil && panel.window.isVisible && panel.window.frame.contains(point)
    }
}

#if DEBUG
extension CommentBox {
    /// Sets what the box is open on without opening its panel.
    func setStateForTesting(pending: Pending?) {
        self.pending = pending
    }
}
#endif
