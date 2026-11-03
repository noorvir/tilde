import TildeInstaller
import TildeCore
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
        var rescaled: Bool?
        var original: PageIdentity?
        var page: PageIdentity?
        var isElementConfirmed: Bool?
        var elementFrame: [CGFloat]?
        var windowFrame: [CGFloat]?
        var labelDistance: CGFloat?
        var pushHost: String?
        var pushed: [String]?
        var failed: [String]?
        var sshConfig: String?
        var processList: String?
        var aliases: [AliasRow]?
        var installed: [String]?
        var nodeStatus: String?
        var appStatus: String?
        var deviceMade: [CGFloat]?
        var deviceNow: [CGFloat]?
        var point: [CGFloat]?
        var foundOnMachine: [String]?
        var onThisMac: [String]?
        var isReachable: Bool?
        var hasFailed: Bool?
    }

    struct AliasRow: Decodable {
        let host: String
        var machineName: String?
        var address: String?
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
        var hostIsValid: Bool?
        var confirmation: String?
        var hosts: [String]?
        var machines: [[String]]?
        var dot: String?
        var setup: String?
        var movedTo: [Int]?
        var isDevice: Bool?
        var reachable: String?
        var link: String?
        var chosen: [String]?
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
            if let host = row.pushHost {
                result.hostIsValid = RemotePush.isValid(host: host)
            }
            if let pushed = row.pushed, let failed = row.failed {
                result.confirmation = RemotePush.confirmation(pushed: pushed, failed: failed)
            }
            if let found = row.foundOnMachine, let mac = row.onThisMac {
                result.chosen = NodeSetup.chosen(found: found.compactMap { Harness(rawValue: $0) }, onThisMac: mac.compactMap { Harness(rawValue: $0) })
                    .map(\.rawValue)
            }
            if let made = row.deviceMade, let now = row.deviceNow, let point = row.point {
                let old = CGRect(x: made[0], y: made[1], width: made[2], height: made[3])
                let new = CGRect(x: now[0], y: now[1], width: now[2], height: now[3])
                let moved = DeviceScreen.map(CGPoint(x: point[0], y: point[1]), from: old, to: new)
                result.movedTo = [Int(moved.x.rounded()), Int(moved.y.rounded())]
            }
            if let made = row.deviceMade, let window = row.windowFrame, row.point == nil {
                result.isDevice = DeviceScreen.isDeviceShaped(
                    CGRect(x: made[0], y: made[1], width: made[2], height: made[3]),
                    in: CGRect(x: window[0], y: window[1], width: window[2], height: window[3])
                )
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
                let machine = NodeSetup.Row(host: "box", status: NodeSetup.Status(name: status), isReachable: row.isReachable, hasFailed: row.hasFailed ?? false)
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
                result.isOnLabel = AnnotationController.isOnLabel(distance: distance)
            }
            if let element = row.elementFrame, let window = row.windowFrame {
                let frame = CGRect(x: element[0], y: element[1], width: element[2], height: element[3])
                let clip = CGRect(x: window[0], y: window[1], width: window[2], height: window[3])
                result.labelShows = ElementTracker.visibleFrame(frame, clips: [clip]) != nil
            }
            if var note = row.note, let similarity = row.similarity {
                _ = note.update(similarity: similarity, isRescaled: row.rescaled ?? false)
                result.note = note
            }
            return result
        }
        return try JSONEncoder().encode(results)
    }
}
