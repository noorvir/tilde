import AppKit
import TildeCore
import TildeInstaller
import os

/// The machines that Tilde can be installed on, and a link to each machine that has it: a tunnel
/// from the node to this Mac, so that its agents reach Tilde.
@MainActor
final class NodeSetup: ObservableObject {
    enum Status: Equatable {
        case notInstalled, installing, linked, unreachable

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
            case .installing: "Working on it"
            case .linked: "Installed and linked"
            case .unreachable: "Installed, not reachable"
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let host: String
        var status: Status
        var note: String?

        var id: String { host }
    }

    @Published private(set) var rows: [Row] = []
    private let log = Logger(subsystem: "dev.tilde.app", category: "nodes")
    private let store: NodeStore
    private let nodePort: UInt16
    private let remotePort: UInt16
    private var links: [String: Process] = [:]
    private var isLinking = false

    /// `remotePort` is not Tilde's own port: the node may run a Tilde of its own.
    init(store: NodeStore = NodeStore(), nodePort: UInt16, remotePort: UInt16 = 7319) {
        self.store = store
        self.nodePort = nodePort
        self.remotePort = remotePort
    }

    /// For the contract: rows with no machines behind them.
    func setRowsForTesting(_ rows: [Row]) {
        self.rows = rows
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
        Task {
            let found = await Task.detached { NodeDiscovery.runningHosts() + RemotePush.sshHosts() }.value
            let installed = store.load().map(\.host)
            var hosts = installed
            for host in found where !hosts.contains(host) {
                hosts.append(host)
            }
            rows = hosts.map { host in
                if let row = rows.first(where: { $0.host == host }) {
                    return row
                }
                let isLinked = links[host] != nil
                let status: Status = installed.contains(host) ? (isLinked ? .linked : .unreachable) : .notInstalled
                return Row(host: host, status: status)
            }
        }
    }

    func install(_ host: String) {
        update(host, status: .installing, note: nil)
        let token = UUID().uuidString + UUID().uuidString
        let url = "http://127.0.0.1:\(remotePort)/mcp"
        Task {
            let result = await Task.detached { () -> Result<NodeInstaller.Report, Error> in
                Result { try Self.installer(host, url: url).install(token: token) }
            }.value
            switch result {
            case .success(let report) where report.changed.isEmpty && !report.skipped.isEmpty:
                update(host, status: .notInstalled, note: report.skipped.joined(separator: ". "))
            case .success(let report):
                var nodes = store.load().filter { $0.host != host }
                nodes.append(Node(host: host, token: token))
                try? store.save(nodes)
                log.notice("installed on \(host, privacy: .public): \(report.changed, privacy: .public), skipped \(report.skipped, privacy: .public)")
                update(host, status: .unreachable, note: report.skipped.isEmpty ? nil : report.skipped.joined(separator: ". "))
                link(host)
            case .failure(let error):
                log.error("could not install on \(host, privacy: .public): \(String(describing: error), privacy: .public)")
                update(host, status: .notInstalled, note: "Could not connect by ssh")
            }
        }
    }

    func uninstall(_ host: String) {
        update(host, status: .installing, note: nil)
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

    private func update(_ host: String, status: Status, note: String?) {
        if let index = rows.firstIndex(where: { $0.host == host }) {
            rows[index].status = status
            rows[index].note = note
        } else {
            rows.append(Row(host: host, status: status, note: note))
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
        Task {
            try? await Task.sleep(for: .seconds(min(30, 2 * (next + 1))))
            link(host, attempt: next)
        }
    }
}
