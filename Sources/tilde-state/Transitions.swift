import TildeInstaller
import TildeCore
@testable import TildeUI
import AppKit

/// Runs the rows of a transition table through the real rules.
@MainActor
enum Transitions {
    /// A row's flow with its facts, which the row writes as one object.
    struct FlowState: Codable {
        var flow: SessionFlow
        var facts: SessionFlow.Facts

        init(from decoder: Decoder) throws {
            flow = try SessionFlow(from: decoder)
            facts = try SessionFlow.Facts(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try flow.encode(to: encoder)
            try facts.encode(to: encoder)
        }
    }

    struct Row: Decodable {
        let name: String
        var state: FlowState?
        var event: SessionFlow.Event?
        /// A single key pressed while Tilde has the keyboard, by its default name, such as "R".
        var key: String?
        var note: NoteVisibility?
        var similarity: Double?
        var original: PageIdentity?
        var page: PageIdentity?
        var isElementConfirmed: Bool?
        var elementFrame: [CGFloat]?
        var windowFrame: [CGFloat]?
        var labelDistance: CGFloat?
        var pushHost: String?
        var failed: [String]?
        var sshConfig: String?
        var processList: String?
        var aliases: [AliasRow]?
        var installed: [String]?
        var nodeStatus: String?
        var appStatus: String?
        var foundOnMachine: [String]?
        var onThisMac: [String]?
        var isReachable: Bool?
        var hasFailed: Bool?
        var isWorking: Bool?
        var keys: [KeyEvent]?
        var watching: [String]?
        var tapped: String?
        var startKey: String?
        var pauseKey: String?
        var isPaused: Bool?
        var hasSession: Bool?
        var dropCentre: [CGFloat]?
        var homeCentre: [CGFloat]?
        var visibleFrame: [CGFloat]?
        var previewSize: [CGFloat]?
        var room: [CGFloat]?
    }

    /// A modifier going down or up (`down` is every modifier held after it), or, with `other`,
    /// another key or a click.
    struct KeyEvent: Decodable {
        var down: [String]?
        var other: Bool?
        let at: TimeInterval
    }

    struct AliasRow: Decodable {
        let host: String
        var machineName: String?
        var address: String?
    }

    struct Result: Encodable {
        let name: String
        var state: FlowState?
        var effects: [SessionFlow.Effect]?
        /// The action the key chose, such as "rectangleTool"; nil when it is none.
        var keyAction: String?
        var note: NoteVisibility?
        var samePage: Bool?
        var hides: Bool?
        var pictureDecides: Bool?
        var labelShows: Bool?
        var isOnLabel: Bool?
        var hostIsValid: Bool?
        var confirmation: String?
        var hosts: [String]?
        var machines: [[String]]?
        var dot: String?
        var setup: String?
        var reachable: String?
        var link: String?
        var chosen: [String]?
        var doubleTaps: [String]?
        var doubleTapAction: String?
        var snapsHome: Bool?
        var browserFrame: [CGFloat]?
        var previewSize: [CGFloat]?
    }

    /// "ok", the button's title, "error: <button>", or the grey text.
    private static func name(_ state: SetupState) -> String {
        switch state {
        case .ok: "ok"
        case .action(let title): title
        case .error(_, let title): "error: \(title)"
        case .notApplicable(let text): text
        }
    }

