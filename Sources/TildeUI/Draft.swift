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
    /// Where a drawing's shapes are, in Quartz screen coordinates.
    var drawingBounds: CGRect?
}

extension NewNote {
    /// A note on a picked element, for a click at `point`. In a window that shows no elements,
    /// the label is at the point, and only the picture around it tells whether the note is
    /// still on screen.
    init(_ picked: Picked, at point: CGPoint) {
        let isWholeWindow = picked.isWholeWindow
        let marker = isWholeWindow ? point : CGPoint(x: picked.frame.maxX, y: picked.frame.minY)
        self.init(
            target: .element(picked.element), frame: picked.frame, marker: marker, chip: picked.chip, outline: picked.frame,
            window: picked.window, anchor: picked.anchor, tracked: isWholeWindow ? nil : picked.tracked,
            pictureArea: isWholeWindow ? NoteFingerprint.area(around: point) : nil
        )
    }
}

extension Draft {
    /// The note of a comment box with its comment. `capture`: its screenshots, which can be
    /// newer than the ones of `pending`.
    init(_ pending: Pending, comment: String, capture: Task<Captures, Never>) {
        let annotation = Annotation(comment: comment, target: pending.target, frame: pending.frame, image: nil, contextImage: nil)
        self.init(
            annotation: annotation, marker: pending.marker, chip: pending.chip, capture: capture, anchor: pending.anchor,
            sourceWindow: pending.sourceWindow, fingerprint: pending.fingerprint, page: pending.page, sourcePID: pending.sourcePID, pictureArea: pending.pictureArea
        )
    }
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
            pictureArea: note.pictureArea, drawingIDs: note.drawingIDs, drawingBounds: note.drawingBounds
        )
    }
}
