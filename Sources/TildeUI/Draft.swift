import TildeCore
import AppKit

/// An annotation the user has added but not yet sent. `annotation.image` fills in when
/// `capture` finishes; sending waits for every capture.
struct Draft: Identifiable {
    var annotation: Annotation
    /// From a saved session, with no window or page to confirm where it belongs.
    var isRestored = false
    /// Quartz point where the numbered marker sits.
    var marker: CGPoint
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
    /// The part of its window that the picture check looks at, when that is not its frame.
    var pictureArea: CGRect?

    var id: UUID { annotation.id }
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
    var target: Target
    var frame: CGRect
    var marker: CGPoint
    let chip: String
    let capture: Task<Captures, Never>
    var anchor: PageAnchor?
    var tracked: TrackedElement?
    var sourceWindow: Int?
    var fingerprint: Task<NoteFingerprint?, Never>?
    var page: Task<PageIdentity?, Never>?
    var sourcePID: pid_t?
    var pictureArea: CGRect?
    var drawingIDs: [String] = []
    /// The shape changed after its picture was taken.
    var isDrawingEdited = false
    /// Where the shape is; `frame` is what its label is attached to.
    var drawingBounds: CGRect?
}

/// A target the user picked or drew, before its comment box opens.
struct NewNote {
    var target: Target
    /// What its label is attached to.
    var frame: CGRect
    var marker: CGPoint
    var chip: String
    /// The element to outline in its screenshots; nil for a region or a drawing.
    var outline: CGRect?
    /// The window it belongs to.
    var window: ElementPicker.WindowInfo?
    var anchor: PageAnchor?
    var tracked: TrackedElement?
    var pictureArea: CGRect?
    /// Its screenshots when they are taken already, as for a drawing.
    var captures: Captures?
    var drawingIDs: [String] = []
}

extension Pending {
    /// A new target with its screenshots started, and, outside Tilde's browser, what its area
    /// looks like and which page it is on, to tell later whether it still shows.
    @MainActor
    init(_ note: NewNote, browser: BrowserController, withContext: Bool) {
        let capture: Task<Captures, Never>
        if let captures = note.captures {
            capture = Task { captures }
        } else {
            capture = NoteCaptures.start(of: note.frame, outline: note.outline, window: note.window, browser: browser, withContext: withContext)
        }

        // Pages in Tilde's browser report their elements; other windows are compared by picture.
        var fingerprint: Task<NoteFingerprint?, Never>?
        var page: Task<PageIdentity?, Never>?
        if note.anchor == nil, let window = note.window {
            let windowID = CGWindowID(window.number)
            let area = note.pictureArea ?? note.frame
            fingerprint = Task { await NoteFingerprint.capture(window: windowID, area: area) }
            page = Task.detached { PageIdentity.read(pid: window.pid, windowFrame: window.frame) }
        }

        self.init(
            target: note.target, frame: note.frame, marker: note.marker, chip: note.chip, capture: capture, anchor: note.anchor,
            tracked: note.tracked, sourceWindow: note.window?.number, fingerprint: fingerprint, page: page, sourcePID: note.window?.pid,
            pictureArea: note.pictureArea, drawingIDs: note.drawingIDs
        )
    }
}
