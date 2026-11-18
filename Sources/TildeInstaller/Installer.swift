import Foundation
import TildeSkill

/// An agent app that Tilde can add its MCP server and skill to. This is the list of known apps:
/// to add one, add a case here, its `name`, and its `Target` in `Installer.target(for:)`.
public enum Harness: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case vscode
    case gemini
    case windsurf

    /// The app for a command-line name: a raw value, or `claude` for Claude Code.
    public static func named(_ name: String) -> Harness? {
        if name == "claude" {
            return .claudeCode
        }
        return Harness(rawValue: name)
    }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
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
    /// The `Authorization` header of the MCP entries: the local token on this Mac, a node's
    /// token on a machine that reaches Tilde by a tunnel.
    public var authorization: String?
    /// A command and its arguments that the entries start as a stdio server instead of
    /// reaching `mcpURL`: on a machine linked by its socket, `tproxy` and the socket.
    public var proxy: [String]?
    /// Variables that move an app's folder, such as `CODEX_HOME`.
    public var variables: [String: String] = [:]
    /// A Linux machine, where some apps keep their config elsewhere, such as VS Code.
    public var isLinux = false
    /// Tilde's own folder for the backups that older versions left in skills folders. Never
    /// inside a skills folder, which may be a repository.
    public var backups: URL

    public init(home: URL, applications: [URL], binaries: [URL], mcpURL: String, bridgePath: String) {
        self.home = home
        self.applications = applications
        self.binaries = binaries
        self.mcpURL = mcpURL
        self.bridgePath = bridgePath
        backups = home.appendingPathComponent("Library/Application Support/Tilde/Backups")
    }

    /// This Mac: `standard`, with the local token that Tilde's listener asks for.
    public static func local(home: URL, port: String, bridgePath: String, isolated: Bool = false) throws -> InstallEnvironment {
        var environment = standard(home: home, port: port, bridgePath: bridgePath, isolated: isolated)
        environment.authorization = try LocalToken.authorization(home: home)
        return environment
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
    /// The name is another skill's or command's, so the install changed nothing.
    public internal(set) var conflict: Conflict?

    public var hasChanges: Bool {
        changes.contains { $0.action.isChange }
    }

    /// One line per file, then what to restart. Paths inside `home` start with `~`.
    public func summary(home: URL) -> [String] {
        // Paths can name the home through /private/tmp or /tmp, as the file system gives it.
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
                return dryRun ? "Would update \(file)" : "Updated \(file)"
            case .removed:
                return dryRun ? "Would remove \(file)" : "Removed \(file)"
            case .moved(let destination):
                return dryRun ? "Would move \(file) to \(short(destination))" : "Moved \(file) to \(short(destination))"
            case .unchanged:
                return "Already set: \(file)"
            case .unchangedNotPrivate(let message):
                return "Already set: \(file), but others may read it: \(message)"
            case .failed(let message):
                return "Could not change \(file): \(message)"
            }
        }
        if let conflict {
            lines.append("\(conflict.message) Nothing changed: choose another command name.")
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
        /// Moved to Tilde's backup folder.
        case moved(to: URL)
        case unchanged
        /// The right text, in a file that could not be made private, such as a read-only one.
        case unchangedNotPrivate(String)
        case failed(String)

        public var isChange: Bool {
            switch self {
            case .created, .updated, .removed, .moved: true
            case .unchanged, .unchangedNotPrivate, .failed: false
            }
        }

        public var isFailure: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    public let file: URL
    public let action: Action
}

/// Adds Tilde's MCP server entry and skill to agent apps, and removes them again.
/// Each config keeps everything that is not Tilde's, as it was: only Tilde's entry changes, and
/// the file is replaced in one step.
public struct Installer: Sendable {
    public let environment: InstallEnvironment
    public let files: InstallFiles
    /// Reports what would change without writing.
    public var dryRun = false
    /// The command that starts Tilde, such as `annotate` for `/annotate`.
    public var command = CommandName.standard
    /// The names that the command had before: Tilde's files under them go on the next install.
    public var oldCommands: [String] = []

    public init(environment: InstallEnvironment, files: InstallFiles = LocalFiles()) {
        self.environment = environment
        self.files = files
    }

