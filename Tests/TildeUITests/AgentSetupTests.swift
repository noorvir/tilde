@testable import TildeCore
@testable import TildeUI
import Foundation
import TildeInstaller
import Testing

/// "Copy setup" on the Home page of Settings.
@MainActor
struct AgentSetupTests {
    /// The copied setups work: the HTTP ones hold the token that the local listener asks for,
    /// and the stdio one starts the bridge, which reads the token itself.
    @Test func copiedSetupsAreLetInByTheLocalListener() async throws {
        let bridge = "/Applications/Tilde.app/Contents/MacOS/tilde-mcp"
        var environment = InstallEnvironment.standard(home: FileManager.default.temporaryDirectory, port: "7311", bridgePath: bridge, isolated: true)
        environment.authorization = "Bearer secret"
        let setup = AgentSetup(installer: Installer(environment: environment), placeholderIcon: Fixtures.appIcon)
        let texts = Dictionary(uniqueKeysWithValues: setup.copySetups.map { ($0.title, $0.text) })
        // None is for another machine: Remote machines sets those up, and keeps the token here.
        #expect(setup.copySetups.map(\.title) == ["Claude Code Command", "Codex Config (config.toml)", "JSON Config (HTTP)", "JSON Config (stdio)"])

        for title in ["Claude Code Command", "Codex Config (config.toml)", "JSON Config (HTTP)"] {
            #expect(texts[title]?.contains("Bearer secret") == true, "\(title)")
        }
        func entry(_ title: String) throws -> [String: Any] {
            let text = try #require(texts[title])
            let config = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return try #require((config?["mcpServers"] as? [String: Any])?["tilde"] as? [String: Any])
        }
        #expect(try entry("JSON Config (stdio)")["command"] as? String == bridge)

        let http = try entry("JSON Config (HTTP)")
        let url = try #require(URL(string: http["url"] as? String ?? ""))
        let authorization = try #require((http["headers"] as? [String: Any])?["Authorization"] as? String)
        let headers = ["host": "127.0.0.1:\(url.port ?? 0)", "content-type": "application/json", "authorization": authorization]
        let ping = HTTPRequest(method: "POST", path: url.path, headers: headers, body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        let server = MCPServer(store: SessionStore(), localToken: "secret")
        #expect(await server.handleLocal(ping).status == 200)
    }

    /// A new command name moves Tilde's skill in each app with Tilde and is kept for the next
    /// launch; an app where the name is another skill's keeps everything, and the toast says so.
    @Test func aNewCommandNameMovesTheSkillInEachAppWithTilde() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-rename-\(UUID().uuidString)")
        func write(_ path: String, _ text: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
        }
        try write(".claude.json", "{}")
        try write(".codex/config.toml", "")
        let defaults = MemoryDefaults()
        let installer = Installer(environment: .standard(home: home, port: "7311", bridgePath: "", isolated: true))
        let setup = AgentSetup(installer: installer, placeholderIcon: Fixtures.appIcon, defaults: defaults)
        _ = setup.install(setup.foundRows)
        try write(".agents/skills/look/SKILL.md", "---\nname: look\n---\n")

        let result = setup.rename(to: "look")

        #expect(result.conflicts.map(\.message) == ["Codex already has a skill named look."])
        #expect(InstallToastView.title(result) == "Installed in 1 of 2 apps · 1 skipped")
        #expect(InstallToastView.subtitle(result) == "Codex already has a skill named look. Choose another command name in Settings.")
        #expect(exists(".claude/skills/look/SKILL.md"))
        #expect(!exists(".claude/skills/annotate"))
        #expect(exists(".agents/skills/annotate/SKILL.md"))
        #expect(defaults.string(forKey: AgentSetup.commandKey) == "look")
        #expect(defaults.stringArray(forKey: AgentSetup.oldCommandsKey) == ["annotate"])
        #expect(AgentSetup(installer: installer, placeholderIcon: Fixtures.appIcon, defaults: defaults).command == "look")
        let codex = try #require(AgentSetup.rows.first { $0.harness == .codex })
        guard case .taken = setup.skillStatus(codex.harness) else {
            Issue.record("Codex should show that the name is taken")
            return
        }

        // The prompt asks for another name; Install uses it in every app and leaves the other skill.
        let prompt = NamePrompt()
        var shown: [InstallResult] = []
        prompt.onResult = { shown.append($0) }
        let conflict = try #require(result.conflicts.first)
        prompt.ask([conflict], setup: setup, suggestion: "look-2", pending: result)
        prompt.name = "look"
        prompt.install()
        #expect(prompt.problem == "Codex already has a skill named look.")
        prompt.name = "look-2"
        prompt.install()

        #expect(prompt.request == nil)
        #expect(shown.count == 1 && shown[0].conflicts.isEmpty)
        #expect(setup.command == "look-2")
        #expect(setup.skillStatus(codex.harness) == .installed)
        #expect(exists(".claude/skills/look-2/SKILL.md"))
        #expect(!exists(".claude/skills/look"))
        #expect(!exists(".agents/skills/annotate"))
        #expect(try String(contentsOf: home.appendingPathComponent(".agents/skills/look/SKILL.md"), encoding: .utf8) == "---\nname: look\n---\n")
    }

    /// Cancel installs nothing more and shows what the install did.
    @Test func cancelShowsWhatTheInstallDid() throws {
        let setup = try Fixtures.agentSetup()
        let prompt = NamePrompt()
        var shown: [InstallResult] = []
        prompt.onResult = { shown.append($0) }
        let pending = Fixtures.installResult(failed: 0)
        let conflict = Conflict(kind: .skill, name: "annotate", harness: .claudeCode, item: URL(fileURLWithPath: "/"))

        prompt.ask([conflict], setup: setup, suggestion: "annotate-2", pending: pending)
        prompt.cancel()

        #expect(prompt.request == nil)
        #expect(shown.count == 1)
        #expect(setup.command == "annotate")
    }
}
