import AppKit

/// The preview card of the session: the note it shows, and its panel. The session's flow
/// says when it opens and closes.
@MainActor
final class PreviewCard: ObservableObject {
    /// The note in the card; nil while it is closed. Annotate clicks wait while it is open.
    @Published private(set) var id: Draft.ID?
    /// The screenshot that fills the card's image area, if any.
    @Published var expandedImage: PreviewImage?

    private let makePanel: () -> PreviewPanel
    private lazy var panel = makePanel()

    init(makePanel: @escaping () -> PreviewPanel) {
        self.makePanel = makePanel
    }

    func open(_ id: Draft.ID) {
        self.id = id
        expandedImage = nil
        panel.show()
    }

    /// Shows the note `step` places on in `drafts`, wrapping around at either end. An enlarged
    /// screenshot stays enlarged, so ← and → compare the same kind of image.
    func step(_ step: Int, in drafts: [Draft]) {
        guard let id, let index = drafts.firstIndex(where: { $0.id == id }) else {
            return
        }
        let next = (index + step + drafts.count) % drafts.count
        self.id = drafts[next].id
    }

    func close() {
        expandedImage = nil
        guard id != nil else {
            return
        }
        id = nil
        panel.close()
    }

    /// Whether an AppKit screen point is over the card.
    func contains(_ point: NSPoint) -> Bool {
        id != nil && panel.window.isVisible && panel.window.frame.contains(point)
    }
}

#if DEBUG
extension PreviewCard {
    /// Sets the note in the card without opening its panel.
    func setStateForTesting(id: Draft.ID?) {
        self.id = id
    }
}
#endif