    /// The installer of another machine, reached by a shell and a tunnel to `mcpURL`, or with
    /// `proxied`, by `tproxy` and its socket in the machine's `~/.tilde`. Its folders come
    /// from its login shell.
    public static func remote(mcpURL: String, authorization: String, proxied: Bool = false, run: @escaping ShellFiles.Run) throws -> Installer {
        let names = ["HOME", "PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME"]
        let printed = names.map { "\"$\($0)\"" }.joined(separator: " ")
        let output = try run("${SHELL:-/bin/sh} -lc 'printf \"%s\\n\" \(printed)' | tail -n \(names.count)", nil)
        let values = output.components(separatedBy: "\n")
        guard values.count >= names.count, values[0].hasPrefix("/") else {
            throw InstallerError.noHome
        }

        var environment = InstallEnvironment.standard(home: URL(fileURLWithPath: values[0]), port: "0", bridgePath: "", isolated: true)
        environment.isLinux = try run("uname -s", nil).trimmingCharacters(in: .whitespacesAndNewlines) == "Linux"
        environment.applications.insert(URL(fileURLWithPath: "/Applications"), at: 0)
        environment.binaries += values[1].split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        environment.mcpURL = mcpURL
        environment.authorization = authorization
        environment.backups = URL(fileURLWithPath: values[0] + "/.tilde/backups")
        if proxied {
            environment.proxy = [values[0] + "/.tilde/bin/tproxy", values[0] + "/.tilde/tilde.sock"]
        }
        for (name, value) in zip(names, values).dropFirst(2) where !value.isEmpty {
            environment.variables[name] = value
        }
        return Installer(environment: environment, files: ShellFiles(run: run))
    }

    public func status(of harness: Harness) -> InstallStatus {
        guard isPresent(harness) else {
            return .notFound
        }
        let target = target(for: harness)
        let text = (try? files.read(target.config)) ?? ""
        do {
            return try target.format.entry(in: text) ? .installed : .notInstalled
        } catch {
            return .failed(String(describing: error))
        }
    }

    public func isPresent(_ harness: Harness) -> Bool {
        let target = target(for: harness)
        let paths = target.detect.paths.map { environment.home.appendingPathComponent($0) } + target.detect.files
        let apps = environment.applications.flatMap { folder in target.detect.apps.map { folder.appendingPathComponent($0) } }
        let tools = environment.binaries.flatMap { folder in target.detect.binaries.map { folder.appendingPathComponent($0) } }
        return (try? files.firstExisting(paths + apps + tools)) != nil
    }

    /// The MCP config file that Tilde writes for the app.
    public func configFile(for harness: Harness) -> URL {
        target(for: harness).config
    }

    public func appBundle(for harness: Harness) -> URL? {
        let target = target(for: harness)
        return (target.detect.apps + target.iconApps).lazy
            .flatMap { name in environment.applications.map { $0.appendingPathComponent(name) } }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Adds Tilde's entry, and its skill and command under `command`, then removes Tilde's
    /// files under the old names. When the name is another skill's or command's, the install
    /// changes nothing and reports the conflict: Tilde never changes what it did not write.
    public func install(_ harness: Harness) -> InstallReport {
        install(harness, entry: true)
    }

    /// The install, with the app's MCP entry or only its skill.
    private func install(_ harness: Harness, entry: Bool) -> InstallReport {
        let target = target(for: harness)
        var report = InstallReport(harness: harness, dryRun: dryRun)
        let backups = newBackupFolder()
        do {
            if let conflict = try conflict(in: harness) {
                report.conflict = conflict
                return report
            }
        } catch {
            report.changes.append(FileChange(file: skillFile(for: harness), action: .failed(String(describing: error))))
            return report
        }

        if entry {
            report.changes.append(edit(target.config) { try target.format.installing(in: $0) })
        }
        for file in skillFiles(for: harness, command: command) {
            report.changes.append(edit(file.file) { _ in file.text })
        }
        for file in oldSkillFiles(for: harness) where !isUsedByAnotherApp(file, besides: harness, includingOld: true) {
            report.changes += removeSkillFile(file, backupFolder: backups)
        }
        return report
    }

    /// Moves Tilde's skill where the app has Tilde's files under an old name, such as the
    /// `tilde` skill of older versions or a name the user changed: they go, and the current
    /// ones come. The app's MCP entry stays as it is. Nil when there is nothing to move.
    public func migrate(_ harness: Harness) -> InstallReport? {
        oldSkillFiles(for: harness).isEmpty ? nil : install(harness, entry: false)
    }

    public func uninstall(_ harness: Harness) -> InstallReport {
        let target = target(for: harness)
        var report = InstallReport(harness: harness, dryRun: dryRun)
        do {
            if try files.exists(target.config) {
                report.changes.append(edit(target.config) { try target.format.removing(from: $0) })
            }
        } catch {
            report.changes.append(FileChange(file: target.config, action: .failed(String(describing: error))))
        }
        // A skill folder can be shared by several apps; a file goes when the last of them is uninstalled.
        let backups = newBackupFolder()
        let current = skillFiles(for: harness, command: command).map(\.file).filter { file in
            (try? files.read(file)).map(Mark.isValid) == true
        }
        for file in current + oldSkillFiles(for: harness) where !isUsedByAnotherApp(file, besides: harness, includingOld: false) {
            report.changes += removeSkillFile(file, backupFolder: backups)
        }
        return report
    }

    // MARK: - Files

    /// Rewrites `file` with `change`, which gets the current text ("" for a missing file).
    /// Writes through symbolic links, such as a skills folder that links into a dotfiles repository.
    private func edit(_ file: URL, _ change: (String) throws -> String) -> FileChange {
        do {
            // A file that cannot be asked about is not a missing one: its text must not be
            // replaced with only Tilde's entry.
            let exists = try files.exists(file)
            let old = exists ? try files.read(file) : ""
            let new = try change(old)
            guard new != old || !exists else {
                // The right text, maybe from an older Tilde that left it readable by others. A
                // file that cannot change, such as one linked into a read-only store, is left.
                if !dryRun {
                    do {
                        try files.makePrivate(file)
                    } catch {
                        return FileChange(file: file, action: .unchangedNotPrivate(String(describing: error)))
                    }
                }
                return FileChange(file: file, action: .unchanged)
            }
            if dryRun {
                return FileChange(file: file, action: exists ? .updated : .created)
            }

            try files.write(new, to: file)
            return FileChange(file: file, action: exists ? .updated : .created)
        } catch {
            return FileChange(file: file, action: .failed(String(describing: error)))
        }
    }
}

public enum InstallerError: Error {
    case noHome
}

// MARK: - Targets

/// Where one app keeps its MCP config and skills, and how to find out that it is installed.
struct Target {
    struct Detection {
        var paths: [String] = []
        /// Folders that a variable moved.
        var files: [URL] = []
        var apps: [String] = []
        var binaries: [String] = []
    }

