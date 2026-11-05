import Foundation
import os

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

    /// The warning when a copy's images did not reach some machines.
    public static func failure(_ hosts: [String]) -> String {
        "Could not send the images to \(hosts.joined(separator: ", "))"
    }

    /// Copies the folder to `~/.tilde/inbox/<its name>/` on the host, the same place as on this
    /// Mac. A copy with videos can take minutes, so it waits on a thread of its own, never on
    /// Swift's shared ones.
    public static func push(_ folder: URL, to host: String) async throws {
        guard isValid(host: host) else {
            throw Failure.invalidHost
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    let name = folder.lastPathComponent
                    _ = try run(ssh, options + [host, "mkdir -p ~/.tilde/inbox/\(name)"])
                    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).map { folder.appendingPathComponent($0).path }
                    _ = try run(scp, options + files + ["\(host):.tilde/inbox/\(name)/"])
                })
            }
        }
    }

    /// Runs a command on the host, with `input` as its standard input. Waits for the network.
    public static func runOnNode(_ host: String, command: String, input: String? = nil) throws -> String {
        guard isValid(host: host) else {
            throw Failure.invalidHost
        }
        try FileManager.default.createDirectory(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tilde"), withIntermediateDirectories: true)
        shareConnection(to: host)
        return try run(ssh, options + [host, command], input: input)
    }

    private static let ssh = "/usr/bin/ssh"
    private static let scp = "/usr/bin/scp"
    // Never waits for a password: there is nobody to type it. A connection that stops
    // answering for 30 s ends the command, also in the middle of a copy.
    private static let options = [
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
        "-o", "ControlMaster=no", "-o", "ControlPath=~/.tilde/ssh-%C",
    ]
    private static let lastShared = OSAllocatedUnfairLock(initialState: [String: Date]())

    /// Opens a connection that the many small commands of an install share, when none is recent.
    /// It stays in the background, so it gets none of the pipes that a command is read through.
    private static func shareConnection(to host: String) {
        let isRecent = lastShared.withLock { times in
            if let time = times[host], Date().timeIntervalSince(time) < 20 {
                return true
            }
            times[host] = Date()
            return false
        }
        guard !isRecent else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = [
            "-f", "-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ControlMaster=auto",
            "-o", "ControlPath=~/.tilde/ssh-%C", "-o", "ControlPersist=30", host,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
        }
    }

    private static func run(_ tool: String, _ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errorsFile = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ssh-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorsFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorsFile) }
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: errorsFile)
        let inputPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        try process.run()
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.failed((try? String(contentsOf: errorsFile, encoding: .utf8)) ?? "")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
