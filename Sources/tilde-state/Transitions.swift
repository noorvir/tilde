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
    }

    struct Result: Encodable {
        let name: String
        var state: SessionFlow?
        var effects: [SessionFlow.Effect]?
        var note: NoteVisibility?
        var samePage: Bool?
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
                result.samePage = page.isSamePage(as: original)
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
