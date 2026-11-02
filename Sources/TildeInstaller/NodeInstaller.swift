import Foundation
import TildeSkill

/// Installs Tilde on another machine through a shell there. It writes one MCP entry and one small
/// skill for each agent it finds, and backs up each file that it changes.
public struct NodeInstaller {
    /// Runs a shell command on the node, with its standard input, and returns its output.
    public typealias Shell = (_ command: String, _ input: String?) throws -> String

    public let shell: Shell
    /// The address on the node, which a tunnel leads to this Mac.
    public let mcpURL: String

    public init(mcpURL: String, shell: @escaping Shell) {
        self.mcpURL = mcpURL
        self.shell = shell
    }

    /// What was done and what was left out, for the user.
    public struct Report: Equatable, Sendable {
        public var changed: [String] = []
        public var skipped: [String] = []
    }

    private enum Agent: CaseIterable {
        case claude, codex
    }

    public func install(token: String) throws -> Report {
        var report = Report()
        let found = try agents()
        guard !found.isEmpty else {
            report.skipped.append("No Claude Code or Codex there")
            return report
        }

        for agent in found {
            let (config, format) = target(agent, token: token)
            if try edit(config, { try format.installing(in: $0) }) {
                report.changed.append(config)
            }
            try writeSkill(skillFile(agent), report: &report)
        }
        return report
    }

    public func uninstall() throws -> Report {
        var report = Report()
        for agent in try agents() {
            let (config, format) = target(agent, token: "")
            if try edit(config, { try format.removing(from: $0) }) {
                report.changed.append(config)
            }
            let skill = skillFile(agent)
            // Only the skill that Tilde wrote, unchanged.
            if (try? shell("cat \(skill)", nil)) == nodeSkill {
                _ = try shell("rm -f \(skill) && rmdir \(skillFolder(skill)) 2>/dev/null; true", nil)
                report.changed.append(skill)
            }
        }
        return report
    }

    private func agents() throws -> [Agent] {
        let output = try shell("[ -e ~/.claude ] || [ -e ~/.claude.json ] && echo claude; [ -e ~/.codex ] && echo codex; true", nil)
        let names = output.split(whereSeparator: \.isNewline).map(String.init)
        return Agent.allCases.filter { names.contains($0 == .claude ? "claude" : "codex") }
    }

    private func target(_ agent: Agent, token: String) -> (String, ConfigFormat) {
        switch agent {
        case .claude:
            let headers = JSONValue.object([.init(key: "Authorization", value: .string("Bearer \(token)"))])
            let entry = JSONValue.object([
                .init(key: "type", value: .string("http")),
                .init(key: "url", value: .string(mcpURL)),
                .init(key: "headers", value: headers),
            ])
            return ("~/.claude.json", .json(path: ["mcpServers", "tilde"], entry: entry))
        case .codex:
            return ("~/.codex/config.toml", .toml(table: "mcp_servers.tilde", lines: [
                "[mcp_servers.tilde]",
                "url = \"\(mcpURL)\"",
                "http_headers = { Authorization = \"Bearer \(token)\" }",
                "default_tools_approval_mode = \"approve\"",
            ]))
        }
    }

    private func skillFile(_ agent: Agent) -> String {
        agent == .claude ? "~/.claude/skills/tilde/SKILL.md" : "~/.agents/skills/tilde/SKILL.md"
    }

    private func skillFolder(_ skill: String) -> String {
        String(skill.dropLast("/SKILL.md".count))
    }

    /// A skills folder or a skill that links elsewhere belongs to something else, such as a
    /// config repository: Tilde does not write into it.
    private func writeSkill(_ skill: String, report: inout Report) throws {
        let folder = skillFolder(skill)
        let parts = folder.split(separator: "/").map(String.init)
        let chain = (2...parts.count).map { parts[0..<$0].joined(separator: "/") }
        let isLinked = chain.map { "[ -L \($0) ]" }.joined(separator: " || ")
        let answer = try shell("if \(isLinked); then echo linked; fi", nil)
        if answer.contains("linked") {
            report.skipped.append("\(skill): its folder links elsewhere")
            return
        }
        if try edit(skill, { _ in nodeSkill }) {
            report.changed.append(skill)
        }
    }

    /// Rewrites a file with `change`, keeping a copy of what it replaces. True if it changed.
    private func edit(_ file: String, _ change: (String) throws -> String) throws -> Bool {
        let old = (try? shell("cat \(file) 2>/dev/null", nil)) ?? ""
        let new = try change(old)
        guard new != old else {
            return false
        }

        let folder = file.split(separator: "/").dropLast().joined(separator: "/")
        let temporary = "\(file).tilde-new"
        let backup = old.isEmpty ? "true" : "cp \(file) \(file).tilde-backup-$(date +%Y%m%d-%H%M%S)"
        _ = try shell("mkdir -p \(folder) && \(backup) && cat > \(temporary) && mv \(temporary) \(file)", new)
        return true
    }
}
