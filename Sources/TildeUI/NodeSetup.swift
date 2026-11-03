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

    /// Whether the machine answers over ssh.
    nonisolated static func reachableState(of row: Row) -> SetupState {
        switch row.isReachable {
        case true?: .ok
        case false?: .error(reason: "It does not answer over ssh. Check that \"ssh \(row.host)\" works in Terminal", action: "Check Again")
        case nil: .notApplicable("Checking")
        }
    }

    /// Whether the machine's agents can reach this Mac.
    nonisolated static func linkState(of row: Row) -> SetupState {
        if row.status == .linked {
            return .ok
        }
        if row.hasFailed {
            return .error(reason: row.detail ?? row.note ?? "The install or the link failed", action: row.status.isInstalled ? "Reconnect" : "Retry")
        }
        if row.status.isInstalled {
            return .action("Reconnect")
        }
        return .notApplicable("Not installed")
    }

    /// Starts the link to a machine again.
    func reconnect(_ host: String) {
        links.removeValue(forKey: host)?.terminate()
        link(host)
    }

    /// The apps that a machine's Install sets up: those on this Mac, or all when none are.
    nonisolated static func chosen(found: [Harness], onThisMac: [Harness]) -> [Harness] {
        onThisMac.isEmpty ? found : found.filter(onThisMac.contains)
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
    /// Each machine's apps, once its page has read them.
    @Published private(set) var setups: [String: AgentSetup] = [:]
    /// This Mac's setup, for the icons and the apps that are switched on.
    weak var localSetup: AgentSetup?
    /// A machine's token from its first install on; a machine with none installed has a new one.
    private var pendingTokens: [String: String] = [:]
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

    /// Reads what a machine has, for its page, once.
    func loadSetup(_ host: String) async {
        guard setups[host] == nil, !isFixed else {
            return
        }

        let token = token(for: host)
        let url = remoteURL
        guard let installer = await Task.detached(operation: { try? Self.installer(host, url: url, token: token) }).value else {
            update(host, status: rows.first { $0.host == host }?.status ?? .notInstalled, note: "Could not connect by ssh")
            setFailed(host, true)
            return
        }

        let setup = AgentSetup(installer: installer, nodes: self, isRemote: true, iconSource: localSetup)
        setup.onChange = { [weak self, weak setup] in
            if let setup {
                self?.agentsChanged(host, setup)
            }
        }
        await setup.load()
        setups[host] = setup
    }

    /// For the contract: a machine's page without the machine.
    func setSetupForTesting(_ setup: AgentSetup, for host: String) {
        setups[host] = setup
    }

    /// Installs Tilde on the machine's apps that are switched on on this Mac, the same way as on
    /// this Mac; with none switched on, on all of them.
    func install(_ host: String) {
        update(host, status: .installing, note: nil)
        setFailed(host, false)
        Task {
            await loadSetup(host)
            guard let setup = setups[host] else {
                update(host, status: .notInstalled, note: "Could not connect by ssh")
                return
            }
            let found = setup.foundRows.map(\.harness)
            let onThisMac = localSetup.map { local in AgentSetup.rows.filter { local.status(of: $0) == .installed }.map(\.harness) } ?? []
            let chosen = Self.chosen(found: found, onThisMac: onThisMac)
            if chosen.isEmpty {
                update(host, status: .notInstalled, note: "No agent apps found")
                return
            }
            setup.apply(chosen, action: .installed)
        }
    }

    /// Removes Tilde from all of the machine's apps, the same way as on this Mac.
    func uninstall(_ host: String) {
        update(host, status: .removing, note: nil)
        guard let setup = setups[host] else {
            return
        }
        setup.apply(setup.foundRows.map(\.harness), action: .removed)
    }

    /// A machine with Tilde in any app is linked; with none, its link goes.
    private func agentsChanged(_ host: String, _ setup: AgentSetup) {
        let isInstalled = AgentSetup.rows.contains { setup.status(of: $0) == .installed }
        let isKnown = store.load().contains { $0.host == host }
        if isInstalled, !isKnown {
            try? store.save(store.load() + [Node(host: host, token: token(for: host))])
            log.notice("installed on \(host, privacy: .public)")
            update(host, status: .unreachable, note: nil)
            link(host)
        } else if !isInstalled {
            if isKnown {
                try? store.save(store.load().filter { $0.host != host })
            }
            links.removeValue(forKey: host)?.terminate()
            update(host, status: .notInstalled, note: nil)
        } else if rows.first(where: { $0.host == host })?.status.isWorking == true {
            update(host, status: links[host] == nil ? .unreachable : .linked, note: nil)
        }
    }

    private func token(for host: String) -> String {
        if let token = store.load().first(where: { $0.host == host })?.token ?? pendingTokens[host] {
            return token
        }
        let token = UUID().uuidString + UUID().uuidString
        pendingTokens[host] = token
        return token
    }

    private var remoteURL: String {
        "http://127.0.0.1:\(remotePort)/mcp"
    }

    nonisolated private static func installer(_ host: String, url: String, token: String) throws -> Installer {
        try Installer.remote(mcpURL: url, authorization: "Bearer \(token)") { command, input in
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
