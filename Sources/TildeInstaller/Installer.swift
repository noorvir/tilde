import Foundation
import TildeSkill

/// An agent app that Tilde can add its MCP server and skill to. This is the list of known apps:
/// to add one, add a case here, its `name`, and its `Target` in `Installer.target(for:)`.
public enum Harness: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case codex
    case cursor
    case vscode
    case gemini
    case windsurf

    /// The apps for a command-line name: a raw value, or `claude` for both Claude apps.
    public static func named(_ name: String) -> [Harness]? {
        if name == "claude" {
            return [.claudeCode, .claudeDesktop]
        }
        return Harness(rawValue: name).map { [$0] }
    }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude app"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .gemini: "Gemini CLI"
        case .windsurf: "Windsurf (Devin)"
        }
    }
}

/// Where the installer looks for apps and writes files.
public struct InstallEnvironment: Sendable {
    public var home: URL
    /// Folders that hold `.app` bundles.
    public var applications: [URL]
    /// Folders searched for command-line tools such as `claude` and `codex`.
    public var binaries: [URL]
    public var mcpURL: String
    /// The `tilde-mcp` stdio bridge, for apps that only start stdio servers.
    public var bridgePath: String

    public init(home: URL, applications: [URL], binaries: [URL], mcpURL: String, bridgePath: String) {
        self.home = home
        self.applications = applications
        self.binaries = binaries
        self.mcpURL = mcpURL
        self.bridgePath = bridgePath
    }