    /// A folder of the app's command files, such as `annotate.toml` for `/annotate`.
    struct Commands {
        let folder: URL
        let fileExtension: String
        /// Tilde writes its command here, because the app starts skills only through the model.
        /// Otherwise the folder is only checked for a command that Tilde's skill would hide.
        let isTildes: Bool

        func file(_ name: String) -> URL {
            folder.appendingPathComponent("\(name).\(fileExtension)")
        }
    }

    let config: URL
    let format: ConfigFormat
    /// Where Tilde writes its skill.
    let skills: URL
    let detect: Detection
    /// Apps whose icon stands for a command-line tool; they do not count as the tool being installed.
    var iconApps: [String] = []
    /// Other folders that the app reads skills from: a skill there under Tilde's name takes the command.
    var otherSkills: [URL] = []
    var commands: Commands?
    /// Where versions before the command name wrote the `tilde` skill.
    var legacySkill: URL
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
    /// A config file that holds only the app's entry for Tilde, as Install writes it: the text
    /// to set up by hand an app of that kind that Tilde did not find.
    public func entryText(for harness: Harness) -> String {
        // An empty config always takes the entry.
        try! target(for: harness).format.installing(in: "")
    }

    func target(for harness: Harness) -> Target {
        let home = environment.home
        // An app's JSON entry: Tilde's URL under the app's key for it, with the token, or the
        // stdio command instead, such as `tproxy` on a machine linked by its socket. Apps
        // that name the transport take a `type` first.
        func server(urlKey: String, typed: Bool = false) -> JSONValue {
            var members: [JSONValue.Member]
            if let command = environment.proxy {
                let arguments = command.dropFirst().map(JSONValue.string)
                members = [.init(key: "command", value: .string(command[0])), .init(key: "args", value: .array(arguments))]
            } else {
                members = [.init(key: urlKey, value: .string(environment.mcpURL))]
                if let authorization = environment.authorization {
                    members.append(.init(key: "headers", value: .object([.init(key: "Authorization", value: .string(authorization))])))
                }
            }
            if typed {
                let type = environment.proxy == nil ? "http" : "stdio"
                members.insert(.init(key: "type", value: .string(type)), at: 0)
            }
            return .object(members)
        }

        let claudeFolder = environment.variables["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        let codexFolder = environment.variables["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        let configFolder = environment.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        // Claude reads only its own folder. The other apps all read ~/.agents/skills; Cursor and
        // VS Code also read ~/.claude/skills, so they get one skill folder in common with Claude.
        // The skill is named after the command in every app. It is the slash command, except
        // in Gemini CLI, which starts skills only through the model and so also gets a command
        // file of that name; Codex starts a skill with `$`.
        var codexServer = ["url = \"\(environment.mcpURL)\""] + (environment.authorization.map { ["http_headers = { Authorization = \"\($0)\" }"] } ?? [])
        if let command = environment.proxy {
            let args = command.dropFirst().map { "\"\($0)\"" }.joined(separator: ", ")
            codexServer = ["command = \"\(command[0])\"", "args = [\(args)]"]
        }
        let claudeSkills = claudeFolder?.appendingPathComponent("skills") ?? home.appendingPathComponent(".claude/skills")
        let agentSkills = home.appendingPathComponent(".agents/skills")
        let agentLegacy = agentSkills.appendingPathComponent("tilde/SKILL.md")

        switch harness {
        case .claudeCode:
            return Target(
                config: (claudeFolder ?? home).appendingPathComponent(".claude.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: server(urlKey: "url", typed: true)),
                skills: claudeSkills,
                detect: Target.Detection(paths: [".claude.json"], files: claudeFolder.map { [$0] } ?? [], binaries: ["claude"]),
                iconApps: ["Claude.app"],
                // Commands are Claude's older kind of skill: a skill of the same name hides one.
                commands: Target.Commands(folder: (claudeFolder ?? home.appendingPathComponent(".claude")).appendingPathComponent("commands"), fileExtension: "md", isTildes: false),
                legacySkill: claudeSkills.appendingPathComponent("tilde/SKILL.md")
            )
        case .codex:
            return Target(
                config: (codexFolder ?? home.appendingPathComponent(".codex")).appendingPathComponent("config.toml"),
                format: .toml(table: "mcp_servers.tilde", lines: ["[mcp_servers.tilde]"] + codexServer + ["default_tools_approval_mode = \"approve\""]),
                skills: agentSkills,
                detect: Target.Detection(paths: [".codex"], files: codexFolder.map { [$0] } ?? [], apps: ["Codex.app"], binaries: ["codex"]),
                iconApps: ["ChatGPT.app"],
                otherSkills: [(codexFolder ?? home.appendingPathComponent(".codex")).appendingPathComponent("skills")],
                legacySkill: agentLegacy
            )
        case .cursor:
            return Target(
                config: home.appendingPathComponent(".cursor/mcp.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: server(urlKey: "url")),
                skills: agentSkills,
                detect: Target.Detection(paths: [".cursor"], apps: ["Cursor.app"]),
                otherSkills: [claudeSkills, home.appendingPathComponent(".cursor/skills")],
                legacySkill: agentLegacy
            )
        case .vscode:
            let codeFolder = environment.isLinux ? configFolder.appendingPathComponent("Code/User") : home.appendingPathComponent("Library/Application Support/Code/User")
            return Target(
                config: codeFolder.appendingPathComponent("mcp.json"),
                format: .json(path: ["servers", "tilde"], entry: server(urlKey: "url", typed: true)),
                skills: agentSkills,
                detect: Target.Detection(files: [codeFolder], apps: ["Visual Studio Code.app"], binaries: ["code"]),
                otherSkills: [claudeSkills, home.appendingPathComponent(".copilot/skills")],
                legacySkill: agentLegacy
            )
        case .gemini:
            return Target(
                config: home.appendingPathComponent(".gemini/settings.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: server(urlKey: "httpUrl")),
                skills: agentSkills,
                detect: Target.Detection(paths: [".gemini/settings.json"], binaries: ["gemini"]),
                otherSkills: [home.appendingPathComponent(".gemini/skills")],
                commands: Target.Commands(folder: home.appendingPathComponent(".gemini/commands"), fileExtension: "toml", isTildes: true),
                legacySkill: agentLegacy
            )
        case .windsurf:
            return Target(
                // Windsurf's app is Devin Desktop, with its config in devin/; older versions had ~/.codeium/windsurf.
                config: configFolder.appendingPathComponent("devin/mcp_config.json"),
                format: .json(path: ["mcpServers", "tilde"], entry: server(urlKey: "serverUrl")),
                skills: agentSkills,
                detect: Target.Detection(paths: [".codeium/windsurf"], files: [configFolder.appendingPathComponent("devin")], apps: ["Devin.app", "Windsurf.app"]),
                otherSkills: [configFolder.appendingPathComponent("devin/skills"), home.appendingPathComponent(".codeium/windsurf/skills")],
                legacySkill: agentLegacy
            )
        }
    }
}
