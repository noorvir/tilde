@testable import TildeUI
import Foundation
import TildeCore
import TildeInstaller
import Testing

/// What Tilde runs on a node before each link, here in a shell with a temporary home.
struct NodeLinkTests {
    private func prepare(_ home: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", NodeSetup.prepareCommand(socket: home.path + "/.tilde/tilde.sock")]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func mode(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
    }

    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-node-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// The folders are made private, a stale socket goes, and the type and the proxy's hash
    /// come back, so that the right file is copied only when the hash differs.
    @Test func itReadiesTheFoldersAndReportsTheProxy() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let tilde = home.appendingPathComponent(".tilde")

        let fresh = prepare(home)
        #expect(fresh.status == 0)
        #expect(fresh.output.split(separator: "\n").count == 1)
        #expect(mode(tilde) == 0o700)
        #expect(mode(tilde.appendingPathComponent("bin")) == 0o700)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tilde.path)
        try Data("stale".utf8).write(to: tilde.appendingPathComponent("tilde.sock"))
        try Data("proxy".utf8).write(to: tilde.appendingPathComponent("bin/tproxy"))
        let again = prepare(home)
        #expect(again.status == 0)
        #expect(mode(tilde) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: tilde.appendingPathComponent("tilde.sock").path))
        let lines = again.output.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.last?.hasPrefix(TProxy.sha256(Data("proxy".utf8))) == true)
    }

    /// A `~/.tilde` that is a link, such as one to another user's folder, is never used.
    @Test func aLinkedFolderIsRefused() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".tilde"), withDestinationURL: elsewhere)

        #expect(prepare(home).status != 0)
    }

    /// The node's installer through a shell, with `home` as its home.
    private func installer(_ home: URL, proxied: Bool) throws -> Installer {
        try Installer.remote(mcpURL: "http://127.0.0.1:7319/mcp", authorization: "Bearer secret", proxied: proxied) { command, input in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
            let output = Pipe()
            let stdin = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = stdin
            try process.run()
            if let input {
                stdin.fileHandleForWriting.write(Data(input.utf8))
            }
            try stdin.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// A node with an older Tilde's URL entries in several apps moves to its socket in one
    /// Install: all its apps start tproxy, or, when one cannot change, all keep their URL.
    @Test func aNodeMovesAllItsAppsToTheSocketOrNone() throws {
        let home = try home()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent(".cursor").path)
            try? FileManager.default.removeItem(at: home)
        }
        for folder in [".codex", ".cursor"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "{}".write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let apps: [Harness] = [.claudeCode, .codex, .cursor]
        let old = try installer(home, proxied: false)
        let new = try installer(home, proxied: true)
        apps.forEach { _ = old.install($0) }
        let configs = [".claude.json", ".codex/config.toml", ".cursor/mcp.json"]
        func texts() throws -> [String] {
            try configs.map { try String(contentsOf: home.appendingPathComponent($0), encoding: .utf8) }
        }
        let before = try texts()
        #expect(apps.allSatisfy { new.status(of: $0) == .notInstalled })

        // Cursor's folder cannot change: nothing moves.
        let cursorFile = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: cursorFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.appendingPathComponent(".cursor").path)
        #expect(!NodeSetup.move(apps, from: old, to: new))
        #expect(try texts() == before)
        #expect(apps.allSatisfy { old.status(of: $0) == .installed })

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent(".cursor").path)
        #expect(NodeSetup.move(apps, from: old, to: new))
        #expect(apps.allSatisfy { new.status(of: $0) == .installed })
        #expect(try texts().allSatisfy { $0.contains("tproxy") && !$0.contains("Bearer") })
    }
}
