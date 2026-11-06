import AppKit
import TildeCore
import TildeInstaller
import os

/// The machines that Tilde can be installed on, and a link to each machine that has it: an ssh
/// tunnel from the node's socket, which its agents reach through `tproxy`, to this Mac's
/// socket for that node. A node type with no `tproxy` file is linked by a port instead.
@MainActor
final class NodeSetup: ObservableObject {
    /// The machine's link. A change under way leaves it as it is: see `Row.isWorking`.
    enum Status: Equatable {
        case notInstalled, linked, unreachable

        var isInstalled: Bool {
            self == .linked || self == .unreachable
        }

        init(name: String) {
            switch name {
            case "linked": self = .linked
            case "unreachable": self = .unreachable
            default: self = .notInstalled
            }
        }

        var text: String {
            switch self {
            case .notInstalled: "Not installed"
            case .linked: "Installed and linked"
            case .unreachable: "Installed, not linked"
            }
        }
    }

    enum Dot: String, Equatable {
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
        /// Linked by its socket. A node type with no `tproxy` file is linked by a port,
        /// which every user on the node can reach.
        var isProtected = true
        /// Linked by the port, as installed by an older Tilde, though its type has `tproxy`: one
        /// Install moves all its apps to the socket.
        var needsMove = false
        /// A change is under way: install, remove, the move, or an app's switch.
        var isWorking = false

        var text: String {
            isWorking ? "Working on it" : status.text
        }

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
    /// Serves the nodes' sockets; links start once it is set.
    var mcp: MCPServer?
    private var links: [String: Process] = [:]
    /// Nodes whose `tproxy` is being checked before their tunnel starts.
    private var preparing: Set<String> = []
    private var sockets: [String: NodeSocket] = [:]
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
        sockets.values.forEach { $0.stop() }
        sockets = [:]
    }

