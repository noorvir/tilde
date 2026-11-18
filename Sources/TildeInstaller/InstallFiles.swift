import Foundation

/// The file operations of an install: on this Mac, or on another machine through a shell.
public protocol InstallFiles: Sendable {
    /// Throws when the files cannot be asked, such as on a machine that does not answer: that
    /// is not "no file".
    func exists(_ file: URL) throws -> Bool
    /// The first of the files that is there; nil when none is.
    func firstExisting(_ files: [URL]) throws -> URL?
    func read(_ file: URL) throws -> String
    /// Writes through symbolic links, creating the folders on the way. A file it replaces is
    /// for its owner only (0600): agents' configs hold tokens, such as Tilde's on a machine.
    func write(_ text: String, to file: URL) throws
    /// Makes a file, or the target of a link, for its owner only (0600), such as a config
    /// written by an older Tilde that already has the right text.
    func makePrivate(_ file: URL) throws
    func remove(_ file: URL) throws
    func removeFolderIfEmpty(_ folder: URL)
    /// The names in a folder; none when the folder is not there.
    func contents(of folder: URL) throws -> [String]
    /// Moves a file or folder, creating the destination's folders on the way. A link is moved
    /// as a link: what it points to stays where it is.
    func move(_ item: URL, to destination: URL) throws
    /// The path with its links followed, to tell whether two paths are one file, such as
    /// `~/.claude/skills` linked to `~/.agents/skills`. As given when it cannot be told.
    func resolved(_ file: URL) -> URL
}

extension InstallFiles {
    public func firstExisting(_ files: [URL]) throws -> URL? {
        try files.first { try exists($0) }
    }
}

public struct LocalFiles: InstallFiles {
    public init() {}

    public func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    public func read(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    public func write(_ text: String, to file: URL) throws {
        let real = file.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The new file is never readable by others, not even before it replaces the old one.
        let temporary = real.appendingPathExtension("tilde-new")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, real.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: real.path])
        }
    }

    public func makePrivate(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.resolvingSymlinksInPath().path)
    }

    public func remove(_ file: URL) throws {
        try FileManager.default.removeItem(at: file.resolvingSymlinksInPath())
    }

    public func removeFolderIfEmpty(_ folder: URL) {
        let real = folder.resolvingSymlinksInPath()
        if (try? FileManager.default.contentsOfDirectory(atPath: real.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: real)
        }
    }

    public func contents(of folder: URL) throws -> [String] {
        let real = folder.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: real.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: real.path).sorted()
    }

    public func move(_ item: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: item, to: destination)
    }

    public func resolved(_ file: URL) -> URL {
        file.resolvingSymlinksInPath()
    }
}

/// The same operations on another machine. `run` runs a shell command there, with its standard
/// input, and throws when the command fails.
public struct ShellFiles: InstallFiles {
    public typealias Run = @Sendable (_ command: String, _ input: String?) throws -> String

    public let run: Run

    public init(run: @escaping Run) {
        self.run = run
    }

    private func quoted(_ file: URL) -> String {
        "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command succeeds for a file that is not there too: only then does a failed
    /// command, such as a dropped connection, never read as "no file".
    public func exists(_ file: URL) throws -> Bool {
        let answer = try run("if [ -e \(quoted(file)) ]; then echo yes; else echo no; fi", nil)
        return answer.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    /// In one command, as each command is a round trip: an app is looked for in each folder
    /// of the machine's PATH.
    public func firstExisting(_ files: [URL]) throws -> URL? {
        guard !files.isEmpty else {
            return nil
        }
        let list = files.map(quoted).joined(separator: " ")
        let answer = try run("for file in \(list); do if [ -e \"$file\" ]; then printf '%s' \"$file\"; break; fi; done; true", nil)
        return files.first { $0.path == answer.trimmingCharacters(in: .newlines) }
    }

    public func read(_ file: URL) throws -> String {
        try run("cat \(quoted(file))", nil)
    }

    /// As on this Mac: a link is followed and its target replaced, never written in place, so
    /// a dropped connection leaves the old file and the new one is 0600 from the start.
    public func write(_ text: String, to file: URL) throws {
        let folder = quoted(file.deletingLastPathComponent())
        let target = "target=\(quoted(file)) && if [ -L \"$target\" ]; then target=$(readlink -f \"$target\"); fi"
        _ = try run("mkdir -p \(folder) && \(target) && (umask 077 && cat > \"$target.tilde-new\") && mv \"$target.tilde-new\" \"$target\"", text)
    }

    public func makePrivate(_ file: URL) throws {
        _ = try run("target=\(quoted(file)) && if [ -L \"$target\" ]; then target=$(readlink -f \"$target\"); fi && chmod 600 \"$target\"", nil)
    }


    public func remove(_ file: URL) throws {
        _ = try run("rm \(quoted(file))", nil)
    }

    public func removeFolderIfEmpty(_ folder: URL) {
        _ = try? run("rmdir \(quoted(folder))", nil)
    }

    public func contents(of folder: URL) throws -> [String] {
        let output = try run("if [ -d \(quoted(folder)) ]; then ls -A \(quoted(folder)); fi", nil)
        return output.split(separator: "\n").map(String.init).sorted()
    }

    public func move(_ item: URL, to destination: URL) throws {
        _ = try run("mkdir -p \(quoted(destination.deletingLastPathComponent())) && mv \(quoted(item)) \(quoted(destination))", nil)
    }

    /// As given: one more command for each file is not worth it.
    public func resolved(_ file: URL) -> URL {
        file
    }
}
