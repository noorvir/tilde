import AppKit

/// The comment box of the session: what it is open on, its text, and its panel next to the
/// target. The session's flow says when it opens and closes.
@MainActor
final class CommentBox: ObservableObject {
    /// What the box is open on; nil while it is closed.
    @Published private(set) var composer: Composer? {
        didSet {
            let isOpen = composer != nil
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

    /// The target of the open comment that is not yet a note.
    var pending: Pending? {
        if case .new(let pending) = composer {
            return pending
        }
        return nil
    }

    /// Opens the box, empty, on a new target.
    func open(_ pending: Pending) {
        composer = .new(pending)
        text = ""
        panel.show(chip: pending.chip, isEditing: false, near: pending.marker, below: pending.frame)
    }

    /// Opens the box on a note, with its comment.
    func open(editing draft: Draft) {
        composer = .edit(draft.id)
        text = draft.annotation.comment
        panel.show(chip: draft.chip, isEditing: true, near: draft.marker, below: draft.annotation.frame)
    }

    /// The new target is somewhere else, as when its shape changed: the box goes along.
    func follow(_ pending: Pending) {
        composer = .new(pending)
        panel.follow(near: pending.marker, below: pending.frame)
    }

    /// Gives the box the keyboard.
    func focus() {
        panel.focus()
    }

    func close() {
        guard composer != nil else {
            return
        }
        composer = nil
        panel.close()
    }

    /// Whether an AppKit screen point is over the box.
    func contains(_ point: NSPoint) -> Bool {
        composer != nil && panel.window.isVisible && panel.window.frame.contains(point)
    }
}

#if DEBUG
extension CommentBox {
    /// Sets what the box is open on without opening its panel.
    func setStateForTesting(composer: Composer?) {
        self.composer = composer
    }
}
#endif
