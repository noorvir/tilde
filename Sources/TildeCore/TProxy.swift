import CryptoKit
import Foundation

/// `tproxy`, the pipe from a node's agents to Tilde: they start it as a stdio MCP server,
/// and it connects to the socket that Tilde's ssh link forwards to the node. Tilde copies each
/// node the file for its type: the one in Tilde.app when the build put them there (dev builds),
/// or else the one from the GitHub release of this Tilde's version, with the hash built in here,
/// the same as `proxy/SHA256SUMS`.
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

        /// The release file's hash.
        public var sha256: String {
            switch self {
            case .darwinArm64: "c8782c721b027c6b6927010585c22743f67cf27e39e758f9d29ad5fd9deb0337"
            case .darwinAmd64: "d29007226862a85e2f2527562d7b7f315861980b9b07b2bdbbdb5c986e26edef"
            case .linuxAmd64: "105617cce37b2a904af94bd48ec4816af5c47c7954dba7935eb4b96dd6b1cfbf"
            case .linuxArm64: "c67513e7f3de33e8ee6eba9fd255a0c3720bcf76af615f66b8b246c1ec756a58"
            }
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case download(String)
        case wrongHash(String)

        public var description: String {
            switch self {
            case .download(let reason): "Could not download tproxy: \(reason)"
            case .wrongHash(let name): "The downloaded \(name) is not the one Tilde expects, so it was not used"
            }
        }
    }

    /// The files in Tilde.app, when the build put them there.
    public static var bundled: URL? {
        let folder = Bundle.main.resourceURL?.appendingPathComponent("tproxy")
        return folder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// The release of this Tilde's version.
    public static var release: URL {
        URL(string: "https://github.com/noorvir/tilde/releases/download/v\(appVersion)")!
    }

    public static var defaultCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.tilde.app/tproxy-v\(appVersion)")
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The node type's file on this Mac: Tilde.app's own, or else the release's, which is
    /// downloaded once, checked against its built-in hash and cached. A release file with
    /// another hash is never returned.
    public static func file(for target: Target, bundled: URL? = bundled, cache: URL = defaultCache, release: URL = release) async throws -> URL {
        if let bundled {
            return bundled.appendingPathComponent(target.fileName)
        }

        let file = cache.appendingPathComponent(target.fileName)
        if let data = try? Data(contentsOf: file), sha256(data) == target.sha256 {
            return file
        }

        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(from: release.appendingPathComponent(target.fileName))
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                throw Failure.download("the server answered \(status)")
            }
            data = body
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        guard sha256(data) == target.sha256 else {
            throw Failure.wrongHash(target.fileName)
        }

        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }
}
