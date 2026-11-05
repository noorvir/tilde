import Foundation

/// Machines that Tilde is installed on. A node's agents reach this Mac through `tilde-proxy` and
/// the node's socket, which its ssh link forwards to a socket of this Mac for that node only; a
/// node type with no `tilde-proxy` file reaches it through the node port with its token.
public struct Node: Codable, Equatable, Sendable {
    public let host: String
    public let token: String
    /// The socket on the node, an absolute path; nil for a node linked by the port.
    public var socket: String?

    public init(host: String, token: String, socket: String? = nil) {
        self.host = host
        self.token = token
        self.socket = socket
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

    /// Where an alias leads, from the output of `ssh -G`: aliases of one address are one machine.
    public static func address(fromSSHSettings text: String) -> String? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            if words.count == 2 {
                values[words[0].lowercased()] = words[1]
            }
        }
        return values["hostname"].map { "\($0):\(values["port"] ?? "22")" }
    }

    /// What is known of each alias, best first: the machine's own name, or else where it leads.
    public struct Alias: Equatable, Sendable {
        public let host: String
        public let machineName: String?
        public let address: String?

        public init(host: String, machineName: String?, address: String?) {
            self.host = host
            self.machineName = machineName
            self.address = address
        }
    }

    /// The aliases of each machine, in the order found. Two aliases are one machine when they
    /// share an address, or report the same machine name. The name to show comes first: an
    /// installed one, or else the first that is not a bare IP address.
    public static func machines(_ aliases: [Alias], installed: [String] = []) -> [[String]] {
        var groups: [[Alias]] = []
        for alias in aliases {
            let index = groups.firstIndex { group in
                group.contains { other in
                    (alias.address != nil && alias.address == other.address)
                        || (alias.machineName != nil && alias.machineName == other.machineName)
                }
            }
            if let index {
                groups[index].append(alias)
            } else {
                groups.append([alias])
            }
        }

        func isAddress(_ host: String) -> Bool {
            host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        }
        return groups.map { group in
            let hosts = group.map(\.host)
            let first = hosts.first(where: installed.contains) ?? hosts.first { !isAddress($0) } ?? hosts[0]
            return [first] + hosts.filter { $0 != first }
        }
    }

    public static func address(ofAlias host: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", host]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return address(fromSSHSettings: String(decoding: data, as: UTF8.self))
    }

    /// The machine's own name, when it answers quickly.
    public static func machineName(of host: String) -> String? {
        let name = try? RemotePush.runOnNode(host, command: "uname -n")
        return name?.trimmingCharacters(in: .whitespacesAndNewlines)
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
