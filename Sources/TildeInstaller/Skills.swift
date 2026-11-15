import CryptoKit
import Foundation
import TildeSkill

/// The name of the command that starts Tilde in an agent, such as `annotate` for `/annotate`.
public enum CommandName {
    public static let standard = "annotate"
    /// The name of Tilde's skill before the command had a setting.
    static let legacy = "tilde"

    /// Why `name` cannot be a command name, or nil when it can. A name is also a folder name
    /// and a skill name, which agents limit to 64 characters; Gemini CLI's skill adds `tilde-`.
    public static func problem(_ name: String) -> String? {
        if name.isEmpty {
            return "Enter a name."
        }
        if !name.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) {
            return "Use only lowercase letters, digits and hyphens."
        }
        if name.hasPrefix("-") || name.hasSuffix("-") || name.contains("--") {
            return "Start and end with a letter or digit, with no double hyphen."
        }
        if name.count > 58 {
            return "Use at most 58 characters."
        }
        return nil
    }
}

/// A skill or command of the same name as Tilde's, which Tilde did not write.
public struct Conflict: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case skill
        case command
    }

    public let kind: Kind
    public let name: String
    public let harness: Harness
    /// The other skill's folder, or the other command's file.
    public let item: URL

    public init(kind: Kind, name: String, harness: Harness, item: URL) {
        self.kind = kind
        self.name = name
        self.harness = harness
        self.item = item
    }

    public var message: String {
        "A \(kind.rawValue) named \(name) already exists in \(harness.name). Choose another command name."
    }
}

public enum SkillStatus: Equatable, Sendable {
    /// Tilde's skill, and command where the app has one, under the current name.
    case installed
    case missing
    /// The name is another skill's or command's.
    case taken(Conflict)
}

/// Tilde's mark on a file it writes: a line that ends `tilde-checksum: <SHA-256>`, where the
/// checksum is of the file without that line. A file with a correct mark is Tilde's text as
/// Tilde wrote it; any change by hand, or a copied mark, makes the check fail.
enum Mark {
    private static let key = "tilde-checksum: "

    /// The text that `make` gives for the checksum, with the checksum of that text.
    static func signed(_ make: (String) -> String) -> String {
        let unsigned = withoutMarkLine(make(String(repeating: "0", count: 64)))
        return make(checksum(unsigned ?? ""))
    }

    static func isValid(_ text: String) -> Bool {
        guard let range = text.range(of: key) else {
            return false
        }
        let value = text[range.upperBound...].prefix { $0 != "\n" }
        return value.count == 64 && withoutMarkLine(text).map(checksum) == String(value)
    }

    private static func withoutMarkLine(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains(key) }) else {
            return nil
        }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    private static func checksum(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the `tilde` skills that Tilde wrote before it marked its files.
    static let legacySkills: Set<String> = [
        "43babc27cd9f5d7069994946ec59b0d6dee9b167403a75b5f6eff7767e242c23",
        "1d08c429519cecf3855a34f55c4763087a98ca4adddcd8ce20d8c1383b8ce27c",
    ]

    static func isLegacySkill(_ text: String) -> Bool {
        legacySkills.contains(checksum(text))
    }
}

/// A file that Tilde writes so that the user can start it in an app.
struct SkillFile {
    let kind: Conflict.Kind
    let name: String
    let file: URL
    let text: String

    /// The skill's folder, or the command's file: what holds the name.
    var item: URL {
        kind == .skill ? file.deletingLastPathComponent() : file
    }
}

extension Installer {
    /// What the user types to start Tilde in the app: `$annotate` in Codex, which starts
    /// skills by `$`, else `/annotate`.
    public func invocation(for harness: Harness) -> String {
        (harness == .codex ? "$" : "/") + command
    }

    /// The skill, or for an app with commands the command, that Tilde writes: the file that
    /// Settings shows.
    public func skillFile(for harness: Harness) -> URL {
        skillFiles(for: harness, command: command).last!.file
    }

    /// Whether the app has Tilde's files under the current name, or another skill or command
    /// has that name.
    public func skillStatus(of harness: Harness) -> SkillStatus {
        if let conflict = try? conflict(in: harness) {
            return .taken(conflict)
        }
        let files = skillFiles(for: harness, command: command)
        let installed = files.allSatisfy { (try? self.files.read($0.file)) == $0.text }
        return installed ? .installed : .missing
    }

