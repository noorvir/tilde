import Foundation

/// The file operations of an install: on this Mac, or on another machine through a shell.
public protocol InstallFiles: Sendable {
    func exists(_ file: URL) -> Bool
    func read(_ file: URL) throws -> String
    /// Writes through symbolic links, creating the folders on the way.
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
        try Data(text.utf8).write(to: real, options: .atomic)
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

    public func write(_ text: String, to file: URL) throws {
        let path = quoted(file)
        let temporary = quoted(file.appendingPathExtension("tilde-new"))
        let folder = quoted(file.deletingLastPathComponent())
        _ = try run("mkdir -p \(folder) && if [ -L \(path) ]; then cat > \(path); else cat > \(temporary) && mv \(temporary) \(path); fi", text)
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
