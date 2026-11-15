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

    private(set) var installer: Installer
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
    @Published fileprivate var remoteSkills: [Harness: SkillStatus] = [:]
    /// After an install or uninstall on a machine.
    var onChange: () -> Void = {}
    /// Where this Mac keeps the command name; none for a machine, which takes this Mac's.
    private let defaults: UserDefaults?

    nonisolated static let commandKey = "commandName"
    nonisolated static let oldCommandsKey = "oldCommandNames"

    init(
        installer: Installer, placeholderIcon: NSImage? = nil, nodes: NodeSetup? = nil, isRemote: Bool = false, iconSource: AgentSetup? = nil,
        defaults: UserDefaults? = nil
    ) {
        self.nodes = nodes ?? NodeSetup(nodePort: 7312)
        self.installer = installer
        self.placeholderIcon = placeholderIcon
        self.isRemote = isRemote
        self.iconSource = iconSource
        self.defaults = defaults
        if let defaults {
            self.installer.command = defaults.string(forKey: Self.commandKey) ?? CommandName.standard
            self.installer.oldCommands = defaults.stringArray(forKey: Self.oldCommandsKey) ?? []
        }
        if !isRemote {
            self.nodes.localSetup = self
        }
    }

    /// The command that starts Tilde in the agents, such as `annotate`.
    var command: String {
        installer.command
    }

    /// Uses `name` for the files from now on; Tilde's files under earlier names go on the next
    /// install or migration. Nothing is written.
    func setCommand(_ name: String, oldCommands: [String]) {
        installer.command = name
        installer.oldCommands = oldCommands
        revision += 1
    }

    /// Changes the command name: each app with Tilde gets the skill under the new name and
    /// loses Tilde's files under the old one, on this Mac and on the linked machines. An app
    /// where the new name is another skill's keeps everything as it was.
    func rename(to name: String) -> InstallResult {
        let oldCommands = Array(Set(installer.oldCommands + [installer.command]).subtracting([name])).sorted()
        defaults?.set(name, forKey: Self.commandKey)
        defaults?.set(oldCommands, forKey: Self.oldCommandsKey)
        setCommand(name, oldCommands: oldCommands)
        nodes.commandChanged()
        return install(foundRows.filter { status(of: $0) == .installed })
    }

    /// Moves Tilde's files under old names, such as the `tilde` skill of older versions, to
    /// the current name in each app; then reads what the apps have.
    func migrate() async {
        let installer = self.installer
        await Task.detached {
            for harness in Harness.allCases where installer.isPresent(harness) {
                _ = installer.migrate(harness)
            }
        }.value
        if isRemote {
            await load()
        }
        revision += 1
    }

    /// Reads what a machine has.
    func load() async {
        let installer = self.installer
        let (statuses, skills) = await Task.detached {
            let statuses = Dictionary(uniqueKeysWithValues: Harness.allCases.map { ($0, installer.status(of: $0)) })
            let found = Harness.allCases.filter { statuses[$0] != .notFound }
            let skills = Dictionary(uniqueKeysWithValues: found.map { ($0, installer.skillStatus(of: $0)) })
            return (statuses, skills)
        }.value
        remoteStatuses = statuses
        remoteSkills = skills
    }

    /// For the contract: a machine's apps without the machine.
    func setRemoteStatusesForTesting(_ statuses: [Harness: InstallStatus]) {
        remoteStatuses = statuses
        remoteSkills = statuses.mapValues { $0 == .installed ? .installed : .missing }
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

    /// Snippets for apps that Tilde cannot set up itself. Each holds the local token, as the
    /// entries that Install writes do, except the stdio one: the `tilde-mcp` bridge reads the
    /// token itself.
    var copySetups: [CopySetup] {
        let environment = installer.environment
        let header = environment.authorization.map { " --header \"Authorization: \($0)\"" } ?? ""
        var bridge = environment
        bridge.proxy = [environment.bridgePath]

        return [
            CopySetup(title: "Claude Code Command", text: "claude mcp add --scope user --transport http tilde \(environment.mcpURL)\(header)"),
            CopySetup(title: "Codex Config (config.toml)", text: installer.entryText(for: .codex)),
            CopySetup(title: "JSON Config (HTTP)", text: installer.entryText(for: .cursor)),
            CopySetup(title: "JSON Config (stdio)", text: Installer(environment: bridge).entryText(for: .cursor)),
        ]
    }

    /// The icon of the agent that the HUD and History name as the client, such as "Codex":
    /// the same as its row on the Home page of Settings (Codex shows the ChatGPT app's icon).
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

    /// Installs in the app after the user confirmed that the other skill or command of the
    /// same name goes to Tilde's backup folder.
    func replace(_ row: Row) -> InstallResult {
        run([row], action: .replaced)
    }

    private func run(_ rows: [Row], action: InstallResult.Action) -> InstallResult {
        let found = rows.filter { status(of: $0) != .notFound }
        if isRemote {
            nodes.apply(found.map(\.harness), action: action, by: self)
            return InstallResult(action: action, apps: [])
        }

        let apps = found.map { row in
            let report = Self.run(action, row.harness, with: installer)
            let failed = report.changes.contains(where: \.action.isFailure)
            return InstallResult.App(name: row.name, icon: icon(for: row), failed: failed, changed: report.hasChanges, conflict: report.conflict?.message)
        }
        revision += 1
        return InstallResult(action: action, apps: apps)
    }

    nonisolated static func run(_ action: InstallResult.Action, _ harness: Harness, with installer: Installer) -> InstallReport {
        switch action {
        case .installed: installer.install(harness)
        case .replaced: installer.install(harness, replace: true)
        case .removed: installer.uninstall(harness)
        }
    }
}

extension AgentSetup {
    /// On a machine: the same install or uninstall, away from the main thread.
    func apply(_ harnesses: [Harness], action: InstallResult.Action) {
        let installer = self.installer
        Task {
            await Task.detached {
                for harness in harnesses {
                    _ = Self.run(action, harness, with: installer)
                }
            }.value
            await load()
            revision += 1
            onChange()
        }
    }
}

extension AgentSetup {
    /// Whether the app has Tilde's skill, or another has its name: read now on this Mac, kept
    /// from the last read on a machine.
    func skillStatus(_ harness: Harness) -> SkillStatus {
        isRemote ? remoteSkills[harness] ?? .missing : installer.skillStatus(of: harness)
    }
}

/// What one install or uninstall did, for the toast.
struct InstallResult {
    enum Action {
        case installed
        /// Installed after another skill of the same name went to the backup folder.
        case replaced
        case removed
    }

    struct App {
        let name: String
        let icon: NSImage
        let failed: Bool
        let changed: Bool
        /// Why nothing changed: the name is another skill's or command's.
        var conflict: String?
    }

    let action: Action
    let apps: [App]

    var failures: Int {
        apps.filter(\.failed).count
    }

    var conflicts: [String] {
        apps.compactMap(\.conflict)
    }
}
