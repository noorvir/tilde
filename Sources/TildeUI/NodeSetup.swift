import AppKit
import TildeCore
import TildeInstaller
import os

/// The machines that Tilde can be installed on, and a link to each machine that has it: a tunnel
/// from the node to this Mac, so that its agents reach Tilde.
@MainActor
final class NodeSetup: ObservableObject {
    enum Status: Equatable {
        case notInstalled, installing, removing, linked, unreachable

        var isInstalled: Bool {
            self == .linked || self == .unreachable || self == .removing
        }

        var isWorking: Bool {
            self == .installing || self == .removing
        }

        init(name: String) {
            switch name {
            case "linked": self = .linked
            case "unreachable": self = .unreachable
            case "installing": self = .installing
            default: self = .notInstalled
            }
        }

        var text: String {
            switch self {
            case .notInstalled: "Not installed"
            case .installing, .removing: "Working on it"
            case .linked: "Installed and linked"
            case .unreachable: "Installed, not linked"
            }
        }
    }

    enum Dot: Equatable {
        case green, yellow, grey, red

        init(status: Status, isReachable: Bool?, hasFailed: Bool) {
            if status == .linked {
                self = .green
            } else if isReachable == false {
                self = .grey
            } else if hasFailed {
                self = .red
            } else {
                self = .yellow
            }
        }

        var name: String {
            switch self {
            case .green: "green"
            case .yellow: "yellow"
            case .grey: "grey"
            case .red: "red"
            }
        }

