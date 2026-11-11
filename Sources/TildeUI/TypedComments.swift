import Foundation

/// Comments typed into the fields of notes, kept until typing pauses: every change to the
/// notes redraws the HUD and the overlay, which must not happen on each key.
@MainActor
final class TypedComments {
    /// No key came for 250 ms.
    var onPause: () -> Void = {}

    private var comments: [Draft.ID: String] = [:]
    private let pauseTime = Countdown()

    func typed(_ id: Draft.ID, _ comment: String) {
        comments[id] = comment
        pauseTime.start(0.25) { [weak self] in
            self?.onPause()
        }
    }

    /// What was typed since the last call, for the notes to take.
    func take() -> [Draft.ID: String] {
        pauseTime.cancel()
        let typed = comments
        comments = [:]
        return typed
    }
}
