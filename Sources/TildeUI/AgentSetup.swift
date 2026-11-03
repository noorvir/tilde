import TildeInstaller
import AppKit

/// Tilde's MCP server and skill in the user's agent apps, as the menu, the install toast and
/// Settings show them. Each row is what the user sees as one app.
@MainActor
final class AgentSetup: ObservableObject {
    struct Row: Identifiable, Hashable {
        let name: String
        let harness: Harness

        var id: String { name }
    }

    /// Claude Code shows as Claude, with the Claude app's icon.
    static let rows = [Row(name: "Claude", harness: .claudeCode)]
        + Harness.allCases.filter { $0 != .claudeCode }.map { Row(name: $0.name, harness: $0) }

    let installer: Installer
    /// Changes after every install or uninstall, so views read the files again.
    @Published fileprivate(set) var revision = 0
    /// Tests draw one placeholder instead of the apps' icons.
    private let placeholderIcon: NSImage?

    let nodes: NodeSetup
    /// A machine reached over ssh: what it has is read away from the main thread and kept.
    let isRemote: Bool
    /// This Mac's setup, for the icons of a machine's apps.
    private weak var iconSource: AgentSetup?
    @Published private var remoteStatuses: [Harness: InstallStatus] = [:]
    @Published fileprivate var remoteSkills: Set<Harness> = []
    /// After an install or uninstall on a machine.
    var onChange: () -> Void = {}

    init(installer: Installer, placeholderIcon: NSImage? = nil, nodes: NodeSetup? = nil, isRemote: Bool = false, iconSource: AgentSetup? = nil) {
        self.nodes = nodes ?? NodeSetup(nodePort: 7312)
        self.installer = installer
        self.placeholderIcon = placeholderIcon
        self.isRemote = isRemote
        self.iconSource = iconSource
        if !isRemote {
            self.nodes.localSetup = self
        }
    }

    /// Reads what a machine has.
    func load() async {
        let installer = self.installer
        let (statuses, skills) = await Task.detached {
            let statuses = Dictionary(uniqueKeysWithValues: Harness.allCases.map { ($0, installer.status(of: $0)) })
            let skills = Set(Harness.allCases.filter { statuses[$0] != .notFound && installer.hasSkill($0) })
            return (statuses, skills)
        }.value
        remoteStatuses = statuses
        remoteSkills = skills
    }

    /// For the contract: a machine's apps without the machine.
    func setRemoteStatusesForTesting(_ statuses: [Harness: InstallStatus]) {
        remoteStatuses = statuses
        remoteSkills = Set(statuses.filter { $0.value == .installed }.keys)
    }

    /// The rows whose app is on this Mac, or on the machine.
    var foundRows: [Row] {
        Self.rows.filter { status(of: $0) != .notFound }
    }

    func status(of row: Row) -> InstallStatus {
        guard isRemote else {
            return installer.status(of: row.harness)
        }
        return remoteStatuses[row.harness] ?? .notFound
    }

    /// The app's own icon from its bundle on this Mac; Tilde ships no third-party logos.
    /// A command-line tool without an app gets a terminal symbol.
    func icon(for row: Row) -> NSImage {
        if let placeholderIcon {
            return placeholderIcon
        }
        if isRemote, let iconSource {
            return iconSource.icon(for: row)
        }
        let image = installer.appBundle(for: row.harness).map { NSWorkspace.shared.icon(forFile: $0.path) }
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

    /// The icon of the agent that the HUD and History name as the client, such as "Codex":
    /// the same as its row on the Agents page (Codex shows the ChatGPT app's icon).
    func icon(forClient name: String) -> NSImage? {
        let harnesses: [String: Harness] = [
            "Claude": .claudeCode, "Claude Code": .claudeCode, "Codex": .codex, "Cursor": .cursor,
            "VS Code": .vscode, "Gemini CLI": .gemini, "Windsurf": .windsurf,
        ]
        guard let harness = harnesses[name], let row = Self.rows.first(where: { $0.harness == harness }) else {
            return nil
        }
        return icon(for: row)
    }

    func install(_ rows: [Row]) -> InstallResult {
        run(rows, action: .installed)
    }

    func uninstall(_ rows: [Row]) -> InstallResult {
        run(rows, action: .removed)
    }

    private func run(_ rows: [Row], action: InstallResult.Action) -> InstallResult {
        let found = rows.filter { status(of: $0) != .notFound }
        if isRemote {
            apply(found.map(\.harness), action: action)
            return InstallResult(action: action, apps: [])
        }

        let apps = found.map { row in
            let report = action == .installed ? installer.install(row.harness) : installer.uninstall(row.harness)
            let failed = report.changes.contains { if case .failed = $0.action { true } else { false } }
            return InstallResult.App(name: row.name, icon: icon(for: row), failed: failed, changed: report.hasChanges)
        }
        revision += 1
        return InstallResult(action: action, apps: apps)
    }
}

extension AgentSetup {
    /// On a machine: the same install or uninstall, away from the main thread.
    func apply(_ harnesses: [Harness], action: InstallResult.Action) {
        let installer = self.installer
        Task {
            await Task.detached {
                for harness in harnesses {
                    _ = action == .installed ? installer.install(harness) : installer.uninstall(harness)
                }
            }.value
            await load()
            revision += 1
            onChange()
        }
    }
}

extension AgentSetup {
    /// Whether the app has Tilde's skill: read now on this Mac, kept from the last read on a machine.
    func hasSkill(_ harness: Harness) -> Bool {
        isRemote ? remoteSkills.contains(harness) : installer.hasSkill(harness)
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
