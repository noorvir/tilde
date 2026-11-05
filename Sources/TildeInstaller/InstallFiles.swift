import Foundation

/// The file operations of an install: on this Mac, or on another machine through a shell.
public protocol InstallFiles: Sendable {
    func exists(_ file: URL) -> Bool
    func read(_ file: URL) throws -> String
    /// Writes through symbolic links, creating the folders on the way. A file it replaces is
    /// for its owner only (0600): agents' configs hold tokens, such as Tilde's on a machine.
    func write(_ text: String, to file: URL) throws
    func remove(_ file: URL) throws
    /// The names in a folder; none if it is not there.
    func names(in folder: URL) -> [String]
    func removeFolderIfEmpty(_ folder: URL)
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


    public func remove(_ file: URL) throws {
        try FileManager.default.removeItem(at: file.resolvingSymlinksInPath())
    }

    public func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.resolvingSymlinksInPath().path)) ?? []
    }

    public func removeFolderIfEmpty(_ folder: URL) {
        let real = folder.resolvingSymlinksInPath()
        if (try? FileManager.default.contentsOfDirectory(atPath: real.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: real)
        }
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

    public func exists(_ file: URL) -> Bool {
        (try? run("test -e \(quoted(file))", nil)) != nil
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


    public func remove(_ file: URL) throws {
        _ = try run("rm \(quoted(file))", nil)
    }

    public func names(in folder: URL) -> [String] {
        let list = (try? run("ls -A \(quoted(folder))", nil)) ?? ""
        return list.split(whereSeparator: \.isNewline).map(String.init)
    }

    public func removeFolderIfEmpty(_ folder: URL) {
        _ = try? run("rmdir \(quoted(folder))", nil)
    }
}