    static func run(_ table: Data) throws -> Data {
        let rows = try JSONDecoder().decode([Row].self, from: table)
        let results = rows.map { row -> Result in
            var result = Result(name: row.name)
            if var state = row.state, let event = row.event {
                result.effects = state.flow.handle(event, state.facts)
                result.state = state
            }
            if var state = row.state, let key = row.key {
                let shortcuts = ShortcutStore(defaults: UserDefaults(suiteName: "tilde-state-keys") ?? .standard)
                let code = ShortcutStore.Action.allCases.lazy.compactMap { $0.defaultShortcut?.combo }.first { $0.key == key }?.keyCode
                let action = code.flatMap { shortcuts.inAppAction(keyCode: UInt16($0), modifiers: [], isDrawing: state.flow.session?.isDrawing ?? false) }
                result.keyAction = action?.rawValue
                result.effects = action.map { state.flow.events(forKey: $0).flatMap { state.flow.handle($0, state.facts) } } ?? []
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
            if let host = row.pushHost {
                result.hostIsValid = RemotePush.isValid(host: host)
            }
            if let failed = row.failed {
                result.confirmation = RemotePush.failure(failed)
            }
            if let found = row.foundOnMachine, let mac = row.onThisMac {
                result.chosen = NodeSetup.chosen(found: found.compactMap { Harness(rawValue: $0) }, onThisMac: mac.compactMap { Harness(rawValue: $0) })
                    .map(\.rawValue)
            }
            if let status = row.appStatus {
                let value: InstallStatus = switch status {
                case "installed": .installed
                case "failed": .failed("not JSON")
                case "absent": .notFound
                default: .notInstalled
                }
                result.setup = Self.name(SetupState.of(value))
            }
            if let status = row.nodeStatus {
                result.dot = NodeSetup.Dot(status: NodeSetup.Status(name: status), isReachable: row.isReachable, hasFailed: row.hasFailed ?? false).name
                let machine = NodeSetup.Row(host: "box", status: NodeSetup.Status(name: status), isReachable: row.isReachable, hasFailed: row.hasFailed ?? false, isWorking: row.isWorking ?? false)
                result.reachable = Self.name(NodeSetup.reachableState(of: machine))
                result.link = Self.name(NodeSetup.linkState(of: machine))
            }
            if let aliases = row.aliases {
                let found = aliases.map { NodeDiscovery.Alias(host: $0.host, machineName: $0.machineName, address: $0.address) }
                result.machines = NodeDiscovery.machines(found, installed: row.installed ?? [])
            }
            if let list = row.processList {
                result.hosts = NodeDiscovery.sshHosts(inProcessList: list)
            }
            if let config = row.sshConfig {
                result.hosts = RemotePush.sshHosts(inConfig: config)
            }
            if let distance = row.labelDistance {
                result.isOnLabel = NoteTracker.isOnLabel(distance: distance)
            }
            if let element = row.elementFrame, let window = row.windowFrame {
                let frame = CGRect(x: element[0], y: element[1], width: element[2], height: element[3])
                let clip = CGRect(x: window[0], y: window[1], width: window[2], height: window[3])
                result.labelShows = ElementTracker.visibleFrame(frame, clips: [clip]) != nil
            }
            if let events = row.keys {
                var detector = DoubleTapDetector()
                let watching = Set((row.watching ?? []).compactMap(DoubleTapKey.init(rawValue:)))
                result.doubleTaps = events.compactMap { event in
                    let flags = (event.down ?? []).compactMap(DoubleTapKey.init(rawValue:)).reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.flag) }
                    return detector.handle(isFlagsChanged: event.other != true, flags: flags, at: event.at, watching: watching)?.rawValue
                }
            }
            if let tapped = row.tapped.flatMap(DoubleTapKey.init(rawValue:)) {
                let action = AnnotationController.doubleTapAction(
                    for: tapped, startKey: row.startKey.flatMap(DoubleTapKey.init(rawValue:)), pauseKey: row.pauseKey.flatMap(DoubleTapKey.init(rawValue:)),
                    isPaused: row.isPaused ?? false, hasSession: row.hasSession ?? false
                )
                result.doubleTapAction = action.map { "\($0)" } ?? "nothing"
            }
            if let drop = row.dropCentre, let home = row.homeCentre {
                result.snapsHome = SnapDrag.snapsHome(NSPoint(x: drop[0], y: drop[1]), home: NSPoint(x: home[0], y: home[1]))
            }
            if let visible = row.visibleFrame {
                let frame = BrowserController.defaultFrame(in: CGRect(x: visible[0], y: visible[1], width: visible[2], height: visible[3]))
                result.browserFrame = [frame.minX, frame.minY, frame.width, frame.height]
            }
            if let size = row.previewSize, let room = row.room {
                let fit = fitted(CGSize(width: size[0], height: size[1]), min: PreviewPanel.minSize, max: CGSize(width: room[0], height: room[1]))
                result.previewSize = [fit.width, fit.height]
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
