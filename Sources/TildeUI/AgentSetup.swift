import TildeInstaller
import AppKit

/// Tilde's MCP server and skill in the user's agent apps, as the menu, the install toast and
/// Settings show them. Each row is what the user sees as one app.
@MainActor
final class AgentSetup: ObservableObject {
    struct Row: Identifiable, Hashable {
        let name: String
        let harnesses: [Harness]

        var id: String { name }
    }

    /// The Claude row stands for the Claude app and Claude Code, which keep their MCP servers
    /// in different files.
    static let rows = [Row(name: "Claude", harnesses: [.claudeDesktop, .claudeCode])]
        + Harness.allCases.filter { $0 != .claudeCode && $0 != .claudeDesktop }.map { Row(name: $0.name, harnesses: [$0]) }

    let installer: Installer
    /// Changes after every install or uninstall, so views read the files again.
    @Published private(set) var revision = 0
    /// Tests draw one placeholder instead of the apps' icons.
    private let placeholderIcon: NSImage?

    init(installer: Installer, placeholderIcon: NSImage? = nil) {
        self.installer = installer
        self.placeholderIcon = placeholderIcon
    }

    /// The rows with at least one app on this Mac.
    var foundRows: [Row] {
        Self.rows.filter { status(of: $0) != .notFound }
    }

    func status(of row: Row) -> InstallStatus {
        installer.status(of: row.harnesses)
    }

    /// The apps of the row that are on this Mac.
    func present(_ row: Row) -> [Harness] {
        row.harnesses.filter { installer.isPresent($0) }
    }

    /// The app's own icon from its bundle on this Mac; Tilde ships no third-party logos.
    /// A command-line tool without an app gets a terminal symbol.
    func icon(for row: Row) -> NSImage {
        if let placeholderIcon {
            return placeholderIcon
        }
        let bundle = row.harnesses.lazy.compactMap { self.installer.appBundle(for: $0) }.first
        let image = bundle.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    struct CopySetup: Identifiable {
        let title: String
        let text: String

        var id: String { title }
    }

    /// Snippets for apps that Tilde cannot set up itself, and for agents on other machines.
    var copySetups: [CopySetup] {
        let url = installer.environment.mcpURL
        let port = URL(string: url)?.port ?? 7311
        let bridge = installer.environment.bridgePath
        return [
            CopySetup(title: "Claude Code Command", text: "claude mcp add --scope user --transport http tilde \(url)"),
            CopySetup(title: "Codex Config (config.toml)", text: "[mcp_servers.tilde]\nurl = \"\(url)\"\ndefault_tools_approval_mode = \"approve\"\n"),
            CopySetup(title: "JSON Config (HTTP)", text: #"{ "mcpServers": { "tilde": { "url": "\#(url)" } } }"#),
            CopySetup(title: "JSON Config (stdio)", text: #"{ "mcpServers": { "tilde": { "command": "\#(bridge)" } } }"#),
            CopySetup(title: "SSH Tunnel for Remote Agents", text: "ssh -R \(port):127.0.0.1:\(port) <host>"),
        ]
    }

    /// The icon of the agent app that the HUD names as the client, such as "Codex". Only apps
    /// with a bundle on this Mac have one.
    func icon(forClient name: String) -> NSImage? {
        let harnesses: [String: Harness] = [
            "Claude": .claudeDesktop, "Claude Code": .claudeCode, "Codex": .codex, "Cursor": .cursor,
            "VS Code": .vscode, "Gemini CLI": .gemini, "Windsurf": .windsurf,
        ]
        guard let harness = harnesses[name] else {
            return nil
        }
        if let placeholderIcon {
            return placeholderIcon
        }
        return installer.appBundle(for: harness).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    func install(_ rows: [Row]) -> InstallResult {
        run(rows, action: .installed)
    }

    func uninstall(_ rows: [Row]) -> InstallResult {
        run(rows, action: .removed)
    }

    private func run(_ rows: [Row], action: InstallResult.Action) -> InstallResult {
        let apps = rows.map { row in
            let reports = present(row).map { action == .installed ? installer.install($0) : installer.uninstall($0) }
            let failed = reports.contains { report in
                report.changes.contains { if case .failed = $0.action { true } else { false } }
            }
            return InstallResult.App(name: row.name, icon: icon(for: row), failed: failed, changed: reports.contains(where: \.hasChanges))
        }
        revision += 1
        return InstallResult(action: action, apps: apps)
    }
}

/// What one install or uninstall did, for the toast.
struct InstallResult {
    enum Action {
        case installed
        case removed
    }

    struct App {
        let name: String
        let icon: NSImage
        let failed: Bool
        let changed: Bool
    }

    let action: Action
    let apps: [App]

    var failures: Int {
        apps.filter(\.failed).count
    }
}
