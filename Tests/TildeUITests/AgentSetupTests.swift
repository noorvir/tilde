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
}
