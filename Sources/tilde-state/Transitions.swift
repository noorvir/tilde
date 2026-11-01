@testable import TildeUI
import Foundation

/// Runs the rows of a transition table through the real rules.
enum Transitions {
    struct Row: Decodable {
        let name: String
        var state: SessionFlow?
        var event: SessionFlow.Event?
        var note: NoteVisibility?
        var similarity: Double?
        var original: PageIdentity?
        var page: PageIdentity?
        var isElementConfirmed: Bool?
        var elementFrame: [CGFloat]?
        var windowFrame: [CGFloat]?
        var labelDistance: CGFloat?
    }

    struct Result: Encodable {
        let name: String
        var state: SessionFlow?
        var effects: [SessionFlow.Effect]?
        var note: NoteVisibility?
        var samePage: Bool?
        var hides: Bool?
        var pictureDecides: Bool?
        var labelShows: Bool?
        var isOnLabel: Bool?
    }

    static func run(_ table: Data) throws -> Data {
        let rows = try JSONDecoder().decode([Row].self, from: table)
        let results = rows.map { row -> Result in
            var result = Result(name: row.name)
            if var state = row.state, let event = row.event {
                result.effects = state.handle(event)
                result.state = state
            }
            if let original = row.original, let page = row.page {
                let isSamePage = page.isSamePage(as: original)
                result.samePage = isSamePage
                if let isSamePage, let isElementConfirmed = row.isElementConfirmed {
                    let similarity = NoteVisibility.similarity(isSamePage: isSamePage, isElementConfirmed: isElementConfirmed)
                    result.hides = similarity == 0
                    result.pictureDecides = similarity == nil
                }
            }
            if let distance = row.labelDistance {
                result.isOnLabel = AnnotationController.isOnLabel(distance: distance)
            }
            if let element = row.elementFrame, let window = row.windowFrame {
                let frame = CGRect(x: element[0], y: element[1], width: element[2], height: element[3])
                let clip = CGRect(x: window[0], y: window[1], width: window[2], height: window[3])
                result.labelShows = ElementTracker.visibleFrame(frame, clips: [clip]) != nil
            }
            if var note = row.note, let similarity = row.similarity {
                _ = note.update(similarity: similarity)
                result.note = note
            }
            return result
        }
        return try JSONEncoder().encode(results)
    }
}
