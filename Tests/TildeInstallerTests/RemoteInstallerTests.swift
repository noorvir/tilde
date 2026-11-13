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

    /// A machine that does not answer the question "is the file there?", such as when its
    /// connection drops for that one command, keeps its config: a command that fails is not
    /// "no file", which would put a config with only Tilde's entry in place of the user's.
    @Test func aCommandThatFailsDoesNotReadAsNoFile() throws {
        let home = try home()
        let config = #"{ "other": 1 }"#
        try config.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let shell = run(home: home)
        let installer = try Installer.remote(mcpURL: "http://127.0.0.1:7319/mcp", authorization: "Bearer secret") { command, input in
            if command.contains(".claude.json"), command.contains("-e ") {
                throw InstallerError.noHome
            }
            return try shell(command, input)
        }

        let report = installer.install(.claudeCode)

        #expect(report.changes.first?.action == .failed(String(describing: InstallerError.noHome)))
        #expect(try text(home, ".claude.json") == config)
    }

    /// On a machine linked by its socket, each app starts `tproxy` with the socket as a
    /// stdio server, in its own words, and a reinstall replaces an older URL entry.
    @Test func aProxiedMachineGetsStdioEntriesThatReplaceTheURL() throws {
        let home = try home()
        for folder in [".codex", ".cursor", ".gemini", ".config/devin", "Library/Application Support/Code/User"] {
            try make(home, folder)
        }
        try "{}".write(to: home.appendingPathComponent(".gemini/settings.json"), atomically: true, encoding: .utf8)
        try #"{ "mcpServers": { "tilde": { "type": "http", "url": "http://127.0.0.1:7319/mcp" } }, "other": 1 }"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let installer = try Installer.remote(mcpURL: "http://127.0.0.1:7319/mcp", authorization: "Bearer secret", proxied: true, run: run(home: home))
        let proxy = home.path + "/.tilde/bin/tproxy"
        let socket = home.path + "/.tilde/tilde.sock"
        #expect(installer.environment.proxy == [proxy, socket])
        #expect(installer.status(of: .claudeCode) == .notInstalled)

        for harness in Harness.allCases {
            _ = installer.install(harness)
            #expect(installer.status(of: harness) == .installed, "\(harness)")
        }

        func entry(_ path: String, _ keys: [String]) throws -> [String: Any] {
            var value: Any = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(path)))
            for key in keys {
                value = try #require((value as? [String: Any])?[key])
            }
            return try #require(value as? [String: Any])
        }
        let stdio: [String: Any] = ["command": proxy, "args": [socket]]
        let typed = stdio.merging(["type": "stdio"]) { $1 }
        #expect(NSDictionary(dictionary: try entry(".claude.json", ["mcpServers", "tilde"])) == NSDictionary(dictionary: typed))
        #expect(NSDictionary(dictionary: try entry("Library/Application Support/Code/User/mcp.json", ["servers", "tilde"])) == NSDictionary(dictionary: typed))
        for path in [".cursor/mcp.json", ".gemini/settings.json", ".config/devin/mcp_config.json"] {
            #expect(NSDictionary(dictionary: try entry(path, ["mcpServers", "tilde"])) == NSDictionary(dictionary: stdio), "\(path)")
        }
        #expect(try entry(".claude.json", [])["other"] as? Int == 1)
        let codex = try text(home, ".codex/config.toml")
        #expect(codex.contains("command = \"\(proxy)\"\nargs = [\"\(socket)\"]\ndefault_tools_approval_mode = \"approve\""))
        #expect(!codex.contains("Bearer"))
        #expect(!codex.contains("url ="))
    }

    /// VS Code keeps its config in ~/.config on Linux (or XDG_CONFIG_HOME), in ~/Library on macOS.
    @Test func vsCodeIsFoundAndInstalledWhereTheSystemKeepsIt() throws {
        let linux = try home()
        let bin = linux.appendingPathComponent("fake-bin")
        try make(linux, "fake-bin")
        try "#!/bin/sh\necho Linux\n".write(to: bin.appendingPathComponent("uname"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("uname").path)
        let path = ["PATH": "\(bin.path):/usr/bin:/bin"]

        try make(linux, ".config/Code/User")
        let onLinux = try Installer.remote(mcpURL: "http://127.0.0.1:7319/mcp", authorization: "Bearer secret", run: run(home: linux, variables: path))
        #expect(onLinux.environment.isLinux)
        #expect(onLinux.isPresent(.vscode))
        _ = onLinux.install(.vscode)
        #expect(try text(linux, ".config/Code/User/mcp.json").contains("Bearer secret"))
        #expect(!FileManager.default.fileExists(atPath: linux.appendingPathComponent("Library").path))

        try make(linux, "xdg/Code/User")
        let moved = try Installer.remote(mcpURL: "http://127.0.0.1:7319/mcp", authorization: "Bearer secret", run: run(home: linux, variables: path.merging(["XDG_CONFIG_HOME": linux.path + "/xdg"]) { $1 }))
        #expect(moved.configFile(for: .vscode).path == linux.path + "/xdg/Code/User/mcp.json")

        let mac = try home()
        try make(mac, "Library/Application Support/Code/User")
        let local = try installer(mac)
        #expect(!local.environment.isLinux)
        #expect(local.isPresent(.vscode))
        #expect(local.configFile(for: .vscode).path == mac.path + "/Library/Application Support/Code/User/mcp.json")
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

    /// A config that is a link, as in a dotfiles repository, is replaced at its target, whole
    /// and private, never written in place; the link stays.
    @Test func aLinkedConfigIsReplacedAtItsTargetForItsOwnerOnly() throws {
        let home = try home()
        try make(home, "dotfiles")
        try make(home, ".codex")
        let target = home.appendingPathComponent("dotfiles/config.toml")
        try "model = \"o3\"\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex/config.toml"), withDestinationURL: target)

        _ = try installer(home).install(.codex)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".codex/config.toml").path) == target.path)
        #expect(try text(home, "dotfiles/config.toml").contains("Bearer secret"))
        #expect(try text(home, "dotfiles/config.toml").contains("model = \"o3\""))
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600)
    }

    /// A linked config that an older Tilde left readable by others is made private, also when
    /// its text is already right.
    @Test func anUnchangedLinkedConfigBecomesPrivate() throws {
        let home = try home()
        try make(home, "dotfiles")
        try make(home, ".codex")
        let target = home.appendingPathComponent("dotfiles/config.toml")
        try "".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex/config.toml"), withDestinationURL: target)
        _ = try installer(home).install(.codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)

        _ = try installer(home).install(.codex)

        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600)
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
