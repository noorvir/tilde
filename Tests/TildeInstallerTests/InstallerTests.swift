@testable import TildeInstaller
import Foundation
import os
import TildeSkill
import Testing

struct InstallerTests {
    let home: URL
    let installer: Installer

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = InstallEnvironment.standard(home: home, port: "7311", bridgePath: "/Applications/Tilde.app/Contents/MacOS/tilde-mcp", isolated: true)
        installer = Installer(environment: environment)
    }

    /// The local token is made once, private, and the local install sends it.
    @Test func theLocalTokenIsPrivateAndInEveryLocalEntry() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let token = try LocalToken.load(home: home)
        #expect(token.count == 64)
        #expect(try LocalToken.load(home: home) == token)
        #expect(try FileManager.default.attributesOfItem(atPath: LocalToken.file(home: home).path)[.posixPermissions] as? Int == 0o600)
        #expect(try InstallEnvironment.local(home: home, port: "7311", bridgePath: "", isolated: true).authorization == "Bearer \(token)")
    }

    /// Processes that start at the same moment get the same token: it is made once.
    @Test func theLocalTokenIsMadeOnce() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let tokens = OSAllocatedUnfairLock(initialState: Set<String>())
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let token = try? LocalToken.load(home: home) {
                tokens.withLock { _ = $0.insert(token) }
            }
        }
        #expect(tokens.withLock { $0.count } == 1)
        #expect(try LocalToken.load(home: home) == tokens.withLock { $0.first })
    }

    /// An empty token file, such as one left by a full disk, is replaced by a token.
    @Test func anEmptyTokenFileIsReplaced() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = LocalToken.file(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let token = try LocalToken.load(home: home)
        #expect(token.count == 64)
        #expect(try LocalToken.load(home: home) == token)
    }

    /// Processes that find the same empty file at the same moment also end with one token.
    @Test func anEmptyTokenFileIsReplacedOnce() throws {
        for _ in 0..<20 {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-home-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: home) }
            let file = LocalToken.file(home: home)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data())

            let tokens = OSAllocatedUnfairLock(initialState: Set<String>())
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                if let token = try? LocalToken.load(home: home) {
                    tokens.withLock { _ = $0.insert(token) }
                }
            }
            #expect(tokens.withLock { $0.count } == 1)
            #expect(try LocalToken.load(home: home) == tokens.withLock { $0.first })
        }
    }

    @Test func aConfigItWritesIsForItsOwnerOnly() throws {
        try write(".cursor/mcp.json", "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.appendingPathComponent(".cursor/mcp.json").path)

        _ = installer.install(.cursor)

        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".cursor/mcp.json").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    /// A config with Tilde's entry that cannot be made private, such as one linked into a
    /// read-only store, gives a warning, not a failure.
    @Test func anUnchangedConfigThatCannotChangeIsAWarning() throws {
        try write(".cursor/mcp.json", "{}")
        _ = installer.install(.cursor)
        let config = home.appendingPathComponent(".cursor/mcp.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: config)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: config) }

        let report = installer.install(.cursor)

        #expect(report.changes.contains { if case .unchangedNotPrivate = $0.action { true } else { false } })
        #expect(!report.changes.contains { if case .failed = $0.action { true } else { false } })
    }

    @Test func detectsOnlyAppsWithTheirFolders() throws {
        try write(".cursor/argv.json", "{}")
        try write(".gemini/GEMINI.md", "")
        try write(".local/bin/codex", "")

        #expect(installer.status(of: .cursor) == .notInstalled)
        #expect(installer.status(of: .codex) == .notInstalled)
        #expect(installer.status(of: .claudeCode) == .notFound)
        #expect(installer.status(of: .windsurf) == .notFound)
        #expect(installer.status(of: .gemini) == .notFound)
    }

    @Test func claudeNamesClaudeCode() {
        #expect(Harness.named("claude") == .claudeCode)
        #expect(Harness.named("codex") == .codex)
        #expect(Harness.named("claude-app") == nil)
    }

    @Test func invalidConfigIsAnErrorForItsApp() throws {
        try write(".cursor/mcp.json", "{ not json")

        guard case .failed = installer.status(of: .cursor) else {
            Issue.record("expected an error, got \(installer.status(of: .cursor))")
            return
        }
        #expect(installer.install(.cursor).changes.first.map { if case .failed = $0.action { true } else { false } } == true)
    }

    @Test func commandLineToolsUseTheirMakersAppForTheIcon() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Applications/Claude.app"), withIntermediateDirectories: true)

        #expect(installer.appBundle(for: .claudeCode)?.lastPathComponent == "Claude.app")
        #expect(installer.appBundle(for: .gemini) == nil)
        #expect(installer.status(of: .claudeCode) == .notFound)
    }

    @Test func freshInstallCreatesConfigAndSkill() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)

        let report = installer.install(.cursor)

        #expect(report.changes.map(\.action) == [.created, .created])
        #expect(try read(".cursor/mcp.json") == """
        {
          "mcpServers": {
            "tilde": {
              "url": "http://127.0.0.1:7311/mcp"
            }
          }
        }

        """)
        #expect(try read(".agents/skills/tilde/SKILL.md") == tildeSkill)
        #expect(installer.status(of: .cursor) == .installed)
    }

    @Test func installKeepsOtherServersAndFormatting() throws {
        let original = """
        {
            "numStartups": 3,
            "mcpServers": {
                "github": { "type": "http", "url": "https://api.example.com/mcp" }
            },
            "theme": "dark"
        }

        """
        try write(".claude.json", original)

        _ = installer.install(.claudeCode)

        #expect(try read(".claude.json") == """
        {
            "numStartups": 3,
            "mcpServers": {
                "github": { "type": "http", "url": "https://api.example.com/mcp" },
                "tilde": {
                    "type": "http",
                    "url": "http://127.0.0.1:7311/mcp"
                }
            },
            "theme": "dark"
        }

        """)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: home.path).contains { $0.contains("tilde-backup") })
    }

    @Test func installAddsTheServersObjectToVSCodeJSONC() throws {
        try write("Library/Application Support/Code/User/mcp.json", """
        {
          // Servers for every workspace.
          "inputs": [],
        }

        """)

        _ = installer.install(.vscode)

        #expect(try read("Library/Application Support/Code/User/mcp.json") == """
        {
          // Servers for every workspace.
          "inputs": [],
          "servers": {
            "tilde": {
              "type": "http",
              "url": "http://127.0.0.1:7311/mcp"
            }
          },
        }

        """)
    }

    @Test func installUpdatesAnOlderSkill() throws {
        try write(".cursor/mcp.json", "{}")
        try write(".agents/skills/tilde/SKILL.md", "---\nname: tilde\n---\n\nOld text.\n")

        let report = installer.install(.cursor)

        #expect(report.changes.last?.action == .updated)
        #expect(try read(".agents/skills/tilde/SKILL.md") == tildeSkill)
    }

    @Test func secondInstallChangesNothing() throws {
        try write(".gemini/settings.json", #"{ "theme": "GitHub" }"#)

        _ = installer.install(.gemini)
        let settings = try read(".gemini/settings.json")
        let second = installer.install(.gemini)

        #expect(second.changes.map(\.action) == [.unchanged, .unchanged])
        #expect(!second.hasChanges)
        #expect(try read(".gemini/settings.json") == settings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".gemini").path) == ["settings.json"])
    }

    /// Everything that is not Tilde's stays as it was, to the byte, through an install and an
    /// uninstall.
    @Test func installAndUninstallLeaveTheRestOfAConfigByteForByte() throws {
        let json = """
        {
          "numStartups": 3,
          "mcpServers": {
            "github": { "type": "http", "url": "https://api.example.com/mcp" }
          },
          "theme": "dark"
        }

        """
        let toml = """
        model = "gpt-5"   # the default

        [mcp_servers.github]
        url = "https://api.example.com/mcp"

        """
        try write(".claude.json", json)
        try write(".codex/config.toml", toml)

        _ = installer.install(.claudeCode)
        _ = installer.install(.codex)
        #expect(try read(".claude.json").contains("\"github\": { \"type\": \"http\", \"url\": \"https://api.example.com/mcp\" }"))
        #expect(try read(".codex/config.toml").hasPrefix(toml))

        _ = installer.uninstall(.claudeCode)
        _ = installer.uninstall(.codex)
        #expect(try read(".claude.json") == json)
        #expect(try read(".codex/config.toml") == toml)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: home.path).contains { $0.contains("tilde-backup") })
    }

    @Test func uninstallRemovesOnlyTilde() throws {
        let original = """
        {
          "mcpServers": {
            "filesystem": {
              "command": "npx"
            }
          },
          "numStartups": 3
        }

        """
        try write(".claude.json", original)

        _ = installer.install(.claudeCode)
        #expect(try read(".claude.json").contains("tilde"))
        let report = installer.uninstall(.claudeCode)

        #expect(report.changes.map(\.action) == [.updated, .removed])
        #expect(try read(".claude.json") == original)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/tilde").path))
    }

    @Test func uninstallKeepsASkillThatAnotherAppStillUses() throws {
        try write(".codex/config.toml", "")
        try write(".cursor/mcp.json", "{}")
        _ = installer.install(.codex)
        _ = installer.install(.cursor)

        let report = installer.uninstall(.cursor)

        #expect(report.changes.map(\.action) == [.updated])
        #expect(try read(".agents/skills/tilde/SKILL.md") == tildeSkill)
    }

    @Test func codexReplacesTheTildeTableAndKeepsTheRest() throws {
        try write(".codex/config.toml", """
        model = "gpt-5"

        [mcp_servers.tilde]
        command = "/old/tilde-mcp"

        [mcp_servers.tilde.env]
        TILDE_PORT = "7311"

        [mcp_servers.github]
        url = "https://api.example.com/mcp"

        """)

        _ = installer.install(.codex)
        #expect(try read(".codex/config.toml") == """
        model = "gpt-5"

        [mcp_servers.tilde]
        url = "http://127.0.0.1:7311/mcp"
        default_tools_approval_mode = "approve"

        [mcp_servers.github]
        url = "https://api.example.com/mcp"

        """)
        #expect(installer.status(of: .codex) == .installed)

        _ = installer.uninstall(.codex)
        #expect(try read(".codex/config.toml") == """
        model = "gpt-5"

        [mcp_servers.github]
        url = "https://api.example.com/mcp"

        """)
    }

    @Test func codexAppendsTheTableAndRefusesOtherForms() throws {
        try write(".codex/config.toml", "model = \"gpt-5\"\n")
        _ = installer.install(.codex)
        #expect(try read(".codex/config.toml") == """
        model = "gpt-5"

        [mcp_servers.tilde]
        url = "http://127.0.0.1:7311/mcp"
        default_tools_approval_mode = "approve"

        """)

        let inline = "[mcp_servers]\ntilde = { url = \"http://127.0.0.1:9/mcp\" }\n"
        try write(".codex/config.toml", inline)
        let report = installer.install(.codex)
        guard case .failed = report.changes.first?.action else {
            Issue.record("expected a failure, got \(String(describing: report.changes.first?.action))")
            return
        }
        #expect(try read(".codex/config.toml") == inline)
    }

    @Test func skillIsWrittenThroughALinkedSkillsFolder() throws {
        let dotfiles = home.appendingPathComponent("code/config/agents")
        try FileManager.default.createDirectory(at: dotfiles.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".agents"), withDestinationURL: dotfiles)
        try write(".codex/config.toml", "")

        let report = installer.install(.codex)

        #expect(report.changes.map(\.action) == [.updated, .created])
        #expect(try String(contentsOf: dotfiles.appendingPathComponent("skills/tilde/SKILL.md"), encoding: .utf8) == tildeSkill)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".agents").path)
        #expect(link == dotfiles.path)

        _ = installer.uninstall(.codex)
        #expect(!FileManager.default.fileExists(atPath: dotfiles.appendingPathComponent("skills/tilde").path))
        #expect(FileManager.default.fileExists(atPath: dotfiles.appendingPathComponent("skills").path))
    }

    @Test func dryRunWritesNothing() throws {
        try write(".cursor/mcp.json", "{}")
        var dryRun = installer
        dryRun.dryRun = true

        let report = dryRun.install(.cursor)

        #expect(report.changes.map(\.action) == [.updated, .created])
        #expect(try read(".cursor/mcp.json") == "{}")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents").path))
    }

    // MARK: - Helpers

    private func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }
}
