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
        var isProtected: Bool?
        var needsMove: Bool?
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
    /// Send was pressed and the report is being made.
    var sending: Bool?
    /// A short note in the HUD's subtitle, such as "Could not start recording".
    var notice: String?
    /// The first note is a stopped recording of the Safari window, 12 s long.
    var clip: Bool?
    /// The source picker while it lists ("listing"), after it failed ("failed"), with nothing
    /// to offer ("empty"), while it takes the tiles' pictures ("picturing"), or when it could not
    /// take them ("noPictures").
    var pickerPhase: String?
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
    /// The HUD's recording mode: ready, starting, recording, paused or finishing.
    var recording: String?
    /// What clips record when not scoped to a window: "display" or "phone".
    var source: String?
    /// The source picker's page when it is open in full while choosing (`pickingWindow`):
    /// "screens", "windows", or "app" for Safari's windows. Without it the picker is its
    /// "Use window picker" button.
    var sourcePicker: String?
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
