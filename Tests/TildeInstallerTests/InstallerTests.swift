@testable import TildeInstaller
import Foundation
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

    @Test func claudeNamesBothClaudeApps() {
        #expect(Harness.named("claude") == [.claudeCode, .claudeDesktop])
        #expect(Harness.named("codex") == [.codex])
        #expect(Harness.named("claude-app") == nil)
    }

    @Test func statusOfBothClaudeAppsCountsOnlyTheOnesFound() throws {
        let claude: [Harness] = [.claudeDesktop, .claudeCode]
        #expect(installer.status(of: claude) == .notFound)

        try write(".claude.json", "{}")
        #expect(installer.status(of: claude) == .notInstalled)
        _ = installer.install(.claudeCode)
        #expect(installer.status(of: claude) == .installed)

        try write("Library/Application Support/Claude/claude_desktop_config.json", "{}")
        #expect(installer.status(of: claude) == .partlyInstalled)
        _ = installer.install(.claudeDesktop)
        #expect(installer.status(of: claude) == .installed)
    }

    @Test func invalidConfigIsAnErrorForItsAppAndItsRow() throws {
        try write(".claude.json", "{}")
        _ = installer.install(.claudeCode)
        try write("Library/Application Support/Claude/claude_desktop_config.json", "{ not json")

        guard case .failed = installer.status(of: .claudeDesktop) else {
            Issue.record("expected an error, got \(installer.status(of: .claudeDesktop))")
            return
        }
        guard case .failed = installer.status(of: [.claudeDesktop, .claudeCode]) else {
            Issue.record("expected an error for the row")
            return
        }
        #expect(installer.install(.claudeDesktop).changes.first.map { if case .failed = $0.action { true } else { false } } == true)
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

        let report = installer.install(.claudeCode)

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
        let backup = try #require(report.changes.first?.backup)
        #expect(backup.lastPathComponent.hasPrefix(".claude.json.tilde-backup-"))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
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
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".gemini").path).filter { $0.contains("tilde-backup") }
        #expect(backups.count == 1)
    }

    @Test func uninstallRemovesOnlyTilde() throws {
        let original = """
        {
          "mcpServers": {
            "filesystem": {
              "command": "npx"
            }
          },
          "globalShortcut": ""
        }

        """
        try write("Library/Application Support/Claude/claude_desktop_config.json", original)

        _ = installer.install(.claudeDesktop)
        #expect(try read("Library/Application Support/Claude/claude_desktop_config.json").contains("tilde-mcp"))
        let report = installer.uninstall(.claudeDesktop)

        #expect(report.changes.map(\.action) == [.updated, .removed])
        #expect(try read("Library/Application Support/Claude/claude_desktop_config.json") == original)
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
