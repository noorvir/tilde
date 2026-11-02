import Foundation
import Testing
@testable import TildeInstaller

/// Runs the installer's commands in a shell, with a temporary folder as the home of the node.
private func shell(home: URL) -> NodeInstaller.Shell {
    { command, input in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardInput = stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
        }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct NodeInstallerTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-node-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func text(_ home: URL, _ path: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func installWritesEntriesAndSkillsAndKeepsTheRest() throws {
        let home = try home()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try #"{ "other": 1 }"#.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let installer = NodeInstaller(mcpURL: "http://127.0.0.1:7311/mcp", shell: shell(home: home))

        let report = try installer.install(token: "secret")
        #expect(report.skipped.isEmpty)
        let claude = try text(home, ".claude.json")
        #expect(claude.contains("\"other\""))
        #expect(claude.contains("Bearer secret"))
        #expect(try text(home, ".codex/config.toml").contains("Bearer secret"))
        #expect(try text(home, ".claude/skills/tilde/SKILL.md").contains("disable-model-invocation: true"))
        #expect(try text(home, ".agents/skills/tilde/SKILL.md").contains("open Tilde on their Mac"))
        let names = try FileManager.default.contentsOfDirectory(atPath: home.path)
        #expect(names.contains { $0.hasPrefix(".claude.json.tilde-backup-") })

        _ = try installer.uninstall()
        #expect(try !text(home, ".claude.json").contains("Bearer"))
        #expect(try text(home, ".claude.json").contains("\"other\""))
        #expect(try !text(home, ".codex/config.toml").contains("Bearer"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/tilde").path))
    }

    @Test func aSkillsFolderThatLinksElsewhereIsLeftAlone() throws {
        let home = try home()
        let repo = home.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".agents"), withDestinationURL: repo)
        let installer = NodeInstaller(mcpURL: "http://127.0.0.1:7311/mcp", shell: shell(home: home))

        let report = try installer.install(token: "secret")
        #expect(report.skipped == ["Codex skill skipped"])
        #expect(report.details.contains { $0.contains(".agents/skills/tilde") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: repo.path).isEmpty)
    }

    @Test func aMachineWithNoAgentGetsNothing() throws {
        let home = try home()
        let installer = NodeInstaller(mcpURL: "http://127.0.0.1:7311/mcp", shell: shell(home: home))
        let report = try installer.install(token: "secret")
        #expect(report.changed.isEmpty)
        #expect(!report.skipped.isEmpty)
    }
}