    /// A skill or command that the app reads, under a name that Tilde's would take, and that
    /// Tilde did not write. Throws when the files cannot be asked.
    public func conflict(in harness: Harness) throws -> Conflict? {
        let target = target(for: harness)
        var items = skillFiles(for: harness, command: command).map { ($0.kind, $0.name, $0.item) }
        if target.commands == nil {
            // An app whose skills are its commands: a skill of that name in any folder it reads.
            items += target.otherSkills.map { (.skill, command, $0.appendingPathComponent(command)) }
        }
        if let commands = target.commands, !commands.isTildes {
            items.append((.command, command, commands.file(command)))
        }

        for (kind, name, item) in items where try !isTildes(item, kind: kind) {
            return Conflict(kind: kind, name: name, harness: harness, item: item)
        }
        return nil
    }

    /// The files of Tilde's skill and command in the app under `command`.
    func skillFiles(for harness: Harness, command: String) -> [SkillFile] {
        let target = target(for: harness)
        guard let commands = target.commands, commands.isTildes else {
            let file = target.skills.appendingPathComponent("\(command)/SKILL.md")
            let text = Mark.signed { tildeSkill(name: command, checksum: $0) }
            return [SkillFile(kind: .skill, name: command, file: file, text: text)]
        }

        let name = "tilde-\(command)"
        let skill = SkillFile(
            kind: .skill, name: name, file: target.skills.appendingPathComponent("\(name)/SKILL.md"),
            text: Mark.signed { tildeSkill(name: name, checksum: $0) }
        )
        let file = SkillFile(kind: .command, name: command, file: commands.file(command), text: Mark.signed { tildeCommandTOML(checksum: $0) })
        return [skill, file]
    }

    /// Whether `item` is absent or Tilde's: a skill folder whose `SKILL.md`, or a command file,
    /// has Tilde's mark.
    func isTildes(_ item: URL, kind: Conflict.Kind) throws -> Bool {
        guard try files.exists(item) else {
            return true
        }
        let file = kind == .skill ? item.appendingPathComponent("SKILL.md") : item
        guard try files.exists(file) else {
            return false
        }
        return Mark.isValid(try files.read(file))
    }

    /// Tilde's files under earlier names in the app: the ones with Tilde's mark, and the
    /// `tilde` skill of older versions with their text. A file that the user changed stays.
    func oldSkillFiles(for harness: Harness) -> [URL] {
        let names = Set(oldCommands).subtracting([command])
        let marked = names.sorted().flatMap { skillFiles(for: harness, command: $0) }.map(\.file).filter { file in
            (try? files.read(file)).map(Mark.isValid) == true
        }
        let legacy = target(for: harness).legacySkill
        let isLegacy = command != CommandName.legacy && (try? files.read(legacy)).map(Mark.isLegacySkill) == true
        return marked + (isLegacy ? [legacy] : [])
    }

    /// Whether another app with Tilde reads `file`, or keeps it because its new name is taken.
    func isUsedByAnotherApp(_ file: URL, besides harness: Harness, includingOld: Bool) -> Bool {
        let file = files.resolved(file)
        return Harness.allCases.contains { other in
            guard other != harness, status(of: other) == .installed else {
                return false
            }
            if skillFiles(for: other, command: command).contains(where: { files.resolved($0.file) == file }) {
                return true
            }
            return includingOld && (try? conflict(in: other)) != nil && oldSkillFiles(for: other).map(files.resolved).contains(file)
        }
    }

    /// Removes a skill or command file that Tilde wrote, and its folder when it was a skill's
    /// and nothing else is in it. Backups that older versions left next to a `SKILL.md` go to
    /// Tilde's backup folder first, so that no backup stays in a skills folder.
    func removeSkillFile(_ file: URL, backupFolder: URL) -> [FileChange] {
        if dryRun {
            return [FileChange(file: file, action: .removed)]
        }

        do {
            let folder = file.deletingLastPathComponent()
            var changes: [FileChange] = []
            if file.lastPathComponent == "SKILL.md" {
                for name in try files.contents(of: folder) where name.hasPrefix("SKILL.md.tilde-backup-") {
                    let backup = folder.appendingPathComponent(name)
                    let destination = backupDestination(backup, in: backupFolder)
                    try files.move(backup, to: destination)
                    changes.append(FileChange(file: backup, action: .moved(to: destination)))
                }
            }
            try files.remove(file)
            if file.lastPathComponent == "SKILL.md" {
                files.removeFolderIfEmpty(folder)
            }
            return changes + [FileChange(file: file, action: .removed)]
        } catch {
            return [FileChange(file: file, action: .failed(String(describing: error)))]
        }
    }

    /// Where `item` goes in a backup folder: under its path from the home folder.
    func backupDestination(_ item: URL, in backupFolder: URL) -> URL {
        let home = environment.home.path + "/"
        let path = item.path.hasPrefix(home) ? String(item.path.dropFirst(home.count)) : String(item.path.drop { $0 == "/" })
        return backupFolder.appendingPathComponent(path)
    }

    /// A new folder for one install's backups in Tilde's own support folder.
    func newBackupFolder() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return environment.backups.appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))")
    }
}
