@testable import TildeInstaller
import Foundation
import Testing

/// Tilde's skill and command in each app: their names, the name a user chooses, other skills
/// of the same name, and the `tilde` skill of older versions.
struct SkillTests {
    let home: URL
    let installer: Installer

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-skills-\(UUID().uuidString)")
        let configs = [
            ".claude.json": "{}", ".codex/config.toml": "", ".cursor/mcp.json": "{}",
            "Library/Application Support/Code/User/mcp.json": "{}", ".gemini/settings.json": "{}", ".config/devin/mcp_config.json": "{}",
        ]
        for (path, text) in configs {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        installer = Installer(environment: .standard(home: home, port: "7311", bridgePath: "", isolated: true))
    }

    /// Where each app's files go under a name: the skill is the command, except in Gemini CLI.
    private func files(_ harness: Harness, _ name: String) -> [String] {
        switch harness {
        case .claudeCode: [".claude/skills/\(name)/SKILL.md"]
        case .gemini: [".gemini/skills/tilde-\(name)/SKILL.md", ".gemini/commands/\(name).toml"]
        case .codex, .cursor, .vscode, .windsurf: [".agents/skills/\(name)/SKILL.md"]
        }
    }

    @Test(arguments: Harness.allCases)
    func aFreshInstallWritesTheSkillUnderTheCommandName(harness: Harness) throws {
        let report = installer.install(harness)

        #expect(report.conflict == nil)
        #expect(installer.status(of: harness) == .installed)
        #expect(installer.skillStatus(of: harness) == .installed)
        for path in files(harness, "annotate") {
            let text = try read(path)
            #expect(Mark.isValid(text), "\(path)")
            if path.hasSuffix("SKILL.md") {
                // The name in the skill is its folder's, as the apps ask.
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                #expect(text.contains("\nname: \(folder)\n"), "\(path)")
            }
        }
        #expect(installer.invocation(for: harness) == (harness == .codex ? "$annotate" : "/annotate"))
        if harness == .gemini {
            #expect(try read(".gemini/commands/annotate.toml").contains("prompt = \"\"\"\n# Tilde\n"))
        }
    }

    @Test(arguments: Harness.allCases)
    func aNewNameMovesTildesFilesAndLeavesTheRest(harness: Harness) throws {
        _ = installer.install(harness)
        try write(".agents/skills/mine/SKILL.md", "---\nname: mine\n---\n")
        var renamed = installer
        renamed.command = "look"
        renamed.oldCommands = ["annotate"]

        let report = renamed.install(harness)

        #expect(report.conflict == nil)
        #expect(renamed.skillStatus(of: harness) == .installed)
        for path in files(harness, "look") {
            #expect(exists(path), "\(path)")
        }
        for path in files(harness, "annotate") {
            // A skill's folder goes with its file.
            let item = path.hasSuffix("/SKILL.md") ? String(path.dropLast("/SKILL.md".count)) : path
            #expect(!exists(item), "\(item)")
        }
        #expect(try read(".agents/skills/mine/SKILL.md") == "---\nname: mine\n---\n")
        #expect(try backupsInSkillFolders().isEmpty)
    }

    @Test(arguments: Harness.allCases)
    func anotherSkillOfTheNameStaysAsItWasAndShowsAWarning(harness: Harness) throws {
        let other = "---\nname: annotate\ndescription: Mine.\n---\n\nMy own steps.\n"
        let path = harness == .gemini ? ".gemini/commands/annotate.toml" : files(harness, "annotate")[0]
        try write(path, other)
        let configFile = installer.configFile(for: harness)
        let config = try String(contentsOf: configFile, encoding: .utf8)

        let report = installer.install(harness)

        let kind = harness == .gemini ? "command" : "skill"
        #expect(report.conflict?.message == "A \(kind) named annotate already exists in \(harness.name). Choose another command name.")
        #expect(report.changes.isEmpty)
        #expect(try read(path) == other)
        #expect(try String(contentsOf: configFile, encoding: .utf8) == config)
        #expect(installer.skillStatus(of: harness) == .taken(report.conflict!))
        #expect(report.summary(home: home).last == "\(report.conflict!.message) Nothing changed.")
    }

