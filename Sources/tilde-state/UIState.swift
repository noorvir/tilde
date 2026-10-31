import Foundation

/// A state of Tilde's UI as the files in Tests/Contract/states describe it. See the README there.
struct UIState: Decodable {
    struct Session: Decodable {
        let client: String
        var isLocal: Bool?
    }
    struct Toast: Decodable {
        let failed: Int
        let action: String
        let oneApp: Bool
    }
    struct Settings: Decodable {
        let page: String
        var expandedAgents: [String]?
        var recording: Bool?
        var savedSessions: Bool?
    }

    let version: Int
    let surface: String
    var size: [Double]?
    var appearance: String?
    var session: Session?
    var notes: Int?
    var images: Bool?
    var sent: String?
    var paused: Bool?
    var autoPaused: Bool?
    var confirmation: String?
    var pauseNotice: String?
    var scoped: Bool?
    var pickingWindow: Bool?
    var clientWithIcon: String?
    var list: Bool?
    var hudInBrowser: Bool?
    var hover: Bool?
    var editing: Bool?
    var drawing: Bool?
    var drawingColor: String?
    var commentText: String?
    var preview: Int?
    var enlarged: String?
    var text: String?
    var snapped: Bool?
    var pageNotes: Bool?
    var toast: Toast?
    var settings: Settings?
}