    /// Reads the candidates again: installed nodes, running ssh connections and the ssh config.
    func refresh() {
        guard !isFixed else {
            return
        }

        Task {
            let nodes = store.load()
            let installed = nodes.map(\.host)
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
                row.isProtected = nodes.first { $0.host == host }.map { $0.socket != nil } ?? true
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
        // A node on the port keeps its URL entries on its page until it moves.
        let isOnPort = store.load().first { $0.host == host }.map { $0.socket == nil } ?? false
        let installer: Installer
        let hasProxy: Bool
        do {
            (installer, hasProxy) = try await Task.detached { try await Self.installer(host, url: url, token: token, onPort: isOnPort) }.value
        } catch {
            let note = error is TProxy.Failure ? "Could not get tproxy for it" : "Could not connect by ssh"
            update(host, note: note, detail: String(describing: error))
            setFailed(host, true)
            return
        }

        if let index = rows.firstIndex(where: { $0.host == host }) {
            rows[index].needsMove = isOnPort && hasProxy
        }
        await show(host, installer)
    }

    private func show(_ host: String, _ installer: Installer) async {
        let setup = AgentSetup(installer: installer, nodes: self, isRemote: true, iconSource: localSetup)
        // A page that the move replaced may still finish a change: it no longer speaks for the machine.
        setup.onChange = { [weak self, weak setup] in
            if let self, let setup, setups[host] === setup {
                agentsChanged(host, setup)
            }
        }
        await setup.load()
        setups[host] = setup
    }

    /// Moves a node from the port to its socket: every app with Tilde gets its stdio entry in
    /// one Install, and then the link changes. If any app fails, all of them get their URL
    /// entries back and the node stays on the port, so no app is left on a port that stops.
    private func moveToSocket(_ host: String) {
        guard let old = setups[host] else {
            return
        }

        update(host, note: nil)
        setWorking(host, true)
        let installed = old.foundRows.filter { old.status(of: $0) == .installed }.map(\.harness)
        let token = token(for: host)
        let url = remoteURL
        Task {
            let result = await Task.detached { () throws -> Installer? in
                let (new, _) = try await Self.installer(host, url: url, token: token, onPort: false)
                return Self.move(installed, from: old.installer, to: new) ? new : nil
            }.result
            guard case .success(let moved?) = result else {
                var detail: String?
                if case .failure(let error) = result {
                    detail = String(describing: error)
                }
                update(host, note: "Could not move it to a private socket; it stays on the port", detail: detail)
                setFailed(host, true)
                setWorking(host, false)
                return
            }

            if let index = rows.firstIndex(where: { $0.host == host }) {
                rows[index].needsMove = false
            }
            await show(host, moved)
            if let setup = setups[host] {
                agentsChanged(host, setup)
            }
        }
    }

    /// Rewrites each app's entry with `new`; when any fails, puts `old`'s back in all of them.
    nonisolated static func move(_ harnesses: [Harness], from old: Installer, to new: Installer) -> Bool {
        let failed = harnesses.contains { harness in
            let report = new.install(harness)
            return report.changes.contains { if case .failed = $0.action { true } else { false } } || new.status(of: harness) != .installed
        }
        if failed {
            harnesses.forEach { _ = old.install($0) }
        }
        return !failed
    }

    /// For the contract: a machine's page without the machine.
    func setSetupForTesting(_ setup: AgentSetup, for host: String) {
        setups[host] = setup
    }

    /// Whether a change to the machine is under way: install, remove, the move, or an app's
    /// switch. A machine takes one change at a time, and its controls are off meanwhile.
    func isWorking(_ host: String) -> Bool {
        rows.first { $0.host == host }?.isWorking == true
    }

    /// Installs or removes Tilde in some of the apps on the machine whose page `setup` is.
    func apply(_ harnesses: [Harness], action: InstallResult.Action, by setup: AgentSetup) {
        guard let host = setups.first(where: { $0.value === setup })?.key, !isWorking(host) else {
            return
        }
        update(host, note: nil)
        setWorking(host, true)
        setup.apply(harnesses, action: action)
    }

    /// Installs Tilde on the machine's apps that are switched on on this Mac, the same way as on
    /// this Mac; with none switched on, on all of them.
    func install(_ host: String) {
        guard !isWorking(host) else {
            return
        }
        if rows.first(where: { $0.host == host })?.needsMove == true {
            moveToSocket(host)
            return
        }
        update(host, note: nil)
        setFailed(host, false)
        setWorking(host, true)
        Task {
            await loadSetup(host)
            guard let setup = setups[host] else {
                setWorking(host, false)
                return
            }
            let found = setup.foundRows.map(\.harness)
            let onThisMac = localSetup.map { local in AgentSetup.rows.filter { local.status(of: $0) == .installed }.map(\.harness) } ?? []
            let chosen = Self.chosen(found: found, onThisMac: onThisMac)
            if chosen.isEmpty {
                update(host, note: "No agent apps found")
                setWorking(host, false)
                return
            }
            setup.apply(chosen, action: .installed)
        }
    }

    /// Removes Tilde from all of the machine's apps, the same way as on this Mac.
    func uninstall(_ host: String) {
        guard !isWorking(host), let setup = setups[host] else {
            return
        }
        update(host, note: nil)
        setWorking(host, true)
        setup.apply(setup.foundRows.map(\.harness), action: .removed)
    }

    /// A machine with Tilde in any app is linked, by its socket when its entries start
    /// `tproxy`; with none, its link goes.
    private func agentsChanged(_ host: String, _ setup: AgentSetup) {
        let isInstalled = AgentSetup.rows.contains { setup.status(of: $0) == .installed }
        let known = store.load().first { $0.host == host }
        let node = Node(host: host, token: token(for: host), socket: setup.installer.environment.proxy?.last)
        if let index = rows.firstIndex(where: { $0.host == host }) {
            rows[index].isProtected = node.socket != nil
        }
        if isInstalled, known != node {
            // A reinstall can move a node from the port to its socket.
            try? store.save(store.load().filter { $0.host != host } + [node])
            log.notice("installed on \(host, privacy: .public), socket \(node.socket ?? "none", privacy: .public)")
            links.removeValue(forKey: host)?.terminate()
            update(host, status: .unreachable, note: nil)
            link(host)
        } else if !isInstalled {
            if known != nil {
                try? store.save(store.load().filter { $0.host != host })
            }
            links.removeValue(forKey: host)?.terminate()
            sockets.removeValue(forKey: host)?.stop()
            if let socket = known?.socket {
                let folder = (socket as NSString).deletingLastPathComponent
                Task.detached {
                    _ = try? RemotePush.runOnNode(host, command: "rm -f \(Self.quoted(socket)) \(Self.quoted(folder + "/bin/tproxy"))")
                }
            }
            update(host, status: .notInstalled, note: nil)
        }
        setWorking(host, false)
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

    /// The machine's installer, and whether its type has `tproxy`: its entries start `tproxy`
    /// when it has, unless the node is still `onPort`. Such an installer exists only once Tilde
    /// has the machine's `tproxy`, so no entry starts a file that Tilde cannot give it.
    nonisolated private static func installer(_ host: String, url: String, token: String, onPort: Bool) async throws -> (Installer, Bool) {
        let run: ShellFiles.Run = { command, input in
            try RemotePush.runOnNode(host, command: command, input: input)
        }
        let target = TProxy.Target(uname: try run("uname -sm", nil))
        if let target, !onPort {
            _ = try await TProxy.file(for: target)
        }
        return (try Installer.remote(mcpURL: url, authorization: "Bearer \(token)", proxied: target != nil && !onPort, run: run), target != nil)
    }

    nonisolated static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Readies the node for its link: its `~/.tilde` and `~/.tilde/bin` are this user's, 0700,
    /// no stale socket is left, and it prints its type and its `tproxy`'s hash, if any.
    nonisolated static func prepareCommand(socket: String) -> String {
        let folder = quoted((socket as NSString).deletingLastPathComponent)
        let hash = "{ sha256sum || shasum -a 256; } 2>/dev/null <\"$t/bin/tproxy\""
        return [
            "umask 077 && t=\(folder) && mkdir -p \"$t/bin\"",
            "[ ! -L \"$t\" ] && [ -O \"$t\" ] && [ ! -L \"$t/bin\" ] && [ -O \"$t/bin\" ] && chmod 700 \"$t\" \"$t/bin\"",
            "[ \"$(find \"$t\" \"$t/bin\" -maxdepth 0 -type d -user \"$(id -u)\" -perm 700 | wc -l)\" -eq 2 ]",
            "rm -f \(quoted(socket)) && uname -sm && { \(hash) || true; }",
        ].joined(separator: " && ")
    }

    nonisolated private static func prepare(_ host: String, socket: String) async throws {
        let lines = try await RemotePush.blocking { try RemotePush.runOnNode(host, command: prepareCommand(socket: socket)) }.split(whereSeparator: \.isNewline)
        guard let type = lines.first, let target = TProxy.Target(uname: String(type)) else {
            throw RemotePush.Failure.failed("Tilde has no tproxy for this machine")
        }
        // The node's file is replaced whenever it differs from Tilde's.
        let file = try await TProxy.file(for: target)
        let expected = TProxy.sha256(try Data(contentsOf: file))
        guard lines.dropFirst().first?.split(separator: " ").first.map(String.init) != expected else {
            return
        }

        let proxy = (socket as NSString).deletingLastPathComponent + "/bin/tproxy"
        let check = "chmod 700 \(quoted(proxy + ".new")) && mv -f \(quoted(proxy + ".new")) \(quoted(proxy)) && { sha256sum || shasum -a 256; } 2>/dev/null <\(quoted(proxy))"
        let copied = try await RemotePush.blocking {
            try RemotePush.copy(file, to: host, path: proxy + ".new")
            return try RemotePush.runOnNode(host, command: check)
        }
        guard copied.hasPrefix(expected) else {
            throw RemotePush.Failure.failed("tproxy changed on its way to the machine")
        }
    }

    /// Sets the note, and the link's status when one is given.
    private func update(_ host: String, status: Status? = nil, note: String?, detail: String? = nil) {
        if let index = rows.firstIndex(where: { $0.host == host }) {
            rows[index].status = status ?? rows[index].status
            rows[index].note = note
            rows[index].detail = detail ?? (note == nil ? nil : rows[index].detail)
        } else {
            rows.append(Row(host: host, status: status ?? .notInstalled, note: note, detail: detail))
        }
    }

    private func setFailed(_ host: String, _ hasFailed: Bool) {
        if let index = rows.firstIndex(where: { $0.host == host }) {
            rows[index].hasFailed = hasFailed
        }
    }

    private func setWorking(_ host: String, _ isWorking: Bool) {
        if let index = rows.firstIndex(where: { $0.host == host }) {
            rows[index].isWorking = isWorking
        }
    }

    /// One tunnel, started again whenever it ends: sleep and network changes end it. A node
    /// with a socket gets its `tproxy` checked first, and its tunnel joins the two sockets.
    private func link(_ host: String, attempt: Int = 0) {
        guard links[host] == nil, !preparing.contains(host), RemotePush.isValid(host: host), let mcp,
              let node = store.load().first(where: { $0.host == host }) else {
            return
        }
        guard let socket = node.socket else {
            startTunnel(host, forward: "\(remotePort):127.0.0.1:\(nodePort)", attempt: attempt)
            return
        }

        preparing.insert(host)
        Task {
            defer { preparing.remove(host) }
            do {
                let local = try sockets[host] ?? NodeSocket(node: host, mcp: mcp)
                if sockets[host] == nil {
                    local.start()
                    sockets[host] = local
                }
                try await Task.detached { try await Self.prepare(host, socket: socket) }.value
                guard isLinking, store.load().contains(node) else {
                    return
                }
                startTunnel(host, forward: "\(socket):\(local.path)", attempt: attempt)
            } catch {
                log.error("link to \(host, privacy: .public) not ready: \(String(describing: error), privacy: .public)")
                update(host, status: .unreachable, note: rows.first { $0.host == host }?.note, detail: String(describing: error))
                retry(host, lived: 0, attempt: attempt)
            }
        }
    }

    private func startTunnel(_ host: String, forward: String, attempt: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
            "-o", "ExitOnForwardFailure=yes", "-R", forward, host,
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
        retry(host, lived: lived, attempt: attempt)
    }

    private func retry(_ host: String, lived: TimeInterval, attempt: Int) {
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