    @Test(arguments: Harness.allCases)
    func replaceMovesTheOtherSkillToTildesBackupsFirst(harness: Harness) throws {
        let other = "---\nname: annotate\n---\n\nMy own steps.\n"
        let path = harness == .gemini ? ".gemini/commands/annotate.toml" : files(harness, "annotate")[0]
        try write(path, other)

        let report = installer.install(harness, replace: true)

        #expect(report.conflict == nil)
        #expect(installer.skillStatus(of: harness) == .installed)
        let moved = try #require(report.changes.first)
        guard case .moved(let destination) = moved.action else {
            Issue.record("Expected a move, got \(moved.action)")
            return
        }
        #expect(destination.path.hasPrefix(home.appendingPathComponent("Library/Application Support/Tilde/Backups").path))
        let backup = harness == .gemini ? destination : destination.appendingPathComponent("SKILL.md")
        #expect(try String(contentsOf: backup, encoding: .utf8) == other)
        #expect(try backupsInSkillFolders().isEmpty)
    }

    /// Claude Code runs a skill before a command of the same name, so Tilde's skill would hide
    /// the user's command.
    @Test func aClaudeCommandOfTheNameIsAConflict() throws {
        try write(".claude/commands/annotate.md", "Do my thing.\n")

        let report = installer.install(.claudeCode)

        #expect(report.conflict?.message == "A command named annotate already exists in Claude Code. Choose another command name.")
        #expect(!exists(".claude/skills/annotate"))
    }

    /// Cursor also reads Claude's skills folder: a skill of the name there takes `/annotate`.
    @Test func aSkillInAnotherFolderThatTheAppReadsIsAConflict() throws {
        try write(".claude/skills/annotate/SKILL.md", "---\nname: annotate\n---\n")

        #expect(installer.install(.cursor).conflict?.item == home.appendingPathComponent(".claude/skills/annotate"))
        #expect(!exists(".agents/skills/annotate"))
        #expect(installer.install(.codex).conflict == nil)
    }

    /// Tilde's skill that the user changed is no longer provably Tilde's: it stays.
    @Test func tildesSkillChangedByTheUserIsAConflict() throws {
        _ = installer.install(.cursor)
        let changed = try read(".agents/skills/annotate/SKILL.md") + "\nMy own line.\n"
        try write(".agents/skills/annotate/SKILL.md", changed)

        #expect(installer.install(.cursor).conflict != nil)
        #expect(try read(".agents/skills/annotate/SKILL.md") == changed)
    }

    /// An app whose new name is taken keeps its old skill, also in a folder that it shares with
    /// an app that moves to the new name.
    @Test func aSharedOldSkillStaysForAnAppWhoseNewNameIsTaken() throws {
        _ = installer.install(.codex)
        _ = installer.install(.cursor)
        try write(".claude/skills/look/SKILL.md", "---\nname: look\n---\n")
        var renamed = installer
        renamed.command = "look"
        renamed.oldCommands = ["annotate"]

        #expect(renamed.install(.codex).conflict == nil)
        #expect(renamed.install(.cursor).conflict != nil)

        #expect(exists(".agents/skills/look/SKILL.md"))
        #expect(exists(".agents/skills/annotate/SKILL.md"))
    }

    // MARK: - The `tilde` skill of older versions

    @Test(arguments: Harness.allCases)
    func anUpdateRemovesTheOldTildeSkillThatTildeWrote(harness: Harness) throws {
        _ = installer.install(harness)
        let old = harness == .claudeCode ? ".claude/skills/tilde" : ".agents/skills/tilde"
        try write("\(old)/SKILL.md", Self.oldSkill)
        try write("\(old)/SKILL.md.tilde-backup-20261103-112033", "---\nname: tilde\n---\n")

        let report = try #require(installer.migrate(harness))

        #expect(report.conflict == nil)
        #expect(!exists(old))
        #expect(installer.skillStatus(of: harness) == .installed)
        #expect(try backupsInSkillFolders().isEmpty)
        let backups = try FileManager.default.subpathsOfDirectory(atPath: home.appendingPathComponent("Library/Application Support/Tilde/Backups").path)
        #expect(backups.contains { $0.hasSuffix("\(old)/SKILL.md.tilde-backup-20261103-112033") })
        #expect(installer.migrate(harness).map(\.harness) == nil)
    }