        var reason: String {
            switch self {
            case .green: "Tilde is installed here, and the link is up"
            case .yellow: "Answers over ssh, but has no link yet"
            case .grey: "Does not answer over ssh"
            case .red: "Answers over ssh, but the install or the link failed"
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let host: String
        var status: Status
        var note: String?
        /// The reason behind the note.
        var detail: String?
        /// The machine's other names in the ssh config.
        var aliases: [String] = []
        /// Whether it answered over ssh; nil before the first check.
        var isReachable: Bool?
        /// An install or a tunnel failed on a machine that answers.
        var hasFailed = false

        var dot: Dot {
            Dot(status: status, isReachable: isReachable, hasFailed: hasFailed)
        }

        var id: String { host }
    }

    @Published private(set) var rows: [Row] = []
    private let log = Logger(subsystem: "dev.tilde.app", category: "nodes")
    private let store: NodeStore
    private let nodePort: UInt16
    private let remotePort: UInt16
    private var links: [String: Process] = [:]
    private var isLinking = false
    private var isFixed = false

    /// `remotePort` is not Tilde's own port: the node may run a Tilde of its own.
    init(store: NodeStore = NodeStore(), nodePort: UInt16, remotePort: UInt16 = 7319) {
        self.store = store
        self.nodePort = nodePort
        self.remotePort = remotePort
    }

    /// For the contract: rows with no machines behind them.
    func setRowsForTesting(_ rows: [Row]) {
        self.rows = rows
        isFixed = true
    }

    /// Links the installed nodes, for as long as Tilde runs.
    func startLinks() {
        isLinking = true
        store.load().forEach { link($0.host) }
    }

    func stopLinks() {
        isLinking = false
        links.values.forEach { $0.terminate() }
        links = [:]
    }

    /// Reads the candidates again: installed nodes, running ssh connections and the ssh config.
    func refresh() {
        guard !isFixed else {
            return
        }

        Task {
            let installed = store.load().map(\.host)
            let result = await Task.detached {
                var hosts = installed
                for host in NodeDiscovery.runningHosts() + RemotePush.sshHosts() where !hosts.contains(host) {
                    hosts.append(host)
                }
                let aliases = await withTaskGroup(of: NodeDiscovery.Alias.self) { group in
                    for host in hosts {
                        group.addTask {
                            NodeDiscovery.Alias(host: host, machineName: NodeDiscovery.machineName(of: host), address: NodeDiscovery.address(ofAlias: host))
                        }
                    }
                    return await group.reduce(into: [NodeDiscovery.Alias]()) { $0.append($1) }
                }
                let found = hosts.compactMap { host in aliases.first { $0.host == host } }
                return (NodeDiscovery.machines(found, installed: installed), found.filter { $0.machineName != nil }.map(\.host))
            }.value
            let (machines, reachable) = result
            log.notice("machines: \(machines, privacy: .public)")

            rows = machines.map { names in
                let host = names[0]
                var row = rows.first { $0.host == host } ?? Row(host: host, status: installed.contains(host) ? (links[host] != nil ? .linked : .unreachable) : .notInstalled)
                row.aliases = Array(names.dropFirst())
                row.isReachable = reachable.contains { names.contains($0) }
                return row
            }
        }
    }

    func install(_ host: String) {
        update(host, status: .installing, note: nil)
        setFailed(host, false)
        let token = UUID().uuidString + UUID().uuidString
        let url = "http://127.0.0.1:\(remotePort)/mcp"
        Task {
            let result = await Task.detached { () -> Result<NodeInstaller.Report, Error> in
                Result { try Self.installer(host, url: url).install(token: token) }
            }.value
            switch result {
            case .success(let report) where report.changed.isEmpty && !report.skipped.isEmpty:
                update(host, status: .notInstalled, note: report.skipped.joined(separator: ". "), detail: report.details.joined(separator: " "))
            case .success(let report):
                var nodes = store.load().filter { $0.host != host }
                nodes.append(Node(host: host, token: token))
                try? store.save(nodes)
                log.notice("installed on \(host, privacy: .public): \(report.changed, privacy: .public), skipped \(report.skipped, privacy: .public)")
                update(host, status: .unreachable, note: report.skipped.isEmpty ? nil : report.skipped.joined(separator: ". "), detail: report.details.joined(separator: " "))
                link(host)
            case .failure(let error):
                log.error("could not install on \(host, privacy: .public): \(String(describing: error), privacy: .public)")
                update(host, status: .notInstalled, note: "Install failed", detail: String(describing: error))
                setFailed(host, true)
            }
        }
    }

    func uninstall(_ host: String) {
        update(host, status: .removing, note: nil)
        links.removeValue(forKey: host)?.terminate()
        let url = "http://127.0.0.1:\(remotePort)/mcp"
        Task {
            let result = await Task.detached { () -> Result<NodeInstaller.Report, Error> in
                Result { try Self.installer(host, url: url).uninstall() }
            }.value
            switch result {
            case .success:
                try? store.save(store.load().filter { $0.host != host })
                update(host, status: .notInstalled, note: nil)
            case .failure(let error):
                log.error("could not uninstall on \(host, privacy: .public): \(String(describing: error), privacy: .public)")
                update(host, status: .unreachable, note: "Could not connect by ssh")
                link(host)
            }
        }
    }

    nonisolated private static func installer(_ host: String, url: String) -> NodeInstaller {
        NodeInstaller(mcpURL: url) { command, input in
            try RemotePush.runOnNode(host, command: command, input: input)
        }
    }

    private func update(_ host: String, status: Status, note: String?, detail: String? = nil) {
        if let index = rows.firstIndex(where: { $0.host == host }) {
            rows[index].status = status
            rows[index].note = note
            rows[index].detail = detail ?? (note == nil ? nil : rows[index].detail)
        } else {
            rows.append(Row(host: host, status: status, note: note, detail: detail))
        }
    }

    private func setFailed(_ host: String, _ hasFailed: Bool) {
        if let index = rows.firstIndex(where: { $0.host == host }) {
            rows[index].hasFailed = hasFailed
        }
    }

    /// One tunnel, started again whenever it ends: sleep and network changes end it.
    private func link(_ host: String, attempt: Int = 0) {
        guard links[host] == nil, RemotePush.isValid(host: host) else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
            "-o", "ExitOnForwardFailure=yes", "-R", "\(remotePort):127.0.0.1:\(nodePort)", host,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        process.terminationHandler = { [weak self] ended in
            let lived = Date().timeIntervalSince(started)
            Task { @MainActor in
                self?.linkEnded(host, process: ended, lived: lived, attempt: attempt)
            }
        }
        guard (try? process.run()) != nil else {
            return
        }

        links[host] = process
        // An ssh that still runs after the time to connect holds its tunnel: a failed forward ends it.
        Task {
            try? await Task.sleep(for: .seconds(3))
            if links[host] === process, process.isRunning {
                update(host, status: .linked, note: rows.first { $0.host == host }?.note)
                setFailed(host, false)
            }
        }
    }

    private func linkEnded(_ host: String, process: Process, lived: TimeInterval, attempt: Int) {
        guard links[host] === process else {
            return
        }

        links[host] = nil
        update(host, status: .unreachable, note: rows.first { $0.host == host }?.note)
        guard isLinking, store.load().contains(where: { $0.host == host }) else {
            return
        }

        let next = lived > 30 ? 0 : attempt + 1
        setFailed(host, next >= 2)
        Task {
            try? await Task.sleep(for: .seconds(min(30, 2 * (next + 1))))
            link(host, attempt: next)
        }
    }
}
