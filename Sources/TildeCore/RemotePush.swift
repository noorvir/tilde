import Foundation

/// Copies a saved report to another machine, so that an agent there can open its images. The
/// host is a name for `ssh`, such as an alias from `~/.ssh/config`.
public enum RemotePush {
    public enum Failure: Error {
        case invalidHost
        case failed(String)
    }

    /// Whether this can be a host for `ssh`: it must not read as an option or a command.
    public static func isValid(host: String) -> Bool {
        guard let first = host.first, first != "-" else {
            return false
        }
        return host.allSatisfy { $0.isLetter || $0.isNumber || ".-_@:".contains($0) }
    }

    /// The named hosts of an ssh config, without patterns such as `*`.
    public static func sshHosts(inConfig text: String) -> [String] {
        var hosts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.first?.lowercased() == "host" else {
                continue
            }
            for host in words.dropFirst() where isValid(host: host) && !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts
    }

    public static func sshHosts() -> [String] {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return sshHosts(inConfig: (try? String(contentsOf: config, encoding: .utf8)) ?? "")
    }

    public static func sending(to hosts: [String]) -> String {
        "Copied, sending to \(hosts.joined(separator: ", "))"
    }

    public static func confirmation(pushed: [String], failed: [String]) -> String {
        if failed.isEmpty {
            return "Copied, images on \(pushed.joined(separator: ", "))"
        }
        return "Copied, \(failed.joined(separator: ", ")) failed"
    }

    /// Copies the folder to `~/.tilde/inbox/<its name>/` on the host, the same place as on this
    /// Mac. Waits for the network, so call it away from the main thread.
    public static func push(_ folder: URL, to host: String) throws {
        guard isValid(host: host) else {
            throw Failure.invalidHost
        }

        let name = folder.lastPathComponent
        _ = try run(ssh, options + [host, "mkdir -p ~/.tilde/inbox/\(name)"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).map { folder.appendingPathComponent($0).path }
        _ = try run(scp, options + files + ["\(host):.tilde/inbox/\(name)/"])
    }

    /// Runs a command on the host, with `input` as its standard input. Waits for the network.
    public static func runOnNode(_ host: String, command: String, input: String? = nil) throws -> String {
        guard isValid(host: host) else {
            throw Failure.invalidHost
        }
        return try run(ssh, options + [host, command], input: input)
    }

    private static let ssh = "/usr/bin/ssh"
    private static let scp = "/usr/bin/scp"
    // Never waits for a password: there is nobody to type it.
    private static let options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]

    private static func run(_ tool: String, _ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let inputPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        try process.run()
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.failed(String(decoding: message, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
