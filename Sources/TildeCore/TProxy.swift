import CryptoKit
import Foundation

/// `tproxy`, the pipe from a node's agents to Tilde: they start it as a stdio MCP server,
/// and it connects to the socket that Tilde's ssh link forwards to the node. Every build puts
/// the file for each node type in Tilde.app, and Tilde copies each node the one for its type.
public enum TProxy {
    /// A node type that has a file.
    public enum Target: String, CaseIterable, Sendable {
        case darwinArm64 = "darwin-arm64"
        case darwinAmd64 = "darwin-amd64"
        case linuxAmd64 = "linux-amd64"
        case linuxArm64 = "linux-arm64"

        /// The type from `uname -sm`, such as "Linux aarch64"; nil for one with no file, such as
        /// FreeBSD.
        public init?(uname: String) {
            let words = uname.split(whereSeparator: \.isWhitespace)
            guard words.count == 2 else {
                return nil
            }

            switch (words[0], words[1]) {
            case ("Darwin", "arm64"): self = .darwinArm64
            case ("Darwin", "x86_64"): self = .darwinAmd64
            case ("Linux", "x86_64"), ("Linux", "amd64"): self = .linuxAmd64
            case ("Linux", "aarch64"), ("Linux", "arm64"): self = .linuxArm64
            default: return nil
            }
        }

        public var fileName: String {
            "tproxy-\(rawValue)"
        }
    }

    /// The node type's file in Tilde.app.
    public static func file(for target: Target) -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/tproxy/\(target.fileName)")
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
