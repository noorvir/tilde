import Foundation
import Testing
@testable import TildeInstaller
import TildeSkill

/// Runs the installer's commands in a shell, with a temporary folder as the home of the machine.
private func run(home: URL, variables: [String: String] = [:]) -> ShellFiles.Run {
    { command, input in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"].merging(variables) { $1 }
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
            throw InstallerError.noHome
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The same installer as on this Mac, through a shell.
struct RemoteInstallerTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-node-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func make(_ home: URL, _ folder: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
    }

    private func text(_ home: URL, _ path: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    private func installer(_ home: URL, variables: [String: String] = [:]) throws -> Installer {
        try Installer.remote(mcpURL: "http://127.0.0.1:7319/mcp", authorization: "Bearer secret", run: run(home: home, variables: variables))
    }

    @Test func itFindsAgentsInstallsAndRemovesThemLikeOnThisMac() throws {
        let home = try home()
        try make(home, ".codex")
        try make(home, ".cursor")
        try #"{ "other": 1 }"#.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let installer = try installer(home)

        #expect(installer.isPresent(.claudeCode))
        #expect(installer.isPresent(.codex))
        #expect(installer.isPresent(.cursor))
        #expect(!installer.isPresent(.gemini))
        #expect(installer.status(of: .codex) == .notInstalled)

        for harness in [Harness.claudeCode, .codex, .cursor] {
            _ = installer.install(harness)
            #expect(installer.status(of: harness) == .installed)
        }
        let claude = try text(home, ".claude.json")
        #expect(claude.contains("\"other\""))
        #expect(claude.contains("Bearer secret"))
        #expect(claude.contains("127.0.0.1:7319"))
        #expect(try text(home, ".codex/config.toml").contains("Bearer secret"))
        #expect(try text(home, ".cursor/mcp.json").contains("Bearer secret"))
        #expect(try text(home, ".claude/skills/tilde/SKILL.md") == tildeSkill)
        #expect(try text(home, ".agents/skills/tilde/SKILL.md") == tildeSkill)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: home.path).contains { $0.contains("tilde-backup") })

        for harness in [Harness.claudeCode, .codex, .cursor] {
            _ = installer.uninstall(harness)
        }
        #expect(try !text(home, ".claude.json").contains("Bearer"))
        #expect(try text(home, ".claude.json").contains("\"other\""))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/tilde").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/tilde").path))
    }

    @Test func aConfigWithTheTokenIsForItsOwnerOnly() throws {
        let home = try home()
        try make(home, ".codex")
        try "".write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.appendingPathComponent(".codex/config.toml").path)

        _ = try installer(home).install(.codex)

        #expect(try text(home, ".codex/config.toml").contains("Bearer secret"))
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".codex/config.toml").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func itWritesThroughALinkedSkillsFolder() throws {
        let home = try home()
        try make(home, "repo/skills")
        try make(home, ".codex")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".agents"), withDestinationURL: home.appendingPathComponent("repo"))
        _ = try installer(home).install(.codex)
        #expect(try text(home, "repo/skills/tilde/SKILL.md") == tildeSkill)
    }

    @Test func aVariableMovesAnAgentsFolder() throws {
        let home = try home()
        let moved = home.appendingPathComponent("elsewhere")
        try make(home, "elsewhere")
        let installer = try installer(home, variables: ["CODEX_HOME": moved.path])
        #expect(installer.isPresent(.codex))
        _ = installer.install(.codex)
        #expect(try text(home, "elsewhere/config.toml").contains("Bearer secret"))
    }
}
