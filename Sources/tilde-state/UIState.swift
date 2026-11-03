import Foundation

/// A state of Tilde's UI as the files in Tests/Contract/states describe it. See the README there.
struct UIState: Decodable {
    struct Session: Decodable {
        let client: String
        var node: String?
        var isLocal: Bool?
    }
    struct Toast: Decodable {
        let failed: Int
        let action: String
        let oneApp: Bool
    }
    struct NodeState: Decodable {
        let host: String
        let status: String
        var isReachable: Bool?
        var hasFailed: Bool?
        var agents: [String]?
        var agentsOff: [String]?
    }

    struct Settings: Decodable {
        let page: String
        var expandedAgents: [String]?
        var recording: Bool?
        var savedSessions: Bool?
        var nodes: [NodeState]?
        /// The machine whose page is open.
        var machine: String?
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
    /// The remote machine's status dot: green, yellow, grey or red.
    var machineDot: String?
    var list: Bool?
    var hudInBrowser: Bool?
    var hover: Bool?
    var editing: Bool?
    var drawing: Bool?
    var sentStatus: String?
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
