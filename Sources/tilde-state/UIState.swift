import Foundation
import TildeInstaller
@testable import TildeUI

/// A state of Tilde's UI as the files in Tests/Contract/states describe it.
/// A key or a value that it does not know is an error, so a typo cannot record another picture.
struct UIState: Decodable {
    enum Surface: String, Decodable {
        case toast, settings, restorePrompt, tooltip, outline, notesPanel, toolbar, hud, comment, preview, overlay, canvas
    }
    enum Appearance: String, Decodable {
        case light, dark
    }
    enum PickerPhase: String, Decodable {
        case listing, failed, empty, picturing, noPictures
    }
    enum PauseNotice: String, Decodable {
        case escape, otherApp
    }
    enum Recording: String, Decodable {
        case ready, starting, recording, paused, finishing
    }
    enum Source: String, Decodable {
        case display, phone
    }
    enum SourcePicker: String, Decodable {
        case screens, windows, app
    }
    enum SentStatus: String, Decodable {
        case done, failed
    }
    /// The chip of the first component on the canvas: shown, or with its borders menu open.
    enum Chip: String, Decodable {
        case shown, borders
    }
    enum Enlarged: String, Decodable {
        case closeUp, context
    }
    struct Session: Decodable {
        let client: String
        var node: String?
        var isLocal: Bool?
    }
    struct Toast: Decodable {
        enum Action: String, Decodable {
            case installed, removed
        }

        let failed: Int
        let action: Action
        let oneApp: Bool
    }
    struct NodeState: Decodable {
        enum Status: String, Decodable {
            case linked, unreachable, notInstalled
        }

        let host: String
        let status: Status
        var isReachable: Bool?
        var hasFailed: Bool?
        var isProtected: Bool?
        var needsMove: Bool?
        var isWorking: Bool?
        var agents: [Harness]?
        var agentsOff: [Harness]?
    }

    /// The look of wireframe components; what is missing is the default.
    struct Look: Decodable {
        var style: WireframeLook.Style?
        var fill: Double?
        var blur: Double?
        var fade: Double?

        var value: WireframeLook {
            let defaults = WireframeLook()
            return WireframeLook(style: style ?? defaults.style, fill: fill ?? defaults.fill, blur: blur ?? defaults.blur, fade: fade ?? defaults.fade)
        }
    }

    struct Settings: Decodable {
        enum Page: String, Decodable {
            case agents, general, shortcuts, history
        }

        let page: Page
        var expandedAgents: [String]?
        var recording: Bool?
        var savedSessions: Bool?
        var nodes: [NodeState]?
        /// The machine whose page is open.
        var machine: String?
    }

    let version: Int
    let surface: Surface
    var size: [Double]?
    var appearance: Appearance?
    var session: Session?
    var notes: Int?
    var images: Bool?
    var sent: String?
    /// Send was pressed and the report is being made.
    var sending: Bool?
    /// A short note in the HUD's subtitle, such as "Could not start recording".
    var notice: Notice?
    /// The first note is a stopped recording of the Safari window, 12 s long.
    var clip: Bool?
    /// The last note is a wireframe on the Safari window.
    var wireframeNote: Bool?
    /// The source picker while it lists ("listing"), after it failed ("failed"), with nothing
    /// to offer ("empty"), while it takes the tiles' pictures ("picturing"), or when it could not
    /// take them ("noPictures").
    var pickerPhase: PickerPhase?
    var paused: Bool?
    var autoPaused: Bool?
    var confirmation: SessionFlow.Question?
    var pauseNotice: PauseNotice?
    /// The hint under the HUD that offers to open the page of another browser in Tilde's.
    var browserAccessory: Bool?
    var scoped: Bool?
    var pickingWindow: Bool?
    var clientWithIcon: String?
    /// The remote machine's status dot: green, yellow, grey or red.
    var machineDot: NodeSetup.Dot?
    var list: Bool?
    var hudInBrowser: Bool?
    var hover: Bool?
    var editing: Bool?
    var drawing: Bool?
    /// Wireframe mode, in place of Draw mode.
    var wireframe: Bool?
    /// The tool of Draw mode or Wireframe mode, such as "ellipse" or "table"; "none" after
    /// Esc put the tool down.
    var tool: String?
    /// The HUD's recording mode: ready, starting, recording, paused or finishing.
    var recording: Recording?
    /// What clips record when not scoped to a window: "display" or "phone".
    var source: Source?
    /// The source picker's page when it is open in full while choosing (`pickingWindow`):
    /// "screens", "windows", or "app" for Safari's windows. Without it the picker is its
    /// "Use window picker" button.
    var sourcePicker: SourcePicker?
    var sentStatus: SentStatus?
    var drawingColor: String?
    var commentText: String?
    var preview: Int?
    var enlarged: Enlarged?
    var text: String?
    /// The key hints after a tooltip's text, such as ["⌃⌃", "Space"].
    var keys: [String]?
    var snapped: Bool?
    var pageNotes: Bool?
    var toast: Toast?
    var settings: Settings?
    var look: Look?
    var chip: Chip?

    init(file: URL) throws {
        let data = try Data(contentsOf: file)
        self = try JSONDecoder().decode(UIState.self, from: data)
        let unknown = Self.unknownKeys(in: try JSONSerialization.jsonObject(with: data), of: self, at: "")
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown \(unknown.sorted().joined(separator: ", "))"))
        }
    }

    /// The keys of a JSON value that the decoded value has no field for, with their paths.
    private static func unknownKeys(in json: Any, of value: Any, at path: String) -> [String] {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else {
                return []
            }
            return unknownKeys(in: json, of: wrapped, at: path)
        }
        if let items = json as? [Any] {
            return zip(items, mirror.children).flatMap { unknownKeys(in: $0, of: $1.value, at: path) }
        }
        guard let object = json as? [String: Any], mirror.displayStyle == .struct else {
            return []
        }

        var fields: [String: Any] = [:]
        for child in mirror.children {
            if let name = child.label {
                fields[name] = child.value
            }
        }
        return object.flatMap { key, item -> [String] in
            guard let field = fields[key] else {
                return [path + key]
            }
            return unknownKeys(in: item, of: field, at: path + key + ".")
        }
    }
}

extension Notice: Decodable {}
extension NodeSetup.Dot: Decodable {}
extension Harness: Decodable {}
extension WireframeLook.Style: Decodable {}