    @Test func anOldTildeSkillThatTheUserChangedStaysWithoutAWarning() throws {
        _ = installer.install(.codex)
        let changed = Self.oldSkill + "\nMy own line.\n"
        try write(".agents/skills/tilde/SKILL.md", changed)

        #expect(installer.migrate(.codex).map(\.harness) == nil)
        _ = installer.install(.codex)

        #expect(try read(".agents/skills/tilde/SKILL.md") == changed)
        #expect(installer.skillStatus(of: .codex) == .installed)
    }

    @Test func theFirstOldTextIsKnownToo() throws {
        let first = Self.oldSkill
            .replacingOccurrences(of: "disable-model-invocation: true\n", with: "")
            .replacingOccurrences(of: "are missing or cannot be reached, say in one line that the user must open Tilde on their Mac.", with: "are missing, say in one line that the user must open Tilde.")
        #expect(Mark.isLegacySkill(first))
        #expect(Mark.isLegacySkill(Self.oldSkill))
    }

    @Test func uninstallRemovesTildesFilesUnderEveryName() throws {
        _ = installer.install(.gemini)
        try write(".agents/skills/tilde/SKILL.md", Self.oldSkill)

        _ = installer.uninstall(.gemini)

        #expect(!exists(".gemini/skills/tilde-annotate"))
        #expect(!exists(".gemini/commands/annotate.toml"))
        #expect(!exists(".agents/skills/tilde"))
    }

    @Test func aCommandNameHasOnlyLowercaseLettersDigitsAndHyphens() {
        #expect(CommandName.problem("annotate") == nil)
        #expect(CommandName.problem("look-2") == nil)
        #expect(CommandName.problem("") == "Enter a name.")
        #expect(CommandName.problem("Annotate") == "Use only lowercase letters, digits and hyphens.")
        #expect(CommandName.problem("my skill") == "Use only lowercase letters, digits and hyphens.")
        #expect(CommandName.problem("-look") == "Start and end with a letter or digit, with no double hyphen.")
        #expect(CommandName.problem(String(repeating: "a", count: 59)) == "Use at most 58 characters.")
    }

    // MARK: - Helpers

    /// The `tilde` skill as versions up to 0.x wrote it.
    static let oldSkill = """
    ---
    name: tilde
    description: Get visual feedback from the user with Tilde. Use for /tilde and "annotate with Tilde".
    disable-model-invocation: true
    ---

    # Tilde

    1. First action: call `start_annotation` from the `tilde` MCP server. Do not read files, run commands or explain first.
    2. Pass `url` only if the user gave one or it is already known in this conversation, such as a dev server you started. Never search for one.
    3. While the result says that the user is still annotating, call `wait_for_annotation` with the `session_id` and `wait_seconds` 600. Write nothing between calls.
    4. When the feedback arrives, quote each annotation briefly (target and comment), then act on it. If a comment is a question or is unclear, answer or ask first.
    5. If the user cancelled, stop. If the `tilde` tools are missing or cannot be reached, say in one line that the user must open Tilde on their Mac.

    Each annotation has a close-up (primary) and a context image (secondary); look at the context image only if the close-up is not enough. Feedback the user sent earlier is in the resource `tilde://feedback/latest`.

    """

    /// Files whose name says they are a backup, in any folder that an app reads skills or commands from.
    private func backupsInSkillFolders() throws -> [String] {
        let folders = [".claude/skills", ".claude/commands", ".agents/skills", ".gemini/skills", ".gemini/commands", ".cursor/skills"]
        return folders.flatMap { folder in
            (FileManager.default.subpaths(atPath: home.appendingPathComponent(folder).path) ?? []).filter { $0.contains("backup") }
        }
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