    /// The user's real home. With `isolated`, only folders inside `home` are searched, so a
    /// temporary home sees no apps or tools from the rest of the system.
    public static func standard(home: URL, port: String, bridgePath: String, isolated: Bool = false) -> InstallEnvironment {
        var applications = [home.appendingPathComponent("Applications")]
        var binaries = [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", "bin"].map { home.appendingPathComponent($0) }
        if !isolated {
            applications.insert(URL(fileURLWithPath: "/Applications"), at: 0)
            binaries += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            binaries += path.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return InstallEnvironment(
            home: home, applications: applications, binaries: binaries,
            mcpURL: "http://127.0.0.1:\(port)/mcp", bridgePath: bridgePath
        )
    }
}

public enum InstallStatus: Equatable, Sendable {
    /// The app's config has Tilde's current entry.
    case installed
    /// Of several apps on this Mac, some have Tilde's current entry and some do not.
    case partlyInstalled
    /// The app is on this Mac without Tilde's current entry.
    case notInstalled
    case notFound
    /// The app's config cannot be read, for example because it is not valid JSON.
    case failed(String)
}

/// What one install or uninstall did to one app.
public struct InstallReport: Sendable {
    public let harness: Harness
    public let dryRun: Bool
    public internal(set) var changes: [FileChange] = []

    public var hasChanges: Bool {
        changes.contains { $0.action.isChange }
    }

    /// One line per file, then what to restart. Paths inside `home` start with `~`.
    public func summary(home: URL) -> [String] {
        // Backups name the home through /private/tmp or /tmp, as the file system gives it.
        let homes = Set([home.path, home.standardizedFileURL.path, home.resolvingSymlinksInPath().path])
        func short(_ url: URL) -> String {
            let path = url.path
            guard let homePath = homes.first(where: { path.hasPrefix($0 + "/") }) else {
                return path
            }
            return "~" + path.dropFirst(homePath.count)
        }

        var lines = changes.map { change in
            let file = short(change.file)
            switch change.action {
            case .created:
                return dryRun ? "Would create \(file)" : "Created \(file)"
            case .updated:
                let backup = change.backup.map { " (backup: \(short($0)))" } ?? ""
                return dryRun ? "Would update \(file)" : "Updated \(file)\(backup)"
            case .removed:
                return dryRun ? "Would remove \(file)" : "Removed \(file)"
            case .unchanged:
                return "Already set: \(file)"
            case .failed(let message):
                return "Could not change \(file): \(message)"
            }
        }
        if changes.first?.action.isChange == true, !dryRun {
            lines.append("Restart \(harness.name) to load the change.")
        }
        return lines
    }
}

public struct FileChange: Sendable {
    public enum Action: Sendable, Equatable {
        case created
        case updated
        case removed
        case unchanged
        case failed(String)

        public var isChange: Bool {
            self == .created || self == .updated || self == .removed
        }
    }

    public let file: URL
    public let action: Action
    /// The copy of the file from before the change.
    public let backup: URL?
}

/// Adds Tilde's MCP server entry and skill to agent apps, and removes them again.
/// Each config keeps everything that is not Tilde's; a changed file gets a timestamped backup.
public struct Installer {
    public let environment: InstallEnvironment
    /// Reports what would change without writing.
    public var dryRun = false

    public init(environment: InstallEnvironment) {
        self.environment = environment
    }

    public func status(of harness: Harness) -> InstallStatus {
        guard isPresent(harness) else {
            return .notFound
        }
        let target = target(for: harness)
        let text = (try? String(contentsOf: target.config, encoding: .utf8)) ?? ""
        do {
            return try target.format.entry(in: text) ? .installed : .notInstalled
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// The status of several apps together, counting only the ones on this Mac.
    public func status(of harnesses: [Harness]) -> InstallStatus {
        let statuses = harnesses.map { status(of: $0) }.filter { $0 != .notFound }
        if statuses.isEmpty {
            return .notFound
        }
        if let failure = statuses.first(where: { if case .failed = $0 { true } else { false } }) {
            return failure
        }
        if statuses.allSatisfy({ $0 == .installed }) {
            return .installed
        }
        if statuses.contains(.installed) {
            return .partlyInstalled
        }
        return .notInstalled
    }

    public func isPresent(_ harness: Harness) -> Bool {
        let target = target(for: harness)
        let fileManager = FileManager.default
        let paths = target.detect.paths.map { environment.home.appendingPathComponent($0) }
        let apps = environment.applications.flatMap { folder in target.detect.apps.map { folder.appendingPathComponent($0) } }
        let tools = environment.binaries.flatMap { folder in target.detect.binaries.map { folder.appendingPathComponent($0) } }
        return (paths + apps + tools).contains { fileManager.fileExists(atPath: $0.path) }
    }

    /// The MCP config file that Tilde writes for the app.
    public func configFile(for harness: Harness) -> URL {
        target(for: harness).config
    }

    /// The `SKILL.md` that Tilde writes for the app.
    public func skillFile(for harness: Harness) -> URL {
        target(for: harness).skillFile
    }

    /// The newest backup that Tilde made of the app's config file.
    public func latestBackup(for harness: Harness) -> URL? {
        let config = target(for: harness).config.resolvingSymlinksInPath()
        let folder = config.deletingLastPathComponent()
        let prefix = "\(config.lastPathComponent).tilde-backup-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // Timestamps sort as text; a "-2" suffix sorts after the backup it follows.
        return names.filter { $0.hasPrefix(prefix) }.max().map { folder.appendingPathComponent($0) }
    }

    /// The app's bundle on this Mac, for its icon. A command-line tool gives its maker's app.
    public func appBundle(for harness: Harness) -> URL? {
        let target = target(for: harness)
        return (target.detect.apps + target.iconApps).lazy
            .flatMap { name in environment.applications.map { $0.appendingPathComponent(name) } }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func install(_ harness: Harness) -> InstallReport {
        let target = target(for: harness)
        var report = InstallReport(harness: harness, dryRun: dryRun)
        report.changes.append(edit(target.config) { try target.format.installing(in: $0) })
        report.changes.append(edit(target.skillFile) { _ in tildeSkill })
        return report
    }

    public func uninstall(_ harness: Harness) -> InstallReport {
        let target = target(for: harness)
        var report = InstallReport(harness: harness, dryRun: dryRun)
        if FileManager.default.fileExists(atPath: target.config.path) {
            report.changes.append(edit(target.config) { try target.format.removing(from: $0) })
        }
        // A skill folder can be shared by several apps; it goes when the last of them is uninstalled.
        let sharing = Harness.allCases.filter { $0 != harness && self.target(for: $0).skills == target.skills && status(of: $0) == .installed }
        if sharing.isEmpty, let text = try? String(contentsOf: target.skillFile, encoding: .utf8), text == tildeSkill {
            report.changes.append(remove(target.skillFile))
        }
        return report
    }

    // MARK: - Files

    /// Rewrites `file` with `change`, which gets the current text ("" for a missing file).
    /// Writes through symbolic links, such as a skills folder that links into a dotfiles repository.
    private func edit(_ file: URL, _ change: (String) throws -> String) -> FileChange {
        let fileManager = FileManager.default
        let real = file.resolvingSymlinksInPath()
        let exists = fileManager.fileExists(atPath: real.path)

        do {
            let old = exists ? try String(contentsOf: real, encoding: .utf8) : ""
            let new = try change(old)
            guard new != old || !exists else {
                return FileChange(file: file, action: .unchanged, backup: nil)
            }
            if dryRun {
                return FileChange(file: file, action: exists ? .updated : .created, backup: nil)
            }

            var backup: URL?
            if exists {
                backup = backupURL(for: real)
                try fileManager.copyItem(at: real, to: backup!)
            }
            try fileManager.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(new.utf8).write(to: real, options: .atomic)
            return FileChange(file: file, action: exists ? .updated : .created, backup: backup)
        } catch {
            return FileChange(file: file, action: .failed(String(describing: error)), backup: nil)
        }
    }

    /// Removes a skill file Tilde wrote, and its folder when nothing else is in it.
    private func remove(_ file: URL) -> FileChange {
        if dryRun {
            return FileChange(file: file, action: .removed, backup: nil)
        }

        let fileManager = FileManager.default
        let real = file.resolvingSymlinksInPath()
        do {
            try fileManager.removeItem(at: real)
            let folder = real.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try fileManager.removeItem(at: folder)
            }
            return FileChange(file: file, action: .removed, backup: nil)
        } catch {
            return FileChange(file: file, action: .failed(String(describing: error)), backup: nil)
        }
    }

    private func backupURL(for file: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(file.lastPathComponent).tilde-backup-\(formatter.string(from: Date()))"

        var url = file.deletingLastPathComponent().appendingPathComponent(base)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = file.deletingLastPathComponent().appendingPathComponent("\(base)-\(number)")
            number += 1
        }
        return url
    }
}

// MARK: - Targets

/// Where one app keeps its MCP config and skills, and how to find out that it is installed.
struct Target {
    struct Detection {
        var paths: [String] = []
        var apps: [String] = []
        var binaries: [String] = []
    }

    let config: URL
    let format: ConfigFormat
    let skills: URL
    let detect: Detection
    /// Apps whose icon stands for a command-line tool; they do not count as the tool being installed.
    var iconApps: [String] = []

    var skillFile: URL {
        skills.appendingPathComponent("tilde/SKILL.md")
    }
}

enum ConfigFormat {
    /// `path` leads to Tilde's member, such as `["mcpServers", "tilde"]`.
    case json(path: [String], entry: JSONValue)
    /// A `[mcp_servers.tilde]` table.
    case toml(table: String, lines: [String])

    /// Whether the text holds exactly Tilde's entry.
    func entry(in text: String) throws -> Bool {
        switch self {
        case .json(let path, let entry):
            let current = try JSONEditor(text).value(at: path)
            return (current as? NSDictionary)?.isEqual(entry.foundation) == true
        case .toml(let table, let lines):
            return try TOMLEditor(text).table(table) == lines
        }
    }

    func installing(in text: String) throws -> String {
        if try entry(in: text) {
            return text
        }
        switch self {
        case .json(let path, let entry):
            var editor = JSONEditor(text)
            try editor.set(path, to: entry)
            return editor.text.hasSuffix("\n") ? editor.text : editor.text + "\n"
        case .toml(let table, let lines):
            var editor = TOMLEditor(text)
            try editor.set(table, to: lines)
            return editor.text
        }
    }

    func removing(from text: String) throws -> String {
        switch self {
        case .json(let path, _):
            var editor = JSONEditor(text)
            return try editor.remove(path) ? editor.text : text
        case .toml(let table, _):
            var editor = TOMLEditor(text)
            return try editor.remove(table) ? editor.text : text
        }
    }
}

extension Installer {
    func target(for harness: Harness) -> Target {
        let home = environment.home
        let url = JSONValue.string(environment.mcpURL)
        // Claude reads only its own folder. The other apps all read ~/.agents/skills; Cursor and
        // VS Code also read ~/.claude/skills, so they get one skill folder in common with Claude.
        let claudeSkills = home.appendingPathComponent(".claude/skills")
        let agentSkills = home.appendingPathComponent(".agents/skills")

        switch harness {
        case .claudeCode:
            return Target(
                config: home.appendingPathComponent(".claude.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: .object([.init(key: "type", value: .string("http")), .init(key: "url", value: url)])),
                skills: claudeSkills,
                detect: Target.Detection(paths: [".claude.json"], binaries: ["claude"]),
                iconApps: ["Claude.app"]
            )
        case .claudeDesktop:
            return Target(
                config: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: .object([.init(key: "command", value: .string(environment.bridgePath))])),
                skills: claudeSkills,
                detect: Target.Detection(paths: ["Library/Application Support/Claude"], apps: ["Claude.app"])
            )
        case .codex:
            return Target(
                config: home.appendingPathComponent(".codex/config.toml"),
                format: .toml(table: "mcp_servers.tilde", lines: [
                    "[mcp_servers.tilde]",
                    "url = \"\(environment.mcpURL)\"",
                    "default_tools_approval_mode = \"approve\"",
                ]),
                skills: agentSkills,
                detect: Target.Detection(paths: [".codex"], apps: ["Codex.app"], binaries: ["codex"]),
                iconApps: ["ChatGPT.app"]
            )
        case .cursor:
            return Target(
                config: home.appendingPathComponent(".cursor/mcp.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: .object([.init(key: "url", value: url)])),
                skills: agentSkills,
                detect: Target.Detection(paths: [".cursor"], apps: ["Cursor.app"])
            )
        case .vscode:
            return Target(
                config: home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"),
                format: .json(path: ["servers", "tilde"], entry: .object([.init(key: "type", value: .string("http")), .init(key: "url", value: url)])),
                skills: agentSkills,
                detect: Target.Detection(paths: ["Library/Application Support/Code/User"], apps: ["Visual Studio Code.app"], binaries: ["code"])
            )
        case .gemini:
            return Target(
                config: home.appendingPathComponent(".gemini/settings.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: .object([.init(key: "httpUrl", value: url)])),
                skills: agentSkills,
                detect: Target.Detection(paths: [".gemini/settings.json"], binaries: ["gemini"])
            )
        case .windsurf:
            return Target(
                // Windsurf is now Devin Desktop; it moved its config from ~/.codeium/windsurf.
                config: home.appendingPathComponent(".config/devin/mcp_config.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: .object([.init(key: "serverUrl", value: url)])),
                skills: agentSkills,
                detect: Target.Detection(paths: [".config/devin", ".codeium/windsurf"], apps: ["Devin.app", "Windsurf.app"])
            )
        }
    }
}
