import Foundation

/// Machines that Tilde is installed on, and the token of each. A node's agents reach this Mac only
/// through the node port, and only with their token.
public struct Node: Codable, Equatable, Sendable {
    public let host: String
    public let token: String

    public init(host: String, token: String) {
        self.host = host
        self.token = token
    }
}

public struct NodeStore: Sendable {
    public let file: URL

    public init(file: URL = NodeStore.defaultFile) {
        self.file = file
    }

    public static var defaultFile: URL {
        if let path = ProcessInfo.processInfo.environment["TILDE_NODES"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tilde/nodes.json")
    }

    public func load() -> [Node] {
        guard let data = try? Data(contentsOf: file) else {
            return []
        }
        return (try? JSONDecoder().decode([Node].self, from: data)) ?? []
    }

    /// Readable only by this user: the tokens let their holder open Tilde on this screen.
    public func save(_ nodes: [Node]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(nodes).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func node(forAuthorization header: String?) -> Node? {
        guard let header, header.hasPrefix("Bearer ") else {
            return nil
        }
        let token = String(header.dropFirst(7))
        return load().first { $0.token == token }
    }
}

/// The host names on this Mac that may be nodes.
public enum NodeDiscovery {
    /// The hosts of running `ssh` connections, from `ps -axo command`. The host is the first word
    /// after the options, which take a value when they are in `valued`.
    public static func sshHosts(inProcessList text: String) -> [String] {
        let valued = Set("bBcDeEfFiIJlLmoOpPqQRSwW")
        var hosts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let tool = words.first, tool == "ssh" || tool.hasSuffix("/ssh") else {
                continue
            }
            var index = 1
            while index < words.count, words[index].hasPrefix("-") {
                let option = words[index]
                if option.count == 2, let letter = option.last, valued.contains(letter) {
                    index += 1
                }
                index += 1
            }
            guard index < words.count else {
                continue
            }
            let host = words[index].split(separator: "@").last.map(String.init) ?? words[index]
            if RemotePush.isValid(host: host), !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts
    }

    public static func runningHosts() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return sshHosts(inProcessList: String(decoding: data, as: UTF8.self))
    }
}
