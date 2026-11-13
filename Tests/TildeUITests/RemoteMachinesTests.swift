@testable import TildeUI
import Foundation
import TildeCore
import Testing

/// The beta switch for remote machines: off on a new install, on for a Mac that already has a
/// linked machine, and while it is off, no link runs and the node port is closed.
@MainActor
struct RemoteMachinesTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-remote-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aNewInstallStartsWithItOff() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NodeStore(file: folder.appendingPathComponent("nodes.json"))
        let defaults = MemoryDefaults()

        NodeSetup.migrate(defaults: defaults, store: store)

        #expect(NodeSetup(store: store, nodePort: 7312, defaults: defaults).isEnabled == false)
    }

    @Test func aMacWithALinkedMachineKeepsItOnAndLaterChoicesStay() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NodeStore(file: folder.appendingPathComponent("nodes.json"))
        try store.save([Node(host: "box", token: "secret")])
        let defaults = MemoryDefaults()

        NodeSetup.migrate(defaults: defaults, store: store)
        let nodes = NodeSetup(store: store, nodePort: 7312, defaults: defaults)
        #expect(nodes.isEnabled)

        nodes.setEnabled(false)
        NodeSetup.migrate(defaults: defaults, store: store)
        #expect(NodeSetup(store: store, nodePort: 7312, defaults: defaults).isEnabled == false)
    }

    /// Off ends the tunnels and closes the node port at once; on starts them again.
    @Test func offStopsTheLinksAndOnStartsThemAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NodeStore(file: folder.appendingPathComponent("nodes.json"))
        try store.save([Node(host: "box", token: "secret")])
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: NodeSetup.enabledKey)

        // An ssh that holds its tunnel: it writes its process id and waits.
        let pidFile = folder.appendingPathComponent("ssh.pid")
        let ssh = folder.appendingPathComponent("ssh")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 60\n".utf8).write(to: ssh)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)

        let port = UInt16.random(in: 40_000...49_000)
        let nodes = NodeSetup(store: store, nodePort: port, defaults: defaults, ssh: ssh)
        nodes.mcp = MCPServer(store: SessionStore(), localToken: "local", inbox: folder, clientsFile: folder.appendingPathComponent("clients.json"))
        defer { nodes.stopLinks() }

        nodes.startLinks()
        let first = try await tunnel(pidFile)
        #expect(await isOpen(port))

        nodes.setEnabled(false)
        #expect(await ended(first))
        #expect(await !isOpen(port))

        try FileManager.default.removeItem(at: pidFile)
        nodes.setEnabled(true)
        let second = try await tunnel(pidFile)
        #expect(second != first)
        #expect(await isOpen(port))
    }

    /// The process id of the running tunnel, once it has started.
    private func tunnel(_ pidFile: URL) async throws -> pid_t {
        for _ in 0..<50 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }

    private func ended(_ pid: pid_t) async -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) != 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Whether the node port answers within about two seconds.
    private func isOpen(_ port: UInt16) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        for _ in 0..<20 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if (try? await URLSession.shared.data(for: request)) != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
